#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOT_DNS="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google 9.9.9.9#dns.quad9.net"
PLAIN_DNS="1.1.1.1 8.8.8.8"
PLAIN_FALLBACK_DNS="9.9.9.9"
RESOLVED_CONFIG_DIR="/etc/systemd/resolved.conf.d"
DOT_DNS_CONFIG="${RESOLVED_CONFIG_DIR}/dot.conf"
PLAIN_DNS_CONFIG="${RESOLVED_CONFIG_DIR}/dns.conf"
BASE_PACKAGES=(vim curl bubblewrap)
SECURITY_PACKAGES=(ufw fail2ban)
NGINX_PACKAGES=(nginx certbot python3-certbot-dns-cloudflare)
NPCTL_SOURCE_SCRIPT="${SCRIPT_DIR}/nginx_proxy_control.sh"
NPCTL_TARGET_PATH="/usr/local/bin/npctl"
CLOUDFLARE_CREDENTIALS_DIR="/root/.secrets/certbot"
PACKAGE_INDEX_UPDATED=0
LAST_ENSURE_CREATED=0
declare -a SAFE_UPDATE_CREATED_FILES=()

log() {
  echo
  echo ">>> $1"
}

warn() {
  echo "!!! $1" >&2
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 运行此脚本"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  local cmd="$1"
  local hint="$2"

  if ! command_exists "$cmd"; then
    warn "未找到命令 [$cmd]。$hint"
    return 1
  fi
}

install_packages() {
  local packages=("$@")

  if [ "$PACKAGE_INDEX_UPDATED" -eq 0 ]; then
    apt update || return 1
    PACKAGE_INDEX_UPDATED=1
  fi

  apt install -y "${packages[@]}" || return 1
}

package_installed() {
  local package="$1"

  if ! command_exists "dpkg-query"; then
    return 1
  fi

  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$'
}

install_missing_packages() {
  local package
  local -a missing_packages=()

  if ! command_exists "dpkg-query"; then
    warn "未找到 dpkg-query，将直接尝试安装所需软件包。"
    install_packages "$@" || return 1
    return 0
  fi

  for package in "$@"; do
    if ! package_installed "$package"; then
      missing_packages+=("$package")
    fi
  done

  if [ "${#missing_packages[@]}" -eq 0 ]; then
    echo "相关软件包已安装，跳过依赖安装。"
    return 0
  fi

  echo "安装缺失软件包: ${missing_packages[*]}"
  install_packages "${missing_packages[@]}" || return 1
}

ensure_directory_if_missing() {
  local target_dir="$1"
  local owner="${2:-}"
  local mode="${3:-}"

  LAST_ENSURE_CREATED=0

  if [ -d "$target_dir" ]; then
    return 0
  fi

  if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
    warn "路径 [$target_dir] 已存在但不是目录，无法自动补齐。"
    return 1
  fi

  mkdir -p "$target_dir" || return 1
  LAST_ENSURE_CREATED=1

  if [ -n "$owner" ]; then
    chown "$owner" "$target_dir" || return 1
  fi

  if [ -n "$mode" ]; then
    chmod "$mode" "$target_dir" || return 1
  fi
}

ensure_file_if_missing() {
  local target_file="$1"
  local writer_func="$2"

  LAST_ENSURE_CREATED=0

  if [ -d "$target_file" ]; then
    warn "路径 [$target_file] 已存在但不是普通文件，无法自动补齐。"
    return 1
  fi

  if [ -e "$target_file" ] || [ -L "$target_file" ]; then
    return 0
  fi

  "$writer_func" || return 1
  LAST_ENSURE_CREATED=1
  SAFE_UPDATE_CREATED_FILES+=("$target_file")
}

