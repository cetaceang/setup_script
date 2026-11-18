#!/usr/bin/env python3
"""Official repository tests with isolated paths and mocked package/network tools."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SIGNING_KEY = '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62'


class NginxRepoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='npctl-repo-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.scripts = self.root / 'scripts'
        self.nginx = self.root / 'nginx'
        self.apt = self.root / 'apt'
        self.keyrings = self.root / 'keyrings'
        for directory in (self.bin, self.scripts, self.nginx / 'sites-available',
                          self.nginx / 'sites-enabled', self.nginx / 'conf.d', self.root / 'usr/sbin'):
            directory.mkdir(parents=True)
        self.os_release = self.root / 'os-release'
        self.os_release.write_text('ID=ubuntu\nVERSION_CODENAME=noble\n')
        self.config = self.nginx / 'nginx.conf'
        self.config.write_text('# user-owned config, including SNI\nevents {}\nhttp {}\n')
        replacements = {'/etc/nginx': str(self.nginx), '/etc/os-release': str(self.os_release),
                        '/etc/apt': str(self.apt), '/usr/share/keyrings': str(self.keyrings),
                        '/var/backups/npctl': str(self.root / 'backups'),
                        '/run/npctl-nginx-migration.lock': str(self.root / 'migration.lock'),
                        '/usr/sbin': str(self.root / 'usr/sbin')}
        for name in ('setup.sh', 'nginx_proxy_control.sh', 'npctl_nginx_repo.sh', 'npctl_stream.sh'):
            source = (REPO / name).read_text()
            for old, new in replacements.items():
                source = source.replace(old, new)
            (self.scripts / name).write_text(source)
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + ':' + self.env['PATH'], FIXTURE=str(self.root))
        if self.env.get('NPCTL_TEST_AWK'):
            self.stub('awk', '#!/bin/bash\nexec "$NPCTL_TEST_AWK" "$@"\n')
        self.stub('dpkg', '#!/bin/bash\necho "${TEST_ARCH:-amd64}"\n')
        self.stub('dpkg-query', '''#!/bin/bash
case "$*" in
  *ca-certificates*) printf 'install ok installed' ;;
  *Maintainer*) echo 'NGINX Packaging <nginx-packaging@f5.com>' ;;
  *nginx-common*) echo 'nginx 1.28.0 installed'; echo 'nginx-common 1.28.0 installed' ;;
  *Version*) echo '1.28.0-1~noble' ;;
  *) exit 1 ;;
esac
''')
        self.stub('apt-get', '''#!/bin/bash
echo "apt-get $*" >> "$FIXTURE/commands"
if [[ $* == *update* ]]; then [[ ! -f $FIXTURE/fail_index ]]; exit; fi
if [[ $1 == -s ]]; then
  if [[ -f $FIXTURE/migration_plan ]]; then
    [[ $* != *--no-remove* ]] || exit 100
    cat "$FIXTURE/migration_plan"; exit
  fi
  if [[ -f $FIXTURE/conflicting_packages ]]; then
    [[ $* != *--no-remove* ]] || exit 100
    echo 'Remv libnginx-mod-stream [1.28.0]'; exit
  fi
  exit 0
fi
if [[ $* == *--download-only* ]]; then [[ ! -f $FIXTURE/fail_package_download ]]; exit; fi
if [[ $* == *DPkg::Pre-Install-Pkgs* ]]; then
  for arg in "$@"; do
    if [[ $arg == DPkg::Pre-Install-Pkgs::* ]]; then hook=${arg#*=}; fi
  done
  protocol='VERSION 2\nAPT::Get::Assume-Yes=true\n\nnginx-common 1.28.0 > - **REMOVE**\n'
  if [[ -f $FIXTURE/unexpected_removal ]]; then protocol+='unrelated 1.0 > - **REMOVE**\n'; fi
  printf '%b' "$protocol" | "$hook" || exit 100
  "$FIXTURE/usr/sbin/policy-rc.d" nginx start
  [[ $? == 101 ]] || exit 1
  echo 'package default' > "$FIXTURE/nginx/nginx.conf"
  echo 'package default' > "$FIXTURE/nginx/conf.d/default.conf"
fi
printf '%s\\n' "$*" >> "$FIXTURE/installed"
[[ ! -f $FIXTURE/fail_package_install ]]
''')
        self.stub('apt', '#!/bin/bash\necho "apt $*" >> "$FIXTURE/commands"\n')
        self.stub('curl', '''#!/bin/bash
echo "curl $*" >> "$FIXTURE/commands"
[[ ! -f $FIXTURE/fail_download ]] || exit 22
if [[ $* == *nginx_signing.key* && -f $FIXTURE/fail_key_download ]]; then exit 22; fi
while (($#)); do
  if [[ $1 == -o ]]; then printf 'downloaded fixture' > "$2"; exit; fi
  shift
done
exit 1
''')
        self.stub('gpg', '''#!/bin/bash
if [[ $* == *--show-keys* ]]; then cat "$FIXTURE/fingerprints"; exit; fi
while (($#)); do
  if [[ $1 == --output ]]; then printf 'keyring fixture' > "$2"; exit; fi
  shift
done
exit 1
''')
        self.set_keys(SIGNING_KEY)
        (self.root / 'candidate').write_text('1.30.0-1~noble')
        self.set_versions('https://nginx.org/packages/ubuntu')
        self.stub('apt-cache', '''#!/bin/bash
if [[ $1 == policy ]]; then
  printf 'nginx:\\n  Installed: 1.28.0-1~noble\\n  Candidate: %s\\n' "$(cat "$FIXTURE/candidate")"
else
  cat "$FIXTURE/versions"
fi
''')
        self.stub('nginx', '''#!/bin/bash
echo "nginx $*" >> "$FIXTURE/commands"
if [[ $1 == -T ]]; then cat "$FIXTURE/nginx/nginx.conf"; fi
[[ ! -f $FIXTURE/fail_nginx ]]
''')
        self.stub('systemctl', '''#!/bin/bash
echo "systemctl $*" >> "$FIXTURE/commands"
if [[ $1 == is-active ]]; then [[ -f $FIXTURE/service_active ]]; exit; fi
if [[ $1 == stop ]]; then
  [[ ! -f $FIXTURE/fail_stop ]] || exit 1
  if [[ -f $FIXTURE/service_active ]]; then rm "$FIXTURE/service_active"; fi
fi
if [[ $1 == start ]]; then touch "$FIXTURE/service_active"; fi
''')
        self.stub('invoke-rc.d', '#!/bin/bash\nexit 0\n')

    def stub(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def set_keys(self, *keys):
        (self.root / 'fingerprints').write_text(''.join(
            f'pub:-:2048:1:KEY::::\nfpr:::::::::{key}:\n' for key in keys))

    def set_versions(self, url):
        (self.root / 'versions').write_text(f' nginx | 1.30.0-1~noble | {url} noble/nginx amd64 Packages\n')

    def run_bash(self, code, *, script='setup.sh', success=True, input=None):
        result = subprocess.run(['bash', '-c', 'source "$1/$2"; ' + code, 'test', str(self.scripts), script],
                                env=self.env, capture_output=True, text=True, input=input)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def commands(self):
        path = self.root / 'commands'
        return path.read_text() if path.exists() else ''

    def assert_not_installed(self):
        self.assertFalse((self.root / 'installed').exists(), self.commands())

    def test_sourcing_helpers_has_no_side_effects(self):
        self.run_bash(':')
        self.run_bash(':', script='nginx_proxy_control.sh')
        self.assertEqual(self.commands(), '')
        self.assertFalse(self.apt.exists())

    def test_ubuntu_source_has_signed_by_and_pin_and_is_idempotent(self):
        self.run_bash('nginx_setup_official_repo && nginx_setup_official_repo')
        source = (self.apt / 'sources.list.d/nginx.list').read_text()
        self.assertEqual(source.count('deb '), 1)
        self.assertIn(f'arch=amd64 signed-by={self.keyrings}/nginx-archive-keyring.gpg', source)
        self.assertIn('https://nginx.org/packages/ubuntu noble nginx', source)
        pin = (self.apt / 'preferences.d/99nginx').read_text()
        self.assertIn('Pin: origin nginx.org', pin)
        self.assertIn('Pin-Priority: 900', pin)
        self.assertEqual((self.keyrings / 'nginx-archive-keyring.gpg').stat().st_mode & 0o777, 0o644)
        self.assert_not_installed()

    def test_debian_and_arm64_are_supported(self):
        self.os_release.write_text('ID=debian\nVERSION_CODENAME=trixie\n')
        self.env['TEST_ARCH'] = 'arm64'
        self.run_bash('nginx_setup_official_repo')
        source = (self.apt / 'sources.list.d/nginx.list').read_text()
        self.assertIn('arch=arm64', source)
        self.assertIn('https://nginx.org/packages/debian trixie nginx', source)

    def test_unsupported_platform_architecture_or_codename_changes_nothing(self):
        for release, arch in [('ID=alpine\nVERSION_CODENAME=noble\n', 'amd64'),
                              ('ID=ubuntu\n', 'amd64'),
                              ('ID=ubuntu\nVERSION_CODENAME=noble\n', 'i386')]:
            with self.subTest(release=release, arch=arch):
                self.os_release.write_text(release)
                self.env['TEST_ARCH'] = arch
                self.run_bash('nginx_setup_official_repo', success=False)
                self.assertEqual(self.commands(), '')
                self.assertFalse(self.apt.exists())

    def test_failed_release_or_key_download_preserves_existing_source(self):
        source = self.apt / 'sources.list.d/nginx.list'
        source.parent.mkdir(parents=True)
        source.write_text('original source\n')
        for marker in ('fail_download', 'fail_key_download'):
            with self.subTest(marker=marker):
                (self.root / marker).touch()
                self.run_bash('nginx_setup_official_repo', success=False)
                self.assertEqual(source.read_text(), 'original source\n')
                self.assertFalse(self.keyrings.exists())
                (self.root / marker).unlink()

    def test_missing_expected_key_or_unknown_bundled_key_is_rejected(self):
        for keys in [('A' * 40,), (SIGNING_KEY, 'B' * 40)]:
            with self.subTest(keys=keys):
                self.set_keys(*keys)
                self.run_bash('nginx_setup_official_repo', success=False)
                self.assertFalse(self.apt.exists())
                self.assertFalse(self.keyrings.exists())

    def test_new_install_routes_only_nginx_through_official_repo(self):
        self.run_bash('install_packages nginx certbot python3')
        installed = (self.root / 'installed').read_text()
        self.assertIn('--no-remove', installed)
        self.assertIn('nginx=1.30.0-1~noble', installed)
        self.assertIn('Dpkg::Options::=--force-confold', installed)
        self.assertIn('apt install -y certbot python3', self.commands())
        self.assertNotIn('apt update\n', self.commands())
        self.assertEqual(self.commands().count('APT::Update::Error-Mode=any update'), 1)

    def test_third_party_or_mainline_candidates_are_never_installed(self):
        for url in ('https://ppa.example/nginx', 'https://nginx.org/packages/mainline/ubuntu'):
            with self.subTest(url=url):
                self.set_versions(url)
                self.run_bash('nginx_install_official_package', success=False)
                self.assert_not_installed()

    def test_missing_candidate_is_never_installed(self):
        (self.root / 'candidate').write_text('(none)')
        self.run_bash('nginx_install_official_package', success=False)
        self.assert_not_installed()

    def test_failed_index_refresh_never_falls_back_to_stale_packages(self):
        (self.root / 'fail_index').touch()
        self.run_bash('nginx_install_official_package', success=False)
        self.assert_not_installed()

    def test_package_conflicts_stop_before_any_removals(self):
        (self.root / 'conflicting_packages').touch()
        result = self.run_bash('nginx_install_official_package', success=False)
        self.assertIn('勿直接 purge', result.stderr)
        self.assertIn('apt-get -s --no-remove install', self.commands())
        self.assert_not_installed()

    def prepare_migration(self, *, active=True):
        (self.root / 'migration_plan').write_text(
            'Remv nginx-common [1.28.0]\nInst nginx [1.28.0] (1.30.0 nginx:stable)\n')
        if active:
            (self.root / 'service_active').touch()
        policy = self.root / 'usr/sbin/policy-rc.d'
        policy.write_text('#!/bin/bash\nexit 7\n')
        policy.chmod(0o755)
        return policy

    def test_common_only_migration_restores_exact_config_and_host_policy(self):
        policy = self.prepare_migration()
        before = self.config.read_bytes()
        site = self.nginx / 'sites-available/example.com'
        site.write_text('user-owned site\n')
        link = self.nginx / 'sites-enabled/example.com'
        link.symlink_to(site)
        sni = self.nginx / 'npctl-stream'
        sni.mkdir()
        (sni / 'nodes.tsv').write_text('example.com\t34138\n')
        policy_before = policy.read_bytes()
        self.run_bash('nginx_install_official_package --only-upgrade', input='y\n')
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(site.read_text(), 'user-owned site\n')
        self.assertEqual(link.readlink(), site)
        self.assertEqual((sni / 'nodes.tsv').read_text(), 'example.com\t34138\n')
        self.assertFalse((self.nginx / 'conf.d/default.conf').exists())
        self.assertEqual(policy.read_bytes(), policy_before)
        self.assertTrue((self.root / 'service_active').exists())
        self.assertFalse((self.root / 'migration.lock').exists())
        backup, = (self.root / 'backups').iterdir()
        self.assertEqual((backup / 'nginx/nginx.conf').read_bytes(), before)
        self.assertTrue((backup / 'package-nginx/conf.d/default.conf').exists())
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        commands = self.commands()
        self.assertLess(commands.index('--download-only'), commands.index('systemctl stop nginx'))
        self.assertLess(commands.index('systemctl stop nginx'), commands.index('DPkg::Pre-Install-Pkgs'))
        self.assertLess(commands.index('DPkg::Pre-Install-Pkgs'), commands.index('systemctl start nginx'))
        installed = (self.root / 'installed').read_text()
        self.assertIn('APT::Get::Purge=false', installed)
        self.assertNotIn('--no-remove', installed)

    def test_migration_preserves_existing_official_default_and_inactive_state(self):
        policy = self.prepare_migration(active=False)
        policy.unlink()
        default = self.nginx / 'conf.d/default.conf'
        default.write_text('custom original default\n')
        self.run_bash('nginx_install_official_package', input='yes\n')
        self.assertEqual(default.read_text(), 'custom original default\n')
        self.assertFalse(policy.exists())
        self.assertNotIn('systemctl start nginx', self.commands())

    def test_migration_requires_explicit_confirmation(self):
        self.prepare_migration()
        for answer in ('n\n', '\n', ''):
            with self.subTest(answer=answer):
                self.run_bash('nginx_install_official_package', input=answer, success=False)
                self.assert_not_installed()
                self.assertFalse((self.root / 'backups').exists())
                self.assertNotIn('systemctl stop nginx', self.commands())

    def test_migration_rejects_additional_removals_or_purge(self):
        self.prepare_migration()
        for removal in ('Remv libnginx-mod-stream [1.28.0]', 'Remv nginx-core [1.28.0]',
                        'Remv unrelated [1.0]', 'Purg nginx-common [1.28.0]'):
            with self.subTest(removal=removal):
                (self.root / 'migration_plan').write_text('Remv nginx-common [1.28.0]\n' + removal + '\n')
                self.run_bash('nginx_install_official_package', input='y\n', success=False)
                self.assert_not_installed()
                self.assertFalse((self.root / 'backups').exists())

    def test_migration_rejects_loaded_dynamic_modules(self):
        self.prepare_migration()
        self.config.write_text('load_module /custom/module.so;\nevents {}\nhttp {}\n')
        result = self.run_bash('nginx_install_official_package', input='y\n', success=False)
        self.assertIn('动态模块', result.stderr)
        self.assert_not_installed()

    def test_migration_backup_failure_never_stops_service(self):
        policy = self.prepare_migration()
        before = policy.read_bytes()
        self.stub('cp', '#!/bin/bash\nexit 1\n')
        self.run_bash('nginx_install_official_package', input='y\n', success=False)
        self.assert_not_installed()
        self.assertEqual(policy.read_bytes(), before)
        self.assertNotIn('systemctl stop nginx', self.commands())
        self.assertFalse((self.root / 'migration.lock').exists())

    def test_migration_download_failure_never_stops_service(self):
        self.prepare_migration()
        (self.root / 'fail_package_download').touch()
        self.run_bash('nginx_install_official_package', input='y\n', success=False)
        self.assert_not_installed()
        self.assertNotIn('systemctl stop nginx', self.commands())

    def test_migration_install_failure_restores_config_policy_and_service(self):
        policy = self.prepare_migration()
        before = self.config.read_bytes()
        policy_before = policy.read_bytes()
        (self.root / 'fail_package_install').touch()
        result = self.run_bash('nginx_install_official_package', input='y\n', success=False)
        self.assertIn('软件包未自动回滚', result.stderr)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse((self.nginx / 'conf.d/default.conf').exists())
        self.assertEqual(policy.read_bytes(), policy_before)
        self.assertIn('systemctl start nginx', self.commands())
        self.assertFalse((self.root / 'migration.lock').exists())

    def test_migration_guard_blocks_changed_transaction_before_dpkg(self):
        policy = self.prepare_migration()
        before = self.config.read_bytes()
        policy_before = policy.read_bytes()
        (self.root / 'unexpected_removal').touch()
        result = self.run_bash('nginx_install_official_package', input='y\n', success=False)
        self.assertIn('Unexpected package removal: unrelated', result.stderr)
        self.assert_not_installed()
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(policy.read_bytes(), policy_before)

    def test_migration_stop_failure_restores_policy_without_installing(self):
        policy = self.prepare_migration()
        before = policy.read_bytes()
        (self.root / 'fail_stop').touch()
        self.run_bash('nginx_install_official_package', input='y\n', success=False)
        self.assert_not_installed()
        self.assertEqual(policy.read_bytes(), before)
        self.assertNotIn('systemctl start nginx', self.commands())

    def test_update_uses_official_source_and_preserves_configuration(self):
        (self.root / 'service_active').touch()
        before = self.config.read_bytes()
        self.run_bash('update_nginx_package', script='nginx_proxy_control.sh')
        installed = (self.root / 'installed').read_text()
        self.assertIn('--only-upgrade nginx=1.30.0-1~noble', installed)
        self.assertEqual(self.config.read_bytes(), before)
        commands = self.commands()
        self.assertLess(commands.index('nginx -t'), commands.index('apt-get'))
        self.assertIn('systemctl reload nginx', commands)

    def test_update_does_not_touch_packages_when_existing_config_is_invalid(self):
        (self.root / 'fail_nginx').touch()
        self.run_bash('update_nginx_package', script='nginx_proxy_control.sh', success=False)
        self.assertFalse(self.apt.exists())
        self.assert_not_installed()

    def test_official_stream_failure_does_not_install_distribution_modules(self):
        result = self.run_bash('stream_module_available() { return 1; }; stream_ensure_module',
                               script='nginx_proxy_control.sh', success=False)
        self.assertIn('不安装发行版 libnginx-mod-stream', result.stderr)
        self.assertNotIn('apt', self.commands())

    def test_fresh_install_removes_both_distribution_and_official_default_sites(self):
        old_default = self.nginx / 'sites-enabled/default'
        official_default = self.nginx / 'conf.d/default.conf'
        old_default.write_text('distribution default')
        official_default.write_text('official default')
        third_party = self.nginx / 'conf.d/custom.conf'
        third_party.write_text('preserve me')
        self.run_bash('remove_default_nginx_site')
        self.assertFalse(old_default.exists())
        self.assertFalse(official_default.exists())
        self.assertEqual(third_party.read_text(), 'preserve me')


if __name__ == '__main__':
    unittest.main()
