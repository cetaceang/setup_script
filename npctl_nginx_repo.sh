#!/bin/bash
# Shared by setup and npctl. Sourcing this file never changes the host.

nginx_repo_platform() {
  local ID='' VERSION_CODENAME='' UBUNTU_CODENAME=''
  local arch
  # shellcheck disable=SC1091
  . /etc/os-release || return 1
  case "$ID" in
    debian|ubuntu) ;;
    *) warn 'Nginx 官方 APT 源仅支持 Debian / Ubuntu。'; return 1 ;;
  esac
  local codename="${VERSION_CODENAME:-$UBUNTU_CODENAME}"
  [[ $codename =~ ^[a-z][a-z0-9-]*$ ]] || {
    warn '无法识别系统发行代号，未修改 Nginx 软件源。'; return 1;
  }
  arch=$(dpkg --print-architecture) || return 1
  case "$arch" in
    amd64|arm64) ;;
    *) warn "Nginx 官方源不支持当前架构 [$arch]。"; return 1 ;;
  esac
  printf '%s %s %s\n' "$ID" "$codename" "$arch"
}

nginx_setup_official_repo() (
  local platform distro codename arch work fingerprints fingerprint
  require_command apt-get '当前仅支持 Debian / Ubuntu。' || return 1
  require_command dpkg '请先安装 dpkg。' || return 1
  platform=$(nginx_repo_platform) || return 1
  read -r distro codename arch <<<"$platform"

  if ! command_exists curl || ! command_exists gpg ||
      ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -qx 'install ok installed'; then
    apt-get -o APT::Update::Error-Mode=any update || return 1
    apt-get install -y --no-install-recommends --no-upgrade curl gnupg ca-certificates || return 1
  fi

  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"' EXIT
  mkdir -m 0700 "$work/gnupg" || return 1
  # Check that the codename is served before writing any repository files.
  curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 \
    "https://nginx.org/packages/$distro/dists/$codename/Release" -o "$work/Release" || {
    warn "官方 stable 源不可用: $distro / $codename，未修改软件源。"; return 1;
  }
  curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 \
    https://nginx.org/keys/nginx_signing.key -o "$work/signing.key" || return 1
  gpg --homedir "$work/gnupg" --batch --dearmor \
    --output "$work/keyring.gpg" "$work/signing.key" || return 1
  fingerprints=$(gpg --homedir "$work/gnupg" --batch --with-colons --show-keys "$work/keyring.gpg") || return 1
  fingerprints=$(printf '%s\n' "$fingerprints" | awk -F: '
    $1 == "pub" { primary=1; next }
    $1 == "fpr" && primary { print $10; primary=0 }
  ')
  # nginx.org publishes these three primary signing keys. Reject unknown keys
  # rather than trusting an arbitrary key bundled with a recognized one.
  grep -qx '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62' <<<"$fingerprints" || {
    warn 'Nginx 签名密钥指纹校验失败，未修改软件源。'; return 1;
  }
  while IFS= read -r fingerprint; do
    case "$fingerprint" in
      573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62|\
      8540A6F18833A80E9C1653A42FD21310B49F6B46|\
      9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3) ;;
      *) warn "未知 Nginx 签名密钥 [$fingerprint]，请核对官方密钥公告。"; return 1 ;;
    esac
  done <<<"$fingerprints"

  mkdir -p /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d || return 1
  install -m 0644 "$work/keyring.gpg" /usr/share/keyrings/nginx-archive-keyring.gpg || return 1
  printf 'deb [arch=%s signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/%s %s nginx\n' \
    "$arch" "$distro" "$codename" >"$work/nginx.list" || return 1
  cat >"$work/99nginx" <<'EOF'
Package: nginx nginx-*
Pin: origin nginx.org
Pin-Priority: 900
EOF
  install -m 0644 "$work/nginx.list" /etc/apt/sources.list.d/nginx.list || return 1
  install -m 0644 "$work/99nginx" /etc/apt/preferences.d/99nginx || return 1
  echo "已配置 Nginx 官方 stable 源: $distro / $codename / $arch"
)