rollback_safe_update_created_files() {
  local idx
  local target_file

  if [ "${#SAFE_UPDATE_CREATED_FILES[@]}" -eq 0 ]; then
    return 0
  fi

  for ((idx=${#SAFE_UPDATE_CREATED_FILES[@]} - 1; idx >= 0; idx--)); do
    target_file="${SAFE_UPDATE_CREATED_FILES[$idx]}"

    if [ -e "$target_file" ] || [ -L "$target_file" ]; then
      rm -f "$target_file" || warn "删除 [$target_file] 失败，请手动检查。"
    fi
  done

  SAFE_UPDATE_CREATED_FILES=()
}

ensure_resolved_ready() {
  local install_dot_dependencies="${1:-0}"
  local dns_ok=0
  local resolved_ok=0

  require_command "systemctl" "当前系统不支持 systemd。" || return 1

  echo "检查当前 DNS..."
  if getent hosts deb.debian.org >/dev/null 2>&1; then
    dns_ok=1
    echo "当前 DNS 可用。"
  else
    warn "当前 DNS 不可用，将避免执行 apt。"
  fi

  echo "检查 systemd-resolved..."
  if systemctl cat systemd-resolved >/dev/null 2>&1 && command_exists "resolvectl"; then
    resolved_ok=1
    echo "systemd-resolved 与 resolvectl 已可用。"
  else
    warn "systemd-resolved 或 resolvectl 不可用。"
  fi

  if [ "$dns_ok" -eq 1 ]; then
    if [ "$install_dot_dependencies" -eq 1 ]; then
      echo "安装/更新 DoT 相关依赖..."
      install_packages ca-certificates || warn "安装 ca-certificates 失败，继续尝试 DoT 配置。"
    fi

    echo "安装/更新 DNS 验证工具..."
    install_packages dnsutils || warn "安装 dnsutils 失败，将跳过 dig 验证。"

    if [ "$resolved_ok" -eq 0 ]; then
      echo "尝试安装 systemd-resolved..."
      if apt-cache show systemd-resolved >/dev/null 2>&1; then
        apt install -y systemd-resolved || return 1
      else
        warn "软件源中没有 systemd-resolved 包。"
        warn "在某些 Debian 版本中，它可能包含在 systemd 包中。"
      fi
    fi
  else
    echo "跳过 apt，因为当前 DNS 不可用。"
  fi

  echo "重新检查 systemd-resolved..."
  if ! systemctl cat systemd-resolved >/dev/null 2>&1; then
    warn "systemd-resolved.service 不存在。"
    warn "DNS 不可用且 systemd-resolved 不可用，无法安全继续。"
    return 1
  fi

  if ! command_exists "resolvectl"; then
    warn "systemd-resolved 存在，但 resolvectl 不存在。请检查 systemd 安装。"
    return 1
  fi
}

backup_resolv_conf() {
  local backup_path

  echo "备份 /etc/resolv.conf..."
  if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
    backup_path="/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp -a /etc/resolv.conf "$backup_path" || warn "备份 /etc/resolv.conf 失败，继续配置。"

    if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
      echo "已备份到 $backup_path"
    fi
  fi
}

write_dot_dns_config() {
  echo "写入 DNS-over-TLS 配置..."
  mkdir -p "$RESOLVED_CONFIG_DIR" || return 1

  cat > "$DOT_DNS_CONFIG" <<EOF
[Resolve]
DNS=$DOT_DNS
FallbackDNS=
DNSOverTLS=yes
DNSSEC=no
Cache=yes
Domains=~.
EOF

  rm -f "$PLAIN_DNS_CONFIG" || return 1
}

write_plain_dns_config() {
  echo "写入普通 DNS 配置..."
  mkdir -p "$RESOLVED_CONFIG_DIR" || return 1

  cat > "$PLAIN_DNS_CONFIG" <<EOF
[Resolve]
DNS=$PLAIN_DNS
FallbackDNS=$PLAIN_FALLBACK_DNS
DNSOverTLS=no
EOF

  rm -f "$DOT_DNS_CONFIG" || return 1
}

activate_resolved_dns() {
  echo "启用并重启 systemd-resolved..."
  systemctl enable --now systemd-resolved || return 1
  systemctl restart systemd-resolved || return 1

  echo "将 /etc/resolv.conf 指向 systemd-resolved stub..."
  rm -f /etc/resolv.conf || return 1
  ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || return 1
}

test_resolved_dns() {
  echo "测试 DNS..."
  sleep 2
  resolvectl flush-caches || true

  echo
  echo "===== resolvectl status ====="
  resolvectl status || true

  echo
  echo "===== Test google.com ====="
  resolvectl query google.com || true

  echo
  echo "===== Test deb.debian.org ====="
  resolvectl query deb.debian.org || true
  getent hosts deb.debian.org || true

  echo
  echo "===== Optional dig test ====="
  if command_exists "dig"; then
    dig google.com A +short || true
  else
    echo "dig 未安装，已跳过。"
  fi
}

setup_dot_dns() {
  log "1.1 使用 DNS-over-TLS"
  ensure_resolved_ready 1 || return 1
  backup_resolv_conf || return 1
  write_dot_dns_config || return 1
  activate_resolved_dns || return 1
  test_resolved_dns || return 1
}

setup_plain_dns() {
  log "1.2 使用普通 DNS"
  ensure_resolved_ready 0 || return 1
  backup_resolv_conf || return 1
  write_plain_dns_config || return 1
  activate_resolved_dns || return 1
  test_resolved_dns || return 1
}

show_dns_menu() {
  cat <<'EOF'

================ DNS 设置菜单 ================
 1. 使用 DNS-over-TLS (DoT)
 2. 使用普通 DNS (1.1.1.1 / 8.8.8.8)
 q. 返回上级菜单
============================================
每次请输入一个编号
EOF
}

setup_dns() {
  local selection

  log "1. 更改 DNS 设置"

  while true; do
    show_dns_menu
    read -rp "请输入要执行的编号: " selection

    if [ -z "${selection}" ]; then
      warn "未输入任何选项，请重新输入。"
      continue
    fi

    case "$selection" in
      1)
        setup_dot_dns || return 1
        return 0
        ;;
      2)
        setup_plain_dns || return 1
        return 0
        ;;
      q|Q)
        echo "已返回上级菜单。"
        return 0
        ;;
      *)
        warn "无效选项 [$selection]"
        ;;
    esac
  done
}

