#!/usr/bin/env python3
"""Isolated configuration/rollback tests; never use /etc or a running service.

Set NPCTL_TEST_NGINX and NPCTL_TEST_STREAM_MODULE to unpacked distribution
binaries to also run real nginx -t/-T. systemctl, ss and Certbot stay mocked.
"""
import importlib.util
import os
import pwd
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stream_config', REPO / 'npctl_stream_config.py')
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)


class StreamTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='npctl-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.nginx = self.root / 'nginx'
        self.available = self.nginx / 'sites-available'
        self.enabled = self.nginx / 'sites-enabled'
        self.stream = self.nginx / 'npctl-stream'
        self.cert = self.root / 'letsencrypt'
        self.bin = self.root / 'bin'
        self.lib = self.root / 'scripts'
        for directory in (self.available, self.enabled, self.stream, self.cert / 'live/example.com', self.bin, self.lib,
                          self.nginx / 'snippets', self.nginx / 'conf.d', self.nginx / 'modules-enabled', self.root / 'acme'):
            directory.mkdir(parents=True, exist_ok=True)
        replacements = {'/etc/nginx': str(self.nginx), '/etc/letsencrypt': str(self.cert),
                        '/var/www/acme': str(self.root / 'acme'), '/var/www/npctl-fallback': str(self.root / 'web'),
                        '/run/npctl-stream.lock': str(self.root / 'lock'), '/var/backups/npctl': str(self.root / 'backups'),
                        '/usr/local': str(self.root / 'usr/local'), '/root/.secrets': str(self.root / 'secrets'),
                        '/usr/sbin': str(self.root / 'usr/sbin'), '/run/npctl-stream-module.lock': str(self.root / 'module-lock'),
                        '/var/cache/nginx': str(self.root / 'cache')}
        for name in ('nginx_proxy_control.sh', 'setup.sh', 'npctl_stream.sh', 'npctl_stream_config.py'):
            text = (REPO / name).read_text()
            for old, new in replacements.items():
                text = text.replace(old, new).replace(old.replace('/', '\\/'), new.replace('/', '\\/'))
            (self.lib / name).write_text(text)
        self.env = os.environ.copy()
        self.env['PATH'] = str(self.bin) + ':' + self.env['PATH']
        self.env['FIXTURE'] = str(self.root)
        self.env['MAIN'] = str(self.nginx / 'nginx.conf')
        if self.env.get('NPCTL_TEST_AWK'):
            self.stub('awk', '#!/bin/bash\nexec "$NPCTL_TEST_AWK" "$@"\n')
        self.stub('systemctl', '''#!/bin/bash
printf '%s\\n' "$*" >> "$FIXTURE/systemctl.log"
if [[ $1 == show ]]; then
  printf '{ path=%s ; argv[]=%s -g daemon on; master_process on; ; ignore_errors=no ; }\\n' "$(command -v nginx)" "$(command -v nginx)"
fi
if [[ $1 == reload && -f $FIXTURE/fail_reload ]]; then rm "$FIXTURE/fail_reload"; exit 1; fi
''')
        self.stub('ss', '''#!/bin/bash
if [[ $* == *':443 or'* ]]; then
  cat "$FIXTURE/sockets" 2>/dev/null || true
else
  awk '$4 ~ /:8443$/ {print}' "$FIXTURE/sockets" 2>/dev/null || true
fi
''')
        self.stub('certbot', '''#!/bin/bash
[[ $1 == certificates ]] || exit 1
cat <<EOF
Certificate Name: example.com
Domains: example.com *.example.com
Expiry Date: 2099-01-01
EOF
''')
        self.stub('nginx', '''#!/bin/bash
if [[ -f $FIXTURE/fail_check && -f $FIXTURE/nginx/npctl-stream/enabled ]]; then exit 1; fi
if [[ ${NPCTL_TEST_NGINX:-} ]]; then
  if [[ ${NPCTL_TEST_NETNS:-} == 1 ]]; then
    exec sudo -n unshare -n "$NPCTL_TEST_NGINX" -p "$FIXTURE/nginx/" -e stderr "$@" -c "$MAIN"
  fi
  exec "$NPCTL_TEST_NGINX" -p "$FIXTURE/nginx/" -e stderr "$@" -c "$MAIN"
fi
if [[ $1 == -T ]]; then
  for f in "$MAIN" "$FIXTURE"/nginx/sites-enabled/* "$FIXTURE"/nginx/conf.d/*.conf; do
    [[ -f $f ]] || continue
    printf '# configuration file %s:\\n' "$f"; cat "$f"
  done
  if [[ -f $FIXTURE/nginx/npctl-stream/enabled ]]; then
    printf '# configuration file %s:\\n' "$FIXTURE/nginx/npctl-stream/stream.conf"
    cat "$FIXTURE/nginx/npctl-stream/stream.conf"
  fi
fi
''')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
                        '-keyout', str(self.cert / 'live/example.com/privkey.pem'), '-out', str(self.cert / 'live/example.com/fullchain.pem'),
                        '-days', '1', '-subj', '/CN=example.com', '-addext', 'subjectAltName=DNS:example.com,DNS:*.example.com'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        module = self.env.get('NPCTL_TEST_STREAM_MODULE')
        main = f'load_module {module};\n' if module else ''
        main += f'''user {pwd.getpwuid(os.getuid()).pw_name};
pid {self.root}/nginx.pid;
error_log stderr;
events {{}}
http {{
 access_log off;
 client_body_temp_path {self.root}/body;
 proxy_temp_path {self.root}/proxy;
 fastcgi_temp_path {self.root}/fastcgi;
 uwsgi_temp_path {self.root}/uwsgi;
 scgi_temp_path {self.root}/scgi;
 map $http_upgrade $connection_upgrade {{ default upgrade; "" close; }}
 include {self.enabled}/*;
 include {self.nginx}/conf.d/*.conf;
}}
'''
        (self.nginx / 'nginx.conf').write_text(main)
        snippets = {'acme-webroot.conf': f'location ^~ /.well-known/acme-challenge/ {{ root {self.root}/acme; try_files $uri =404; }}',
                    'redirect-https-308.conf': 'location / { return 308 https://$host$request_uri; }',
                    'security-headers.conf': 'add_header X-Content-Type-Options nosniff;',
                    'proxy-common.conf': 'proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade;',
                    'block-common-exploits.optional.conf': '', 'proxy-cache-assets.optional.conf': '', 'cache-assets.optional.conf': ''}
        for name, content in snippets.items():
            (self.nginx / 'snippets' / name).write_text(content + '\n')
        (self.cert / 'options-ssl-nginx.conf').write_text('ssl_protocols TLSv1.2 TLSv1.3;\n')
        self.run_bash('source "$1/setup.sh"; write_letsencrypt_dhparams_file', main=False)
        self.create_site('blog.example.com')
        self.create_site('api.example.com')

    def stub(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_bash(self, code, *, main=True, success=True, input=None):
        source = 'source "$1/nginx_proxy_control.sh"; ' if main else ''
        result = subprocess.run(['bash', '-c', source + code, 'test', str(self.lib)], env=self.env,
                                input=input, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def create_site(self, domain):
        self.run_bash(f'''SITE_DOMAIN={domain}; UPSTREAM_IP=127.0.0.1; UPSTREAM_PORT=3000;
SELECTED_CERT_NAME=example.com; CLIENT_MAX_BODY_SIZE=64M;
ENABLE_BLOCK_COMMON_EXPLOITS=1; ENABLE_PROXY_CACHE_ASSETS=1; ENABLE_BROWSER_CACHE_HEADERS=1;
build_site_config "$NGINX_SITES_AVAILABLE_DIR/{domain}" {domain.replace('.', '_')}_upstream || exit 1
ln -s "$NGINX_SITES_AVAILABLE_DIR/{domain}" "$NGINX_SITES_ENABLED_DIR/{domain}"
''')

    def enable(self):
        self.run_bash('stream_transaction stream_do_enable')

    def add(self, domain, port):
        self.run_bash(f'stream_prepare_website {domain} && stream_transaction stream_do_add_node {domain} {port}', input='y\n')

    def add_relay(self, domain, port):
        confirmation = '' if (self.stream / 'enabled').exists() else 'y\n'
        return self.run_bash('stream_add_node', input=f'{domain}\n{port}\n2\n{confirmation}')

    def remove_all_sites(self):
        for directory in (self.enabled, self.available):
            for file in directory.iterdir():
                file.unlink()

    def assert_no_first_node_state(self, original_main):
        self.assertEqual((self.nginx / 'nginx.conf').read_bytes(), original_main)
        self.assertFalse(list(self.available.iterdir()))
        self.assertFalse(list(self.enabled.iterdir()))
        self.assertFalse(list(self.stream.iterdir()))
        self.assertFalse((self.root / 'web/node.example.com/index.html').exists())
        self.assertFalse((self.root / 'lock').exists())

    def test_first_node_without_existing_sites_enables_in_one_transaction(self):
        self.remove_all_sites()
        result = self.run_bash('stream_add_node', input='node.example.com\n39149\n1\ny\ny\n')
        self.assertIn('当前没有已有 HTTPS 站点', result.stdout)
        self.assertTrue((self.stream / 'enabled').exists())
        self.assertEqual((self.stream / 'nodes.tsv').read_text(), 'node.example.com\t39149\n')
        site = (self.available / 'node.example.com').read_text()
        self.assertIn('listen 127.0.0.1:8443 ssl http2;', site)
        self.assertNotIn('listen 443 ssl', site)
        self.assertEqual((self.root / 'systemctl.log').read_text().count('reload nginx'), 1)
        self.run_bash('stream_transaction stream_do_disable')
        self.assertIn('listen 443 ssl http2;', (self.available / 'node.example.com').read_text())

    def test_enable_without_sites_guides_first_node(self):
        self.remove_all_sites()
        result = self.run_bash('stream_enable', input='node.example.com\n39149\n1\ny\ny\n')
        self.assertIn('请添加首个节点', result.stdout)
        self.assertTrue((self.stream / 'enabled').exists())
        self.assertIn('node.example.com', (self.stream / 'stream.conf').read_text())

    def test_first_node_also_migrates_existing_sites(self):
        before = {p.name: p.read_text() for p in self.available.iterdir()}
        result = self.run_bash('stream_add_node', input='node.example.com\n39149\n1\ny\ny\n')
        self.assertIn('blog.example.com', result.stdout)
        self.assertIn('IP ACL', result.stderr)
        for name, content in before.items():
            self.assertEqual((self.available / name).read_text().replace('127.0.0.1:8443', '443'), content)
        self.assertEqual((self.root / 'systemctl.log').read_text().count('reload nginx'), 1)

    def test_first_node_cancellation_keeps_empty_install_unchanged(self):
        self.remove_all_sites()
        original = (self.nginx / 'nginx.conf').read_bytes()
        for answer in ('\n', 'node.example.com\n39149\n1\nn\n', 'node.example.com\n39149\n1\ny\nn\n'):
            with self.subTest(answer=answer):
                self.run_bash('stream_add_node', input=answer, success=not answer.endswith('y\nn\n'))
                self.assert_no_first_node_state(original)

    def test_first_node_check_or_reload_failure_rolls_back_entire_setup(self):
        self.remove_all_sites()
        original = (self.nginx / 'nginx.conf').read_bytes()
        for marker in ('fail_check', 'fail_reload'):
            with self.subTest(marker=marker):
                (self.root / marker).touch()
                self.run_bash('stream_add_node', input='node.example.com\n39149\n1\ny\ny\n', success=False)
                self.assert_no_first_node_state(original)
                (self.root / marker).unlink(missing_ok=True)

    def test_first_node_rejects_a_certificate_without_matching_sni(self):
        self.remove_all_sites()
        original = (self.nginx / 'nginx.conf').read_bytes()
        self.run_bash('select_certificate() { return 1; }; stream_add_node',
                      input='unrelated.example.net\n39149\n1\ny\ny\n', success=False)
        self.assert_no_first_node_state(original)

    def test_first_node_failure_preserves_existing_sites_and_requires_confirmation(self):
        before = {p.name: p.read_bytes() for p in self.available.iterdir()}
        original = (self.nginx / 'nginx.conf').read_bytes()
        (self.root / 'fail_check').touch()
        self.run_bash('stream_add_node', input='node.example.com\n39149\n1\ny\ny\n', success=False)
        self.assertEqual(original, (self.nginx / 'nginx.conf').read_bytes())
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.available.iterdir()})
        self.assertFalse(list(self.stream.iterdir()))
        self.run_bash('stream_prepare_website node.example.com && stream_transaction stream_do_add_node node.example.com 39149',
                      input='y\n', success=False)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.available.iterdir()})

    def test_first_relay_needs_no_sites_certificates_or_certbot(self):
        self.remove_all_sites()
        shutil.rmtree(self.cert)
        (self.bin / 'certbot').unlink()
        result = self.add_relay('node.example.com', 34138)
        self.assertIn('纯中转', result.stdout)
        self.assertIn('HTTPS 回落由落地机提供', self.run_bash('stream_show_nodes').stdout)
        self.assertFalse(list(self.available.iterdir()))
        self.assertFalse(list(self.enabled.iterdir()))
        self.assertFalse((self.root / 'web').exists())
        self.assertFalse(self.cert.exists())
        self.assertEqual((self.stream / 'nodes.tsv').read_text(), 'node.example.com\t34138\n')
        self.assertEqual((self.stream / 'node-modes.tsv').read_text(), 'node.example.com\trelay\n')
        self.assertEqual((self.root / 'systemctl.log').read_text().count('reload nginx'), 1)

    def test_relay_preserves_existing_websites_and_other_local_nodes(self):
        before = {p.name: p.read_text() for p in self.available.iterdir()}
        self.add_relay('remote.other.net', 34138)
        for path in self.available.iterdir():
            self.assertEqual(path.read_text().replace('127.0.0.1:8443', '443'), before[path.name])
        self.add('local.example.com', 39149)
        result = self.run_bash('stream_show_nodes')
        self.assertIn('remote.other.net → 127.0.0.1:34138 | 纯中转', result.stdout)
        self.assertIn('local.example.com → 127.0.0.1:39149 | 同机回落', result.stdout)
        self.assertFalse((self.available / 'remote.other.net').exists())
        self.run_bash('stream_guard_disable_site "$NGINX_SITES_AVAILABLE_DIR/local.example.com"', success=False)

    def test_relay_first_node_cancellation_or_failure_restores_every_file(self):
        self.remove_all_sites()
        original = (self.nginx / 'nginx.conf').read_bytes()
        self.run_bash('stream_add_node', input='node.example.com\n34138\n2\nn\n')
        self.assert_no_first_node_state(original)
        for marker in ('fail_check', 'fail_reload'):
            with self.subTest(marker=marker):
                (self.root / marker).touch()
                self.run_bash('stream_add_node', input='node.example.com\n34138\n2\ny\n', success=False)
                self.assert_no_first_node_state(original)
                (self.root / marker).unlink(missing_ok=True)

    def test_pure_relay_reenable_reuses_saved_mappings_without_website(self):
        self.remove_all_sites()
        self.add_relay('node.example.com', 34138)
        nodes = (self.stream / 'nodes.tsv').read_bytes()
        modes = (self.stream / 'node-modes.tsv').read_bytes()
        self.run_bash('stream_transaction stream_do_disable')
        result = self.run_bash('stream_enable', input='y\n')
        self.assertIn('恢复已保存的纯中转映射', result.stdout)
        self.assertTrue((self.stream / 'enabled').exists())
        self.run_bash('stream_enable')
        self.assertEqual((self.stream / 'nodes.tsv').read_bytes(), nodes)
        self.assertEqual((self.stream / 'node-modes.tsv').read_bytes(), modes)
        self.assertFalse(list(self.available.iterdir()))
        self.assertEqual((self.nginx / 'nginx.conf').read_text().count('# Managed by npctl SNI'), 1)

    def test_switch_existing_node_to_relay_preserves_ports_sites_and_certificates(self):
        self.enable()
        self.add('node.example.com', 39149)
        paths = [*self.available.iterdir(), *self.cert.glob('live/*/*'), self.stream / 'nodes.tsv', self.stream / 'stream.conf']
        before = {p: p.read_bytes() for p in paths}
        self.run_bash('manage_stream', input='8\nnode.example.com\n2\ny\nq\n')
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)
        self.run_bash('stream_guard_disable_site "$NGINX_SITES_AVAILABLE_DIR/node.example.com"')
        self.run_bash('stream_delete_fallback', input='node.example.com\ny\n')
        self.assertFalse((self.available / 'node.example.com').exists())
        self.assertTrue((self.cert / 'live/example.com/fullchain.pem').exists())
        self.assertIn('node.example.com', (self.stream / 'nodes.tsv').read_text())

    def test_switch_to_relay_failure_and_manual_rollback_restore_legacy_mode(self):
        self.enable()
        self.add('node.example.com', 39149)
        (self.root / 'fail_reload').touch()
        self.run_bash('stream_change_node_mode', input='node.example.com\n2\ny\n', success=False)
        self.assertFalse((self.stream / 'node-modes.tsv').exists())
        self.assertEqual(self.run_bash('stream_node_mode node.example.com').stdout.strip(), 'local')
        self.run_bash('stream_change_node_mode', input='node.example.com\n2\ny\n')
        backup = max((self.root / 'backups').iterdir(), key=lambda p: p.stat().st_mtime)
        self.run_bash(f'bash "{backup}/rollback.sh"')
        self.assertFalse((self.stream / 'node-modes.tsv').exists())
        self.run_bash('stream_guard_disable_site "$NGINX_SITES_AVAILABLE_DIR/node.example.com"', success=False)

    def test_switch_to_local_requires_matching_certificate_and_is_atomic(self):
        self.add_relay('node.example.com', 34138)
        before = {p: p.read_bytes() for p in self.stream.iterdir()}
        for marker in ('fail_check', 'fail_reload'):
            with self.subTest(marker=marker):
                # Let the initial check pass; fail only after creating the website.
                if marker == 'fail_check':
                    self.run_bash('nginx() { [[ ! -f $NGINX_SITES_AVAILABLE_DIR/node.example.com ]] || return 1; command nginx "$@"; }; '
                                  'stream_change_node_mode', input='node.example.com\n1\ny\ny\n', success=False)
                else:
                    (self.root / marker).touch()
                    self.run_bash('stream_change_node_mode', input='node.example.com\n1\ny\ny\n', success=False)
                for path, content in before.items():
                    self.assertEqual(path.read_bytes(), content)
                self.assertFalse((self.available / 'node.example.com').exists())
        self.run_bash('stream_change_node_mode', input='node.example.com\n1\ny\ny\n')
        self.assertIn('同机回落', self.run_bash('stream_show_nodes').stdout)
        self.assertIn('127.0.0.1:8443 ssl', (self.available / 'node.example.com').read_text())
        self.add_relay('unrelated.other.net', 39149)
        self.run_bash('select_certificate() { return 1; }; stream_change_node_mode',
                      input='unrelated.other.net\n1\ny\ny\n', success=False)
        self.assertEqual(self.run_bash('stream_node_mode unrelated.other.net').stdout.strip(), 'relay')

    def test_relay_port_changes_and_delete_preserve_independent_metadata(self):
        self.add_relay('one.other.net', 34138)
        self.add_relay('two.other.net', 39149)
        modes = (self.stream / 'node-modes.tsv').read_bytes()
        self.run_bash('stream_change_node_port', input='one.other.net\n52347\ny\n')
        self.assertEqual((self.stream / 'node-modes.tsv').read_bytes(), modes)
        self.run_bash('stream_delete_node', input='one.other.net\n')
        self.assertEqual((self.stream / 'node-modes.tsv').read_text(), 'two.other.net\trelay\n')
        self.assertEqual((self.stream / 'nodes.tsv').read_text(), 'two.other.net\t39149\n')
        self.run_bash('stream_transaction stream_do_disable')
        self.run_bash('stream_enable', input='y\n')
        self.assertEqual(self.run_bash('stream_node_mode two.other.net').stdout.strip(), 'relay')

    def test_all_relay_nodes_allow_removing_last_local_website(self):
        self.remove_all_sites()
        self.add_relay('remote.other.net', 34138)
        self.run_bash('stream_create_fallback', input='website.example.com\ny\n')
        self.run_bash('stream_guard_disable_site "$NGINX_SITES_AVAILABLE_DIR/website.example.com"')
        self.run_bash('stream_delete_fallback', input='website.example.com\ny\n')
        self.assertFalse(list(self.available.iterdir()))
        self.assertTrue((self.stream / 'enabled').exists())

    def test_landing_https_needs_no_stream_or_public_listener(self):
        self.remove_all_sites()
        (self.root / 'sockets').write_text('LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("sing-box",pid=123,fd=4))\n')
        original = (self.nginx / 'nginx.conf').read_bytes()
        self.run_bash('stream_ensure_module() { return 1; }; stream_create_fallback 1',
                      input='node.example.com\ny\n')
        site = (self.available / 'node.example.com').read_text()
        self.assertIn(parser.LOCAL_FALLBACK_MARKER, site)
        self.assertIn('listen 127.0.0.1:8443 ssl http2;', site)
        self.assertNotIn('listen 80;', site)
        self.assertNotIn('listen 443', site)
        self.assertEqual((self.nginx / 'nginx.conf').read_bytes(), original)
        for path in ('enabled', 'nodes.tsv', 'node-modes.tsv', 'stream.conf'):
            self.assertFalse((self.stream / path).exists())
        calls = (self.root / 'systemctl.log').read_text().count('reload nginx')
        self.run_bash('stream_create_fallback 1', input='node.example.com\n')
        self.assertEqual((self.available / 'node.example.com').read_text(), site)
        self.assertEqual((self.root / 'systemctl.log').read_text().count('reload nginx'), calls + 1)
        self.assertIn('node.example.com', self.run_bash(
            'load_certificate_referenced_sites example.com; printf "%s\\n" "${CERTIFICATE_REFERENCED_SITE_NAMES[@]}"').stdout)

    def test_landing_fallback_listener_survives_stream_enable_disable(self):
        self.run_bash('stream_create_fallback 1', input='node.example.com\ny\n')
        before = (self.available / 'node.example.com').read_bytes()
        (self.root / 'sockets').write_text('LISTEN 0 128 127.0.0.1:8443 0.0.0.0:* users:(("nginx",pid=123,fd=4))\n')
        self.enable()
        self.assertEqual((self.available / 'node.example.com').read_bytes(), before)
        self.run_bash('stream_transaction stream_do_disable')
        self.assertEqual((self.available / 'node.example.com').read_bytes(), before)
        self.assertIn('listen 443 ssl', (self.available / 'blog.example.com').read_text())

    def test_landing_fallback_rejects_port_conflict_or_existing_ordinary_site(self):
        before = {p: p.read_bytes() for p in self.available.iterdir()}
        self.run_bash('stream_create_fallback 1', input='blog.example.com\n', success=False)
        (self.root / 'sockets').write_text('LISTEN 0 128 127.0.0.1:8443 0.0.0.0:* users:(("other",pid=123,fd=4))\n')
        self.run_bash('stream_create_fallback 1', input='node.example.com\ny\n', success=False)
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertFalse((self.available / 'node.example.com').exists())

    def test_landing_fallback_reload_failure_rolls_back_and_bad_marker_blocks_migration(self):
        self.run_bash('nginx() { [[ ! -f $NGINX_SITES_AVAILABLE_DIR/node.example.com ]] || return 1; command nginx "$@"; }; '
                      'stream_create_fallback 1', input='node.example.com\ny\n', success=False)
        self.assertFalse((self.available / 'node.example.com').exists())
        (self.root / 'fail_reload').touch()
        self.run_bash('stream_create_fallback 1', input='node.example.com\ny\n', success=False)
        self.assertFalse((self.available / 'node.example.com').exists())
        self.run_bash('stream_create_fallback 1', input='node.example.com\ny\n')
        site = self.available / 'node.example.com'
        site.write_text(site.read_text().replace('listen 127.0.0.1:8443', 'listen 443'))
        before = {p: p.read_bytes() for p in self.available.iterdir()}
        self.run_bash('stream_transaction stream_do_enable', success=False)
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)

    def test_invalid_mode_metadata_blocks_site_deletion_and_updates(self):
        self.enable()
        self.add('node.example.com', 34138)
        (self.stream / 'node-modes.tsv').write_text('node.example.com\tunknown\n')
        self.run_bash('stream_guard_disable_site "$NGINX_SITES_AVAILABLE_DIR/node.example.com"', success=False)
        self.run_bash('stream_delete_fallback', input='node.example.com\ny\n', success=False)
        self.run_bash('stream_transaction stream_do_change_node_port node.example.com 39149 34138', success=False)

    def test_migrate_multiple_sites_preserves_content_and_disable(self):
        before = {p.name: p.read_text() for p in self.available.iterdir()}
        self.enable()
        for p in self.available.iterdir():
            self.assertEqual(p.read_text().replace('127.0.0.1:8443', '443'), before[p.name])
        self.run_bash('stream_transaction stream_do_disable')
        for p in self.available.iterdir():
            self.assertEqual(p.read_text(), before[p.name])
        self.assertFalse((self.stream / 'enabled').exists())

    def test_multiple_nodes_certificate_fallback_and_independent_delete(self):
        self.enable()
        self.add('node1.example.com', 34138)
        self.add('node2.example.com', 39149)
        text = (self.stream / 'stream.conf').read_text()
        self.assertIn('listen [::]:443', text)
        self.assertIn('node1.example.com npctl_reality_0;', text)
        self.assertIn('127.0.0.1:39149', text)
        self.assertIn('default npctl_https_fallback;', text)
        self.run_bash('stream_show_nodes')
        self.run_bash('stream_transaction stream_do_delete_node node1.example.com')
        self.assertTrue((self.available / 'node1.example.com').exists())
        self.assertTrue((self.cert / 'live/example.com/fullchain.pem').exists())
        self.assertNotIn('node1.example.com', (self.stream / 'nodes.tsv').read_text())

    def test_duplicate_invalid_and_reserved_nodes_rejected(self):
        self.enable()
        self.add('node1.example.com', 34138)
        for domain, port in [('node1.example.com', '39149'), ('node2.example.com', '34138'),
                             ('x;bad.example.com', '39149'), ('node2.example.com', '8443'),
                             ('node2.example.com', '000443'), ('node2.example.com', '999999999999999999')]:
            self.run_bash(f'stream_validate_node "{domain}" "{port}"', success=False)

    def test_edit_node_port_preserves_sites_certificates_and_other_mappings(self):
        self.enable()
        self.add('node1.example.com', 39149)
        self.add('node2.example.com', 39150)
        unchanged = {p: p.read_bytes() for p in [*self.available.iterdir(),
                    *self.cert.glob('live/*/*'), *self.root.glob('web/*/index.html')]}
        result = self.run_bash('manage_stream', input='7\nnode1.example.com\n34138\ny\nq\n')
        self.assertIn('已更新节点后端', result.stdout)
        self.assertEqual((self.stream / 'nodes.tsv').read_text(),
                         'node1.example.com\t34138\nnode2.example.com\t39150\n')
        content = (self.stream / 'stream.conf').read_text()
        self.assertIn('server 127.0.0.1:34138;', content)
        self.assertIn('server 127.0.0.1:39150;', content)
        self.assertNotIn('server 127.0.0.1:39149;', content)
        for path, data in unchanged.items():
            self.assertEqual(path.read_bytes(), data)

    def test_edit_node_port_rejects_invalid_reserved_and_duplicate_ports(self):
        self.enable()
        self.add('node1.example.com', 39149)
        self.add('node2.example.com', 34138)
        before = {p: p.read_bytes() for p in self.stream.iterdir()}
        for port in ('0', '65536', '0080', '80', '443', '8443', '34138', 'not-a-port'):
            with self.subTest(port=port):
                self.run_bash('stream_change_node_port', input=f'node1.example.com\n{port}\n', success=False)
                for path, data in before.items():
                    self.assertEqual(path.read_bytes(), data)

    def test_edit_node_port_uses_each_user_supplied_port(self):
        self.enable()
        self.add('node.example.com', 39149)
        for port in ('12001', '52347', '65535'):
            with self.subTest(port=port):
                self.run_bash('stream_change_node_port', input=f'node.example.com\n{port}\ny\n')
                self.assertEqual((self.stream / 'nodes.tsv').read_text(), f'node.example.com\t{port}\n')
                self.assertIn(f'server 127.0.0.1:{port};', (self.stream / 'stream.conf').read_text())

    def test_edit_node_port_noop_and_cancel_do_not_reload(self):
        self.enable()
        self.add('node.example.com', 39149)
        before = {p: p.read_bytes() for p in self.stream.iterdir()}
        calls = (self.root / 'systemctl.log').read_text().count('reload nginx')
        for answer in ('\n', 'node.example.com\n\n', 'node.example.com\n34138\nn\n'):
            self.run_bash('stream_change_node_port', input=answer)
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)
        self.assertEqual((self.root / 'systemctl.log').read_text().count('reload nginx'), calls)

    def test_edit_node_port_rolls_back_failed_check_or_reload(self):
        self.enable()
        self.add('node.example.com', 39149)
        nginx_stub = (self.bin / 'nginx').read_text()
        old_failure = 'if [[ -f $FIXTURE/fail_check && -f $FIXTURE/nginx/npctl-stream/enabled ]]; then exit 1; fi'
        self.assertIn(old_failure, nginx_stub)
        self.stub('nginx', nginx_stub.replace(old_failure,
                  'if [[ -f $FIXTURE/fail_check ]] && grep -Fq "server 127.0.0.1:34138;" "$FIXTURE/nginx/npctl-stream/stream.conf"; then exit 1; fi'))
        before = {p: p.read_bytes() for p in self.stream.iterdir()}
        for marker in ('fail_check', 'fail_reload'):
            with self.subTest(marker=marker):
                backups = len(list((self.root / 'backups').iterdir()))
                (self.root / marker).touch()
                self.run_bash('stream_change_node_port', input='node.example.com\n34138\ny\n', success=False)
                self.assertEqual(len(list((self.root / 'backups').iterdir())), backups + 1)
                for path, data in before.items():
                    self.assertEqual(path.read_bytes(), data)
                self.assertFalse((self.root / 'lock').exists())
                (self.root / marker).unlink(missing_ok=True)

    def test_edit_stored_node_port_does_not_enable_disabled_stream(self):
        self.enable()
        self.add('node.example.com', 39149)
        self.run_bash('stream_transaction stream_do_disable')
        original = (self.nginx / 'nginx.conf').read_bytes()
        site = (self.available / 'node.example.com').read_bytes()
        self.run_bash('stream_change_node_port', input='node.example.com\n34138\ny\n')
        self.assertEqual((self.stream / 'nodes.tsv').read_text(), 'node.example.com\t34138\n')
        self.assertFalse((self.stream / 'enabled').exists())
        self.assertFalse((self.stream / 'stream.conf').exists())
        self.assertEqual((self.nginx / 'nginx.conf').read_bytes(), original)
        self.assertEqual((self.available / 'node.example.com').read_bytes(), site)

    def test_edit_node_port_rejects_missing_or_concurrently_changed_mapping(self):
        self.enable()
        self.add('node.example.com', 39149)
        before = {p: p.read_bytes() for p in self.stream.iterdir()}
        self.run_bash('stream_change_node_port', input='missing.example.com\n', success=False)
        self.run_bash('stream_transaction stream_do_change_node_port node.example.com 34138 39148', success=False)
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)

    def test_new_ordinary_site_and_body_size_certificate_management(self):
        self.enable()
        self.create_site('new.example.com')
        self.assertIn('listen 127.0.0.1:8443 ssl http2;', (self.available / 'new.example.com').read_text())
        self.run_bash('''site="$NGINX_SITES_AVAILABLE_DIR/new.example.com"
is_npctl_managed_site_file "$site" || exit 1
[[ $(extract_site_client_max_body_size "$site") == 64M ]] || exit 1
rewrite_site_client_max_body_size_config "$site" set 2G "$site.tmp" || exit 1
[[ $(extract_site_client_max_body_size "$site.tmp") == 2G ]] || exit 1
rewrite_site_certificate_config "$site" example.com other.example.com "$site.cert" || exit 1
[[ $(extract_site_certificate_name_from_config "$site.cert") == other.example.com ]]
''')

    def test_certificate_must_cover_sni_and_not_expired(self):
        self.run_bash('stream_certificate_valid node.example.com example.com')
        self.run_bash('stream_certificate_valid node.other.com example.com', success=False)
        self.run_bash('stream_certificate_valid a.b.example.com example.com', success=False)
        expired = self.cert / 'live/expired.example.com'
        expired.mkdir()
        shutil.copy(self.cert / 'live/example.com/privkey.pem', expired / 'privkey.pem')
        subprocess.run(['openssl', 'x509', '-in', str(self.cert / 'live/example.com/fullchain.pem'),
                        '-signkey', str(expired / 'privkey.pem'), '-days', '0', '-out', str(expired / 'fullchain.pem')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.run_bash('stream_certificate_valid node.example.com expired.example.com', success=False)

    def test_old_openssl_zero_exit_on_hostname_mismatch_is_rejected(self):
        # OpenSSL 1.1.1/3.0 print a mismatch while returning success. Newer
        # OpenSSL returns failure; test the older real CLI behavior explicitly.
        self.stub('openssl', '''#!/bin/bash
while [[ $# -gt 0 ]]; do
  if [[ $1 == -checkhost ]]; then
    printf 'Hostname %s does NOT match certificate\\n' "$2"
    exit 0
  fi
  shift
done
exit 0
''')
        self.run_bash('stream_certificate_valid unrelated.example.net example.com', success=False)

    def test_existing_website_is_reused(self):
        self.enable()
        before = (self.available / 'blog.example.com').read_bytes()
        self.add('blog.example.com', 34138)
        self.assertEqual((self.available / 'blog.example.com').read_bytes(), before)

    def test_validation_failure_rolls_back_all_sites(self):
        before = (self.nginx / 'nginx.conf').read_bytes()
        sites = {p.name: p.read_bytes() for p in self.available.iterdir()}
        (self.root / 'fail_check').touch()
        self.run_bash('stream_transaction stream_do_enable', success=False)
        self.assertEqual((self.nginx / 'nginx.conf').read_bytes(), before)
        self.assertFalse((self.stream / 'enabled').exists())
        for p in self.available.iterdir():
            self.assertEqual(p.read_bytes(), sites[p.name])

    def test_reload_failure_restores_and_reloads_previous_config(self):
        before = (self.nginx / 'nginx.conf').read_bytes()
        (self.root / 'fail_reload').touch()
        self.run_bash('stream_transaction stream_do_enable', success=False)
        self.assertEqual((self.nginx / 'nginx.conf').read_bytes(), before)
        calls = (self.root / 'systemctl.log').read_text()
        self.assertEqual(calls.count('reload nginx'), 2)

    def test_third_party_443_rejected_and_external_socket_rejected(self):
        (self.nginx / 'conf.d/third.conf').write_text('server { listen 443; }\n')
        self.run_bash('stream_check_layout', success=False)
        (self.nginx / 'conf.d/third.conf').unlink()
        (self.root / 'sockets').write_text('LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("other",pid=123,fd=4))\n')
        self.run_bash('stream_check_layout', success=False)

    def test_unknown_listener_structure_rejected_without_partial_migration(self):
        before = (self.available / 'api.example.com').read_bytes()
        site = self.available / 'blog.example.com'
        site.write_text(site.read_text().replace('443 ssl http2;', '443 ssl http2 proxy_protocol;'))
        self.run_bash('stream_transaction stream_do_enable', success=False)
        self.assertEqual((self.available / 'api.example.com').read_bytes(), before)

    def test_repeated_enable_disable_and_manual_rollback(self):
        self.enable()
        before = (self.nginx / 'nginx.conf').read_bytes()
        self.run_bash('stream_enable')
        self.assertEqual((self.nginx / 'nginx.conf').read_bytes(), before)
        self.run_bash('stream_transaction stream_do_disable')
        self.run_bash('stream_disable')
        backup = sorted((self.root / 'backups').iterdir(), key=lambda p: p.stat().st_mtime)[-1]
        self.run_bash(f'bash "{backup}/rollback.sh"')
        self.assertTrue((self.stream / 'enabled').exists())

    def test_setup_repeated_install_uses_safe_update_and_keeps_sni(self):
        self.enable()
        before = {p: p.read_bytes() for p in [self.nginx / 'nginx.conf', self.stream / 'stream.conf', self.stream / 'enabled']}
        self.run_bash('''source "$1/setup.sh"
safe_update_npctl() { echo safe-update >> "$FIXTURE/setup.log"; }
setup_nginx_certbot
''', main=False)
        self.assertEqual((self.root / 'setup.log').read_text(), 'safe-update\n')
        for p, content in before.items():
            self.assertEqual(p.read_bytes(), content)

    def test_actual_safe_update_preserves_existing_stream_and_sites(self):
        self.enable()
        self.add('node.example.com', 39149)
        self.add_relay('remote.other.net', 34138)
        self.run_bash('stream_create_fallback 1', input='landing.example.com\ny\n')
        paths = [self.nginx / 'nginx.conf', *self.stream.iterdir(), *self.available.iterdir()]
        before = {p: p.read_bytes() for p in paths}
        self.stub('chown', '#!/bin/bash\nexit 0\n')
        self.run_bash('''source "$1/setup.sh"
install_missing_packages() { return 0; }
safe_update_npctl && safe_update_npctl
''', main=False)
        for p, content in before.items():
            self.assertEqual(p.read_bytes(), content)

    def test_ipv4_ipv6_listener_pair_is_restored_on_disable(self):
        site = self.available / 'blog.example.com'
        site.write_text(site.read_text().replace('listen 443 ssl http2;', 'listen 443 ssl http2;\n    listen [::]:443 ssl http2;'))
        self.enable()
        self.assertEqual(site.read_text().count('listen 127.0.0.1:8443'), 1)
        self.run_bash('stream_transaction stream_do_disable')
        self.assertIn('listen 443 ssl http2;', site.read_text())
        self.assertIn('listen [::]:443 ssl http2;', site.read_text())

    def test_websocket_http2_acme_redirect_and_certificate_references_preserved(self):
        self.enable()
        for site in self.available.iterdir():
            content = site.read_text()
            for expected in ('ssl http2;', 'listen 80;', 'acme-webroot.conf;', 'redirect-https-308.conf;',
                             'proxy-common.conf;', 'fullchain.pem;', 'privkey.pem;', 'client_max_body_size 64M;'):
                self.assertIn(expected, content)
        self.add('node.example.com', 39149)
        result = self.run_bash('load_certificate_referenced_sites example.com; printf "%s\\n" "${CERTIFICATE_REFERENCED_SITE_NAMES[@]}"')
        self.assertIn('node.example.com', result.stdout)
        self.run_bash('stream_guard_disable_site "$NGINX_SITES_AVAILABLE_DIR/node.example.com"', success=False)

    def test_foreign_metadata_and_cancelled_fallback_are_not_overwritten(self):
        (self.stream / 'nodes.tsv').write_text('foreign data\n')
        self.run_bash('stream_transaction stream_do_enable', success=False)
        self.assertEqual((self.stream / 'nodes.tsv').read_text(), 'foreign data\n')
        (self.stream / 'nodes.tsv').unlink()
        self.enable()
        self.run_bash('stream_prepare_website node.example.com', input='n\n', success=False)
        self.assertFalse((self.available / 'node.example.com').exists())

    def test_module_install_blocks_nginx_hooks_and_restores_host_policy(self):
        policy = self.root / 'usr/sbin/policy-rc.d'
        policy.parent.mkdir(parents=True)
        policy.write_text('#!/bin/bash\nexit 7\n')
        policy.chmod(0o755)
        before = policy.read_bytes()
        self.stub('apt', '#!/bin/bash\nexit 0\n')
        self.stub('apt-get', '''#!/bin/bash
if [[ $1 == -s ]]; then echo 'Inst libnginx-mod-stream (test)'; exit 0; fi
"$FIXTURE/usr/sbin/policy-rc.d" nginx reload
[[ $? == 101 ]] || exit 1
"$FIXTURE/usr/sbin/policy-rc.d" other start
[[ $? == 7 ]] || exit 1
[[ ! -f $FIXTURE/fail_package ]]
''')
        self.run_bash('stream_install_module_package')
        self.assertEqual(policy.read_bytes(), before)
        (self.root / 'fail_package').touch()
        self.run_bash('stream_install_module_package', success=False)
        self.assertEqual(policy.read_bytes(), before)

    @unittest.skipUnless(os.environ.get('NPCTL_TEST_NETNS') == '1' and os.environ.get('NPCTL_TEST_NGINX'),
                         'requires unpacked nginx and sudo unshare -n')
    def test_live_namespace_sni_tls_http_and_websocket(self):
        self.enable()
        self.add('node1.example.com', 34138)
        self.add('node2.example.com', 39149)
        self.run_live_smoke()

    @unittest.skipUnless(os.environ.get('NPCTL_TEST_NETNS') == '1' and os.environ.get('NPCTL_TEST_NGINX'),
                         'requires unpacked nginx and sudo unshare -n')
    def test_live_edited_node_port_routes_to_new_backend(self):
        self.enable()
        self.add('node1.example.com', 49149)
        self.add('node2.example.com', 39149)
        self.run_bash('stream_change_node_port', input='node1.example.com\n34138\ny\n')
        self.run_live_smoke()

    @unittest.skipUnless(os.environ.get('NPCTL_TEST_NETNS') == '1' and os.environ.get('NPCTL_TEST_NGINX'),
                         'requires unpacked nginx and sudo unshare -n')
    def test_live_pure_relay_has_no_local_https_or_node_certificates(self):
        self.remove_all_sites()
        self.add_relay('node1.example.com', 34138)
        self.add_relay('node2.example.com', 39149)
        self.assertFalse(list(self.available.iterdir()))
        self.assertNotIn('ssl_certificate', (self.stream / 'stream.conf').read_text())
        self.run_live_smoke('relay')

    @unittest.skipUnless(os.environ.get('NPCTL_TEST_NETNS') == '1' and os.environ.get('NPCTL_TEST_NGINX'),
                         'requires unpacked nginx and sudo unshare -n')
    def test_live_landing_https_works_without_stream_alongside_public_listener(self):
        self.remove_all_sites()
        self.run_bash('manage_stream', input='5\n4\nnode1.example.com\ny\nq\nq\n')
        self.assertFalse((self.stream / 'enabled').exists())
        self.run_live_smoke('local-only')

    def run_live_smoke(self, mode='full'):
        (self.root / 'acme/.well-known/acme-challenge').mkdir(parents=True)
        result = subprocess.run(['sudo', '-n', 'unshare', '-n', 'python3', str(REPO / 'tests/live_stream_smoke.py'),
                                 str(self.root), self.env['NPCTL_TEST_NGINX'], mode], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