nginx_migration_plan_allowed() {
  awk '
    $1 == "Remv" { name=$2; sub(/:.*/, "", name); removed=1; if (name != "nginx-common") bad=1 }
    $1 == "Purg" { bad=1 }
    END { exit !(removed && !bad) }
  '
}

nginx_migrate_common_package() (
  local candidate=$1 plan=$2 answer backup='' dump was_active=0 stopped=0
  local policy=/usr/sbin/policy-rc.d had_policy=0 installed_policy=0 attempted=0 restored=0
  shift 2
  nginx_migration_plan_allowed <<<"$plan" || { warn '迁移计划包含不支持的软件包删除。'; return 1; }
  require_command systemctl '迁移需要 systemd 管理 Nginx。' || return 1
  require_command invoke-rc.d '迁移需要 invoke-rc.d 阻止软件包提前启动服务。' || return 1
  [[ -d /etc/nginx && ! -L /etc/nginx ]] || { warn '迁移仅支持普通 /etc/nginx 目录。'; return 1; }
  nginx -t || return 1
  dump=$(nginx -T) || return 1
  if grep -Eq '(^|[;{}])[[:space:]]*load_module([[:space:]]|$)' <<<"$dump"; then
    warn '已加载动态模块，不能直接切换到官方内核；请先处理模块 ABI 兼容性。'
    return 1
  fi
  printf '%s\n' "$plan"
  warn '将替换发行版 nginx，仅移除 nginx-common（不 purge），完整备份并恢复 /etc/nginx。'
  warn '迁移会短暂停止 Nginx；若安装失败，软件包版本不会自动回滚。'
  read -r -p '确认迁移到官方 Nginx？[y/N]: ' answer || return 1
  case "$answer" in y|Y|yes|YES) ;; *) echo '已取消迁移，未修改软件包。'; return 1 ;; esac

  umask 077
  mkdir /run/npctl-nginx-migration.lock 2>/dev/null || { warn '另一个 Nginx 迁移正在进行。'; return 1; }
  restore_migration_config() {
    [[ $attempted == 1 && $restored == 0 ]] || return 0
    # Keep the package-generated tree for diagnosis; restore the exact original
    # tree so a newly added conf.d/default.conf cannot hijack existing sites.
    if [[ -e /etc/nginx && ! -e $backup/package-nginx ]]; then
      mv /etc/nginx "$backup/package-nginx" || return 1
    fi
    mkdir -p /etc/nginx || return 1
    cp -a "$backup/nginx/." /etc/nginx/ || return 1
    restored=1
  }
  cleanup_migration() {
    local status=$?
    trap - EXIT INT TERM HUP
    restore_migration_config || { warn "配置恢复失败，请立即从 [$backup/nginx] 手动恢复。"; status=1; }
    if [[ $installed_policy == 1 ]]; then rm -f "$policy"; fi
    if [[ $had_policy == 1 ]]; then
      mv "$backup/policy-rc.d" "$policy" || { warn "请恢复系统服务策略: $backup/policy-rc.d → $policy"; status=1; }
    fi
    if [[ $status != 0 && $attempted == 1 ]]; then
      warn "迁移未完成；原配置备份: $backup/nginx。请检查 nginx -t 和 dpkg --audit，软件包未自动回滚。"
      if [[ $stopped == 1 && $restored == 1 ]] && nginx -t; then
        systemctl daemon-reload
        systemctl start nginx || warn '恢复启动 Nginx 失败，请立即手动检查服务。'
      fi
    fi
    rmdir /run/npctl-nginx-migration.lock
    exit "$status"
  }
  trap cleanup_migration EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  mkdir -p /var/backups/npctl || return 1
  backup=$(mktemp -d "/var/backups/npctl/nginx-migration-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || return 1
  cp -a /etc/nginx "$backup/nginx" || return 1
  printf '%s\n' "$dump" >"$backup/nginx-T.txt"
  printf '%s\n' "$plan" >"$backup/apt-plan.txt"
  dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' nginx nginx-common >"$backup/packages.txt" || return 1
  echo "迁移备份: $backup"

  # Enforce the removal allowlist inside APT's transaction, not just in a
  # prior simulation. Abort before dpkg if the dependency plan has changed.
  cat >"$backup/guard-removals" <<'EOF'
#!/bin/sh
awk '
  NR == 1 { if ($0 != "VERSION 2") exit 1; next }
  !actions && $0 == "" { actions=1; next }
  actions && $5 == "**REMOVE**" {
    name=$1; sub(/:.*/, "", name)
    if (name != "nginx-common") { print "Unexpected package removal: " $1 > "/dev/stderr"; exit 1 }
  }
  END { if (!actions) exit 1 }
'
EOF
  chmod 0700 "$backup/guard-removals" || return 1
  # Finish all downloads before introducing any service downtime.
  DEBIAN_FRONTEND=noninteractive apt-get --download-only -y -o APT::Get::Purge=false \
    install "$@" "nginx=$candidate" || return 1

  if [[ -e $policy || -L $policy ]]; then
    if [[ -x $policy ]]; then cp -Lp "$policy" "$backup/delegate-policy" || return 1; fi
    mv "$policy" "$backup/policy-rc.d" || return 1
    had_policy=1
  fi
  installed_policy=1
  {
    printf '#!/bin/bash\noriginal=%q\n' "$backup/delegate-policy"
    cat <<'EOF'
case ${1##*/} in nginx|nginx.service) exit 101 ;; esac
if [[ -x $original ]]; then exec "$original" "$@"; fi
exit 0
EOF
  } >"$policy" || return 1
  chmod 0755 "$policy" || return 1
  if systemctl is-active --quiet nginx; then was_active=1; fi
  systemctl stop nginx || return 1
  stopped=$was_active
  attempted=1
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get \
    -o APT::Get::Purge=false \
    -o "DPkg::Pre-Install-Pkgs::=$backup/guard-removals" \
    -o "DPkg::Tools::Options::$backup/guard-removals::Version=2" \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install -y "$@" "nginx=$candidate" || return 1
  restore_migration_config || return 1
  systemctl daemon-reload || return 1
  nginx -t || return 1
  if [[ $was_active == 1 ]]; then systemctl start nginx || return 1; fi
  stopped=0
  echo "已完成官方 Nginx 迁移，原配置完整保留；备份: $backup"
)

nginx_install_official_package() {
  local policy candidate versions plan
  nginx_setup_official_repo || return 1
  apt-get -o APT::Update::Error-Mode=any update || return 1
  policy=$(LC_ALL=C apt-cache policy nginx) || return 1
  candidate=$(awk '$1 == "Candidate:" { print $2; exit }' <<<"$policy")
  versions=$(LC_ALL=C apt-cache madison nginx) || return 1
  # Pinning alone is insufficient if a third-party source has a higher pin.
  # Require the selected version to actually exist in the official stable repo.
  if [[ ! $candidate || $candidate == '(none)' ]] || ! awk -F '|' -v version="$candidate" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+/, "", $3) }
    $2 == version && $3 ~ /^https:\/\/nginx\.org\/packages\/(debian|ubuntu) / { found=1 }
    END { exit !found }
  ' <<<"$versions"; then
    warn '候选 nginx 软件包不来自 nginx.org stable 源；请检查其他源、APT pin 或已安装的更高版本。'
    return 1
  fi
  echo "Nginx 官方 stable 候选版本: $candidate"
  if ! apt-get -s --no-remove install "$@" "nginx=$candidate"; then
    echo '检测到软件包冲突，检查是否仅需受控替换 nginx-common。'
    plan=$(LC_ALL=C apt-get -s -o APT::Get::Purge=false install "$@" "nginx=$candidate") || return 1
    if nginx_migration_plan_allowed <<<"$plan"; then
      nginx_migrate_common_package "$candidate" "$plan" "$@"
      return $?
    fi
    warn '无法无损安装官方包。发行版 nginx-common / nginx-core 或 libnginx-mod-* 可能冲突。'
    warn '未删除任何软件包；请先备份 /etc/nginx，手动处理旧包和动态模块兼容性后重试，勿直接 purge 配置。'
    return 1
  fi
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get --no-remove \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install -y "$@" "nginx=$candidate"
}