install_base_tools() {
  log "2. 更新软件源并安装基础工具 (${BASE_PACKAGES[*]})"
  install_packages "${BASE_PACKAGES[@]}" || return 1

  echo "验证 bubblewrap..."
  which bwrap || return 1
  bwrap --version || return 1
}

setup_security() {
  log "3. 安装并配置 UFW / Fail2Ban"
  require_command "systemctl" "当前系统不支持 systemd。" || return 1
  install_packages "${SECURITY_PACKAGES[@]}" || return 1

  ufw default deny incoming || return 1
  ufw default allow outgoing || return 1
  ufw allow ssh || return 1
  ufw allow http || return 1
  ufw allow https || return 1
  ufw --force enable || return 1
  ufw status verbose || return 1

  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF

  systemctl restart fail2ban || return 1
  systemctl enable fail2ban || return 1
}

set_timezone() {
  log "4. 设置时区为 Asia/Shanghai"
  require_command "timedatectl" "当前系统不支持 timedatectl。" || return 1

  timedatectl set-timezone Asia/Shanghai || return 1
  timedatectl || return 1
}

install_docker() {
  local docker_script

  log "6.1 安装 Docker (官方脚本)"
  require_command "curl" "请先执行 [2. 安装基础工具]。" || return 1

  docker_script="$(mktemp /tmp/get-docker.XXXXXX.sh)"
  curl -fsSL https://get.docker.com -o "$docker_script" || return 1
  sh "$docker_script" || return 1
  rm -f "$docker_script"
}

configure_docker_logging() {
  log "6.2 配置 Docker 日志 (json-file, 10m)"
  require_command "systemctl" "当前系统不支持 systemd。" || return 1
  require_command "docker" "请先执行 [6. 安装并配置 Docker]。" || return 1

  mkdir -p /etc/docker || return 1

  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

  echo "重启 Docker 服务..."
  systemctl restart docker || return 1
}

choose_target_user() {
  local input_user
  local default_user=""

  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    default_user="${SUDO_USER}"
  fi

  while true; do
    if [ -n "$default_user" ]; then
      read -rp "请输入要加入 docker 组的用户名 [默认: ${default_user}]: " input_user
      input_user="${input_user:-$default_user}"
    else
      read -rp "请输入要加入 docker 组的用户名: " input_user
    fi

    if id "$input_user" >/dev/null 2>&1; then
      echo "$input_user"
      return 0
    fi

    warn "用户 [$input_user] 不存在，请重新输入。"
  done
}

