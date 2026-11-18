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

nginx_install_official_package() {
  local policy candidate versions
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
    warn '无法无损安装官方包。发行版 nginx-common / nginx-core 或 libnginx-mod-* 可能冲突。'
    warn '未删除任何软件包；请先备份 /etc/nginx，手动处理旧包和动态模块兼容性后重试，勿直接 purge 配置。'
    return 1
  fi
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get --no-remove \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install -y "$@" "nginx=$candidate"
}
