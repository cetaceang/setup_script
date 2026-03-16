#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_PACKAGES=(vim curl)
SECURITY_PACKAGES=(ufw fail2ban)
NGINX_PACKAGES=(nginx certbot)
NPCTL_SOURCE_SCRIPT="${SCRIPT_DIR}/nginx_proxy_control.sh"
NPCTL_TARGET_PATH="/usr/local/bin/npctl"
PACKAGE_INDEX_UPDATED=0

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

install_base_tools() {
  log "1. 更新软件源并安装基础工具 (${BASE_PACKAGES[*]})"
  install_packages "${BASE_PACKAGES[@]}" || return 1
}

setup_security() {
  log "2. 安装并配置 UFW / Fail2Ban"
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
  log "3. 设置时区为 Asia/Shanghai"
  require_command "timedatectl" "当前系统不支持 timedatectl。" || return 1

  timedatectl set-timezone Asia/Shanghai || return 1
  timedatectl || return 1
}

install_docker() {
  local docker_script

  log "5.1 安装 Docker (官方脚本)"
  require_command "curl" "请先执行 [1. 安装基础工具]。" || return 1

  docker_script="$(mktemp /tmp/get-docker.XXXXXX.sh)"
  curl -fsSL https://get.docker.com -o "$docker_script" || return 1
  sh "$docker_script" || return 1
  rm -f "$docker_script"
}

configure_docker_logging() {
  log "5.2 配置 Docker 日志 (json-file, 10m)"
  require_command "systemctl" "当前系统不支持 systemd。" || return 1
  require_command "docker" "请先执行 [5. 安装并配置 Docker]。" || return 1

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

  log "4. 创建新用户并加入 sudo 组"
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

  log "5.3 配置 Docker 用户权限"

  if ! getent group docker >/dev/null 2>&1; then
    warn "未检测到 docker 组。请先执行 [5. 安装并配置 Docker]。"
    return 1
  fi

  target_user="$(choose_target_user)" || return 1
  usermod -aG docker "$target_user" || return 1
  echo "已将用户 [$target_user] 加入 docker 组。"
}

verify_docker() {
  log "5.4 验证 Docker 版本"
  require_command "docker" "请先执行 [5. 安装并配置 Docker]。" || return 1

  docker --version || return 1

  if docker compose version >/dev/null 2>&1; then
    docker compose version || return 1
  else
    warn "未检测到 docker compose 插件。"
  fi
}

setup_docker() {
  log "5. 安装并配置 Docker"
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

  log "6. 管理 Swap"
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

write_nginx_snippets() {
  mkdir -p /etc/nginx/snippets || return 1

  cat > /etc/nginx/snippets/acme-webroot.conf <<'EOF'
location ^~ /.well-known/acme-challenge/ {
    root /var/www/acme;
    try_files $uri =404;
}
EOF

  cat > /etc/nginx/snippets/redirect-https-308.conf <<'EOF'
location / {
    return 308 https://$host$request_uri;
}
EOF

  cat > /etc/nginx/snippets/security-headers.conf <<'EOF'
add_header Strict-Transport-Security "max-age=63072000" always;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header Referrer-Policy no-referrer always;
EOF

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

  cat > /etc/nginx/snippets/cache-assets.optional.conf <<'EOF'
expires 30d;
add_header Cache-Control "public, max-age=2592000, immutable" always;
access_log off;
EOF

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

  cat > /etc/nginx/snippets/block-common-exploits.optional.conf <<'EOF'
location ~ /\.(?!well-known) {
    deny all;
}

location ~* \.(?:bak|conf|dist|ini|log|old|orig|save|sql|swp)$ {
    deny all;
}
EOF
}

write_letsencrypt_tls_files() {
  mkdir -p /etc/letsencrypt || return 1

  cat > /etc/letsencrypt/options-ssl-nginx.conf <<'EOF'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
EOF

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

install_npctl_command() {
  log "7.1 安装 npctl 命令"

  if [ ! -f "$NPCTL_SOURCE_SCRIPT" ]; then
    warn "未找到 npctl 源脚本 [$NPCTL_SOURCE_SCRIPT]。"
    return 1
  fi

  mkdir -p /usr/local/bin || return 1
  cp "$NPCTL_SOURCE_SCRIPT" "$NPCTL_TARGET_PATH" || return 1
  chmod 0755 "$NPCTL_TARGET_PATH" || return 1
}

setup_nginx_certbot() {
  log "7. 安装并配置 Nginx / Certbot"
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

  if [ -L /etc/nginx/sites-enabled/default ]; then
    unlink /etc/nginx/sites-enabled/default || return 1
  fi

  write_nginx_main_config || return 1
  write_nginx_acme_config || return 1
  write_nginx_snippets || return 1
  write_letsencrypt_tls_files || return 1
  install_npctl_command || return 1

  nginx -t || return 1
  systemctl reload nginx || return 1
}

show_menu() {
  cat <<'EOF'

================ 服务器初始化交互菜单 ================
 1. 更新软件源并安装基础工具
 2. 安装并配置 UFW / Fail2Ban
 3. 设置时区为 Asia/Shanghai
 4. 创建新用户并加入 sudo 组
 5. 安装、配置并验证 Docker
 6. 管理 Swap
 7. 安装并配置 Nginx / Certbot
 0. 按顺序执行全部
 q. 退出
====================================================
每次请输入一个编号
EOF
}

run_task() {
  local choice="$1"

  case "$choice" in
    1) install_base_tools ;;
    2) setup_security ;;
    3) set_timezone ;;
    4) create_sudo_user ;;
    5) setup_docker ;;
    6) setup_swap ;;
    7) setup_nginx_certbot ;;
    *)
      warn "无效选项 [$choice]"
      return 1
      ;;
  esac
}

run_all_tasks() {
  local task

  for task in 1 2 3 4 5 6 7; do
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