choose_new_username() {
  local input_user

  while true; do
    read -rp "请输入要创建的新用户名: " input_user

    if [ -z "$input_user" ]; then
      warn "用户名不能为空。"
      continue
    fi

    if id "$input_user" >/dev/null 2>&1; then
      warn "用户 [$input_user] 已存在，请重新输入。"
      continue
    fi

    if [[ ! "$input_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
      warn "用户名格式无效，请使用字母、数字、下划线或中横线，并以字母或下划线开头。"
      continue
    fi

    echo "$input_user"
    return 0
  done
}

create_sudo_user() {
  local new_user

  log "5. 创建新用户并加入 sudo 组"
  require_command "adduser" "当前系统缺少 adduser。" || return 1
  require_command "passwd" "当前系统缺少 passwd。" || return 1
  require_command "usermod" "当前系统缺少 usermod。" || return 1

  if ! getent group sudo >/dev/null 2>&1; then
    warn "未检测到 sudo 组，无法继续。"
    return 1
  fi

  new_user="$(choose_new_username)" || return 1
  adduser --disabled-password --gecos "" "$new_user" || return 1
  usermod -aG sudo "$new_user" || return 1

  echo "请为用户 [$new_user] 设置密码："
  passwd "$new_user" || return 1

  echo "已创建用户 [$new_user] 并加入 sudo 组。"
}

configure_docker_user() {
  local target_user

  log "6.3 配置 Docker 用户权限"

  if ! getent group docker >/dev/null 2>&1; then
    warn "未检测到 docker 组。请先执行 [6. 安装并配置 Docker]。"
    return 1
  fi

  target_user="$(choose_target_user)" || return 1
  usermod -aG docker "$target_user" || return 1
  echo "已将用户 [$target_user] 加入 docker 组。"
}

verify_docker() {
  log "6.4 验证 Docker 版本"
  require_command "docker" "请先执行 [6. 安装并配置 Docker]。" || return 1

  docker --version || return 1

  if docker compose version >/dev/null 2>&1; then
    docker compose version || return 1
  else
    warn "未检测到 docker compose 插件。"
  fi
}

setup_docker() {
  log "6. 安装并配置 Docker"
  install_docker || return 1
  configure_docker_logging || return 1
  configure_docker_user || return 1
  verify_docker || return 1
}

check_swap_platform() {
  if [ -d "/proc/vz" ]; then
    warn "当前 VPS 基于 OpenVZ，不支持此 Swap 流程。"
    return 1
  fi
}

swap_exists() {
  grep -q '^/swapfile ' /etc/fstab
}

add_swap() {
  local swapsize

  require_command "fallocate" "当前系统缺少 fallocate。" || return 1
  require_command "chmod" "当前系统缺少 chmod。" || return 1
  require_command "mkswap" "当前系统缺少 mkswap。" || return 1
  require_command "swapon" "当前系统缺少 swapon。" || return 1

  if swap_exists; then
    warn "检测到 /swapfile 已存在，请先删除现有 Swap。"
    return 1
  fi

  while true; do
    echo "请输入需要添加的 swap 大小，建议为内存的 2 倍。"
    read -rp "请输入 swap 数值（单位 MiB）: " swapsize

    if [[ "$swapsize" =~ ^[0-9]+$ ]] && [ "$swapsize" -gt 0 ]; then
      break
    fi

    warn "请输入大于 0 的整数。"
  done

  log "创建 /swapfile (${swapsize} MiB)"
  fallocate -l "${swapsize}M" /swapfile || return 1
  chmod 600 /swapfile || return 1
  mkswap /swapfile || return 1
  swapon /swapfile || return 1
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab || return 1

  echo "Swap 创建成功，当前信息如下："
  cat /proc/swaps || return 1
  grep '^Swap' /proc/meminfo || return 1
}

delete_swap() {
  require_command "swapoff" "当前系统缺少 swapoff。" || return 1
  require_command "sed" "当前系统缺少 sed。" || return 1
  require_command "rm" "当前系统缺少 rm。" || return 1

  if ! swap_exists; then
    warn "未检测到 /swapfile，无法删除。"
    return 1
  fi

  log "删除 /swapfile"
  sed -i '\#^/swapfile #d' /etc/fstab || return 1
  echo "3" > /proc/sys/vm/drop_caches || return 1
  swapoff -a || return 1
  rm -f /swapfile || return 1
  echo "Swap 已删除。"
}

show_swap_menu() {
  cat <<'EOF'

================ Swap 管理菜单 ================
 1. 添加 Swap
 2. 删除 Swap
 q. 返回上级菜单
=============================================
每次请输入一个编号
EOF
}

setup_swap() {
  local selection

  log "7. 管理 Swap"
  check_swap_platform || return 1

  while true; do
    show_swap_menu
    read -rp "请输入要执行的编号: " selection

    if [ -z "${selection}" ]; then
      warn "未输入任何选项，请重新输入。"
      continue
    fi

    case "$selection" in
      1)
        add_swap || return 1
        return 0
        ;;
      2)
        delete_swap || return 1
        return 0
        ;;
      q|Q)
        echo "已返回上级菜单。"
        return 0
        ;;
      *)
        warn "无效选项 [$selection]"
        ;;
    esac
  done
}

write_nginx_main_config() {
  cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    proxy_cache_path /var/cache/nginx/assets_cache
        levels=1:2
        keys_zone=assets_cache:200m
        max_size=1g
        inactive=7d
        use_temp_path=off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
}

write_nginx_acme_config() {
  cat > /etc/nginx/conf.d/acme.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        try_files $uri =404;
    }

    location / {
        return 404;
    }
}
EOF
}

write_nginx_snippet_acme_webroot() {
  cat > /etc/nginx/snippets/acme-webroot.conf <<'EOF'
location ^~ /.well-known/acme-challenge/ {
    root /var/www/acme;
    try_files $uri =404;
}
EOF
}

write_nginx_snippet_redirect_https() {
  cat > /etc/nginx/snippets/redirect-https-308.conf <<'EOF'
location / {
    return 308 https://$host$request_uri;
}
EOF
}

write_nginx_snippet_security_headers() {
  cat > /etc/nginx/snippets/security-headers.conf <<'EOF'
add_header Strict-Transport-Security "max-age=63072000" always;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header Referrer-Policy no-referrer always;
EOF
}

write_nginx_snippet_proxy_common() {
  cat > /etc/nginx/snippets/proxy-common.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_read_timeout  300;
proxy_send_timeout  300;
EOF
}

write_nginx_snippet_cache_assets() {
  cat > /etc/nginx/snippets/cache-assets.optional.conf <<'EOF'
expires 30d;
add_header Cache-Control "public, max-age=2592000, immutable" always;
access_log off;
EOF
}

write_nginx_snippet_proxy_cache_assets() {
  cat > /etc/nginx/snippets/proxy-cache-assets.optional.conf <<'EOF'
proxy_cache assets_cache;
proxy_cache_key "$scheme$request_method$host$request_uri";
proxy_cache_valid 200 206 301 302 30m;
proxy_cache_valid 404 1m;
proxy_cache_lock on;
proxy_cache_revalidate on;
proxy_cache_min_uses 1;
proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;
add_header X-Proxy-Cache $upstream_cache_status always;
EOF
}

write_nginx_snippet_block_common_exploits() {
  cat > /etc/nginx/snippets/block-common-exploits.optional.conf <<'EOF'
location ~ /\.(?!well-known) {
    deny all;
}

location ~* \.(?:bak|conf|dist|ini|log|old|orig|save|sql|swp)$ {
    deny all;
}
EOF
}

write_nginx_snippets() {
  mkdir -p /etc/nginx/snippets || return 1

  write_nginx_snippet_acme_webroot || return 1
  write_nginx_snippet_redirect_https || return 1
  write_nginx_snippet_security_headers || return 1
  write_nginx_snippet_proxy_common || return 1
  write_nginx_snippet_cache_assets || return 1
  write_nginx_snippet_proxy_cache_assets || return 1
  write_nginx_snippet_block_common_exploits || return 1
}

write_letsencrypt_options_file() {
  cat > /etc/letsencrypt/options-ssl-nginx.conf <<'EOF'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
EOF
}

write_letsencrypt_dhparams_file() {
  cat > /etc/letsencrypt/ssl-dhparams.pem <<'EOF'
-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----
EOF
}

write_letsencrypt_tls_files() {
  mkdir -p /etc/letsencrypt || return 1

  write_letsencrypt_options_file || return 1
  write_letsencrypt_dhparams_file || return 1
}

install_npctl_command() {
  if [ ! -f "$NPCTL_SOURCE_SCRIPT" ]; then
    warn "未找到 npctl 源脚本 [$NPCTL_SOURCE_SCRIPT]。"
    return 1
  fi

  mkdir -p /usr/local/bin || return 1
  cp "$NPCTL_SOURCE_SCRIPT" "$NPCTL_TARGET_PATH" || return 1
  chmod 0755 "$NPCTL_TARGET_PATH" || return 1
}

safe_update_npctl() {
  local nginx_files_created=0

  log "9. 安全更新 npctl 并补齐缺失依赖"
  SAFE_UPDATE_CREATED_FILES=()

  install_missing_packages "${NGINX_PACKAGES[@]}" || return 1

  ensure_directory_if_missing /var/cache/nginx || return 1
  ensure_directory_if_missing /var/cache/nginx/assets_cache "www-data:www-data" || return 1
  ensure_directory_if_missing /var/www/acme "www-data:www-data" || return 1
  ensure_directory_if_missing /var/www/acme/.well-known "www-data:www-data" || return 1
  ensure_directory_if_missing /var/www/acme/.well-known/acme-challenge "www-data:www-data" || return 1
  ensure_directory_if_missing /etc/nginx/conf.d || return 1
  ensure_directory_if_missing /etc/nginx/snippets || return 1
  ensure_directory_if_missing /etc/nginx/sites-available || return 1
  ensure_directory_if_missing /etc/nginx/sites-enabled || return 1
  ensure_directory_if_missing /etc/letsencrypt || return 1
  ensure_directory_if_missing /root/.secrets "" "0700" || return 1
  ensure_directory_if_missing "$CLOUDFLARE_CREDENTIALS_DIR" "" "0700" || return 1

  ensure_file_if_missing /etc/nginx/conf.d/acme.conf write_nginx_acme_config || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/nginx/snippets/acme-webroot.conf write_nginx_snippet_acme_webroot || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/nginx/snippets/redirect-https-308.conf write_nginx_snippet_redirect_https || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/nginx/snippets/security-headers.conf write_nginx_snippet_security_headers || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/nginx/snippets/proxy-common.conf write_nginx_snippet_proxy_common || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/nginx/snippets/cache-assets.optional.conf write_nginx_snippet_cache_assets || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/nginx/snippets/proxy-cache-assets.optional.conf write_nginx_snippet_proxy_cache_assets || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/nginx/snippets/block-common-exploits.optional.conf write_nginx_snippet_block_common_exploits || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/letsencrypt/options-ssl-nginx.conf write_letsencrypt_options_file || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  ensure_file_if_missing /etc/letsencrypt/ssl-dhparams.pem write_letsencrypt_dhparams_file || return 1
  if [ "$LAST_ENSURE_CREATED" -eq 1 ]; then
    nginx_files_created=1
  fi

  log "9.1 安装 npctl 命令"
  install_npctl_command || return 1

  if [ "$nginx_files_created" -eq 1 ]; then
    log "检查 Nginx 配置"

    if ! nginx -t; then
      warn "Nginx 配置校验失败，已删除本次补齐的新建文件。"
      rollback_safe_update_created_files
      return 1
    fi

    if command_exists "systemctl" && systemctl is-active --quiet nginx; then
      log "重载 Nginx"

      if ! systemctl reload nginx; then
        warn "Nginx 重载失败，已删除本次补齐的新建文件。"
        rollback_safe_update_created_files
        return 1
      fi
    else
      warn "检测到本次补齐了 Nginx 相关文件，但 nginx 服务未运行，已跳过自动重载。"
    fi
  fi

  SAFE_UPDATE_CREATED_FILES=()

  echo "已安全更新 npctl。"
  echo "缺失依赖已安装，已有配置文件未被覆盖。"

  if [ "$nginx_files_created" -eq 1 ]; then
    echo "本次补齐了缺失的 Nginx / Certbot 基础文件。"
  else
    echo "本次未创建新的 Nginx / Certbot 基础文件。"
  fi
}

setup_nginx_certbot() {
  log "8. 安装并配置 Nginx / Certbot / Cloudflare DNS 插件"
  require_command "systemctl" "当前系统不支持 systemd。" || return 1

  install_packages "${NGINX_PACKAGES[@]}" || return 1
  systemctl enable --now nginx || return 1

  mkdir -p /var/cache/nginx/assets_cache || return 1
  chown -R www-data:www-data /var/cache/nginx/assets_cache || return 1

  mkdir -p /var/www/acme/.well-known/acme-challenge || return 1
  chown -R www-data:www-data /var/www/acme || return 1

  mkdir -p /etc/nginx/conf.d || return 1
  mkdir -p /etc/nginx/snippets || return 1
  mkdir -p /etc/nginx/sites-available || return 1
  mkdir -p /etc/nginx/sites-enabled || return 1
  mkdir -p "$CLOUDFLARE_CREDENTIALS_DIR" || return 1
  chmod 0700 /root/.secrets || return 1
  chmod 0700 "$CLOUDFLARE_CREDENTIALS_DIR" || return 1

  if [ -L /etc/nginx/sites-enabled/default ]; then
    unlink /etc/nginx/sites-enabled/default || return 1
  fi

  write_nginx_main_config || return 1
  write_nginx_acme_config || return 1
  write_nginx_snippets || return 1
  write_letsencrypt_tls_files || return 1
  log "8.1 安装 npctl 命令"
  install_npctl_command || return 1

  nginx -t || return 1
  systemctl reload nginx || return 1
}

show_menu() {
  cat <<'EOF'

================ 服务器初始化交互菜单 ================
 1. 更改 DNS 设置
 2. 更新软件源并安装基础工具
 3. 安装并配置 UFW / Fail2Ban
 4. 设置时区为 Asia/Shanghai
 5. 创建新用户并加入 sudo 组
 6. 安装、配置并验证 Docker
 7. 管理 Swap
 8. 安装并配置 Nginx / Certbot / Cloudflare DNS 插件
 9. 安全更新 npctl 并补齐缺失依赖
 0. 按顺序执行全部
 q. 退出
====================================================
每次请输入一个编号
EOF
}

run_task() {
  local choice="$1"

  case "$choice" in
    1) setup_dns ;;
    2) install_base_tools ;;
    3) setup_security ;;
    4) set_timezone ;;
    5) create_sudo_user ;;
    6) setup_docker ;;
    7) setup_swap ;;
    8) setup_nginx_certbot ;;
    9) safe_update_npctl ;;
    *)
      warn "无效选项 [$choice]"
      return 1
      ;;
  esac
}

run_all_tasks() {
  local task

  for task in 1 2 3 4 5 6 7 8; do
    if ! run_task "$task"; then
      warn "执行步骤 [$task] 失败，已停止后续任务。"
      return 1
    fi
  done
}

main() {
  local selection

  require_root

  while true; do
    show_menu
    read -rp "请输入要执行的编号: " selection

    if [ -z "${selection}" ]; then
      warn "未输入任何选项，请重新输入。"
      continue
    fi

    case "$selection" in
      q|Q)
        echo "已退出。"
        exit 0
        ;;
      0)
        if run_all_tasks; then
          echo
          echo ">>> 所有任务执行完毕！"
          echo "提示：请断开 SSH 连接并重新登录，以便 Docker 组权限生效。"
          echo "提示：如已安装 Nginx 建站工具，可使用 sudo npctl 启动。"
        fi
        continue
        ;;
    esac

    if ! run_task "$selection"; then
      warn "步骤 [$selection] 执行失败。"
    fi

    echo
    echo "本次选择执行完成。"
  done
}

main "$@"
