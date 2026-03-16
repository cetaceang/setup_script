#!/bin/bash

set -uo pipefail

readonly PROGRAM_NAME="npctl"
readonly ACME_WEBROOT="/var/www/acme"
readonly NGINX_SNIPPETS_DIR="/etc/nginx/snippets"
readonly NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
readonly NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
readonly LETSENCRYPT_DIR="/etc/letsencrypt"
readonly ASSET_LOCATION_PATTERN='~* \.(?:avif|bmp|css|gif|ico|jpe?g|js|json|mjs|png|svg|txt|webp|woff2?)$'

SITE_PRIMARY_DOMAIN=""
declare -a SITE_DOMAINS=()
UPSTREAM_IP=""
UPSTREAM_PORT=""
ENABLE_BLOCK_COMMON_EXPLOITS=0
ENABLE_PROXY_CACHE_ASSETS=0
ENABLE_BROWSER_CACHE_HEADERS=0

log() {
  echo
  echo ">>> $1"
}

warn() {
  echo "!!! $1" >&2
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    warn "请使用 sudo 运行此脚本"
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

require_path() {
  local target_path="$1"
  local hint="$2"

  if [ ! -e "$target_path" ]; then
    warn "未找到路径 [$target_path]。$hint"
    return 1
  fi
}

trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
}

join_by() {
  local separator="$1"
  local item
  shift

  local first=1

  for item in "$@"; do
    if [ "$first" -eq 1 ]; then
      printf '%s' "$item"
      first=0
    else
      printf '%s%s' "$separator" "$item"
    fi
  done
}

validate_domain() {
  local domain="${1,,}"

  if [[ "$domain" == \*.* ]]; then
    return 1
  fi

  [[ "$domain" =~ ^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

validate_ipv4() {
  local ip="$1"
  local octet
  local -a octets

  IFS='.' read -r -a octets <<< "$ip"

  if [ "${#octets[@]}" -ne 4 ]; then
    return 1
  fi

  for octet in "${octets[@]}"; do
    if [[ ! "$octet" =~ ^[0-9]{1,3}$ ]]; then
      return 1
    fi

    if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
      return 1
    fi
  done

  return 0
}

validate_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-n}"
  local answer

  while true; do
    if [ "$default_answer" = "y" ]; then
      read -rp "${prompt} [Y/n]: " answer
      answer="${answer:-Y}"
    else
      read -rp "${prompt} [y/N]: " answer
      answer="${answer:-N}"
    fi

    case "${answer}" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *)
        warn "请输入 y 或 n。"
        ;;
    esac
  done
}

check_environment() {
  require_command "nginx" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_command "certbot" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_command "systemctl" "当前系统不支持 systemd。" || return 1

  require_path "$ACME_WEBROOT" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$NGINX_SNIPPETS_DIR/acme-webroot.conf" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$NGINX_SNIPPETS_DIR/redirect-https-308.conf" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$NGINX_SNIPPETS_DIR/security-headers.conf" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$NGINX_SNIPPETS_DIR/proxy-common.conf" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$NGINX_SNIPPETS_DIR/block-common-exploits.optional.conf" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$NGINX_SNIPPETS_DIR/proxy-cache-assets.optional.conf" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$NGINX_SNIPPETS_DIR/cache-assets.optional.conf" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$LETSENCRYPT_DIR/options-ssl-nginx.conf" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$LETSENCRYPT_DIR/ssl-dhparams.pem" "请先完成 Nginx / Certbot 安装步骤。" || return 1
  require_path "$NGINX_SITES_AVAILABLE_DIR" "请确认 Nginx 安装完整。" || return 1
  require_path "$NGINX_SITES_ENABLED_DIR" "请确认 Nginx 安装完整。" || return 1
}

collect_domains() {
  local input
  local domain
  local -a parsed_domains=()
  declare -A seen_domains=()

  while true; do
    parsed_domains=()
    seen_domains=()

    read -rp "请输入域名（多个域名用空格分隔，第一个作为主域名）: " input
    input="$(trim "$input")"

    if [ -z "$input" ]; then
      warn "域名不能为空。"
      continue
    fi

    read -r -a parsed_domains <<< "$input"

    if [ "${#parsed_domains[@]}" -eq 0 ]; then
      warn "请至少输入一个域名。"
      continue
    fi

    local is_valid=1

    for domain in "${parsed_domains[@]}"; do
      domain="${domain,,}"

      if ! validate_domain "$domain"; then
        warn "域名 [$domain] 格式无效。当前脚本不支持通配符证书。"
        is_valid=0
        break
      fi

      if [ -n "${seen_domains[$domain]:-}" ]; then
        warn "域名 [$domain] 重复，请重新输入。"
        is_valid=0
        break
      fi

      seen_domains["$domain"]=1
    done

    if [ "$is_valid" -eq 1 ]; then
      SITE_DOMAINS=()

      for domain in "${parsed_domains[@]}"; do
        SITE_DOMAINS+=("${domain,,}")
      done

      SITE_PRIMARY_DOMAIN="${SITE_DOMAINS[0]}"
      return 0
    fi
  done
}

collect_upstream() {
  local input_ip
  local input_port

  while true; do
    read -rp "请输入反向代理目标 IPv4: " input_ip
    input_ip="$(trim "$input_ip")"

    if validate_ipv4 "$input_ip"; then
      UPSTREAM_IP="$input_ip"
      break
    fi

    warn "IPv4 地址格式无效，请重新输入。"
  done

  while true; do
    read -rp "请输入反向代理目标端口: " input_port
    input_port="$(trim "$input_port")"

    if validate_port "$input_port"; then
      UPSTREAM_PORT="$input_port"
      break
    fi

    warn "端口范围必须在 1-65535。"
  done
}

collect_optional_snippets() {
  log "选择可选 snippets"

  if prompt_yes_no "是否启用 block-common-exploits.optional.conf（常见探测拦截）"; then
    ENABLE_BLOCK_COMMON_EXPLOITS=1
  else
    ENABLE_BLOCK_COMMON_EXPLOITS=0
  fi

  if prompt_yes_no "是否启用 proxy-cache-assets.optional.conf（Nginx 代理缓存静态资源）"; then
    ENABLE_PROXY_CACHE_ASSETS=1
  else
    ENABLE_PROXY_CACHE_ASSETS=0
  fi

  if prompt_yes_no "是否启用 cache-assets.optional.conf（浏览器缓存静态资源）"; then
    ENABLE_BROWSER_CACHE_HEADERS=1
  else
    ENABLE_BROWSER_CACHE_HEADERS=0
  fi
}

show_summary() {
  local domains_text

  domains_text="$(join_by ' ' "${SITE_DOMAINS[@]}")"

  log "即将创建以下站点"
  echo "主域名: ${SITE_PRIMARY_DOMAIN}"
  echo "全部域名: ${domains_text}"
  echo "反代目标: ${UPSTREAM_IP}:${UPSTREAM_PORT}"
  echo "可选 snippets:"
  echo "  block-common-exploits.optional.conf: ${ENABLE_BLOCK_COMMON_EXPLOITS}"
  echo "  proxy-cache-assets.optional.conf: ${ENABLE_PROXY_CACHE_ASSETS}"
  echo "  cache-assets.optional.conf: ${ENABLE_BROWSER_CACHE_HEADERS}"
}

build_site_config() {
  local site_file="$1"
  local upstream_name="$2"
  local domains_text="$3"

  cat > "$site_file" <<EOF
upstream ${upstream_name} {
    server ${UPSTREAM_IP}:${UPSTREAM_PORT};
    keepalive 32;
}

server {
    listen 80;
    server_name ${domains_text};

    include /etc/nginx/snippets/acme-webroot.conf;
    include /etc/nginx/snippets/redirect-https-308.conf;
}

server {
    listen 443 ssl http2;
    server_name ${domains_text};

    ssl_certificate     /etc/letsencrypt/live/${SITE_PRIMARY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SITE_PRIMARY_DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    include /etc/nginx/snippets/security-headers.conf;
    include /etc/nginx/snippets/acme-webroot.conf;
EOF

  if [ "$ENABLE_BLOCK_COMMON_EXPLOITS" -eq 1 ]; then
    cat >> "$site_file" <<'EOF'
    include /etc/nginx/snippets/block-common-exploits.optional.conf;
EOF
  fi

  if [ "$ENABLE_PROXY_CACHE_ASSETS" -eq 1 ] || [ "$ENABLE_BROWSER_CACHE_HEADERS" -eq 1 ]; then
    cat >> "$site_file" <<EOF

    location ${ASSET_LOCATION_PATTERN} {
        proxy_pass http://${upstream_name};
        include /etc/nginx/snippets/proxy-common.conf;
EOF

    if [ "$ENABLE_PROXY_CACHE_ASSETS" -eq 1 ]; then
      cat >> "$site_file" <<'EOF'
        include /etc/nginx/snippets/proxy-cache-assets.optional.conf;
EOF
    fi

    if [ "$ENABLE_BROWSER_CACHE_HEADERS" -eq 1 ]; then
      cat >> "$site_file" <<'EOF'
        include /etc/nginx/snippets/cache-assets.optional.conf;
EOF
    fi

    cat >> "$site_file" <<'EOF'
    }
EOF
  fi

  cat >> "$site_file" <<EOF

    location / {
        proxy_pass http://${upstream_name};
        include /etc/nginx/snippets/proxy-common.conf;
    }
}
EOF
}

request_certificate() {
  local certbot_args=()
  local domain

  certbot_args=(certbot certonly --webroot -w "$ACME_WEBROOT" --cert-name "$SITE_PRIMARY_DOMAIN")

  for domain in "${SITE_DOMAINS[@]}"; do
    certbot_args+=(-d "$domain")
  done

  log "申请证书"
  "${certbot_args[@]}" || return 1
}

create_proxy_site() {
  local upstream_name
  local domains_text
  local available_file
  local enabled_file
  local temp_file
  local link_created=0
  local file_created=0

  collect_domains || return 1
  collect_upstream || return 1
  collect_optional_snippets || return 1
  show_summary

  if ! prompt_yes_no "确认按以上配置创建站点" "y"; then
    echo "已取消。"
    return 0
  fi

  available_file="${NGINX_SITES_AVAILABLE_DIR}/${SITE_PRIMARY_DOMAIN}"
  enabled_file="${NGINX_SITES_ENABLED_DIR}/${SITE_PRIMARY_DOMAIN}"
  upstream_name="$(echo "${SITE_PRIMARY_DOMAIN}" | sed 's/[^A-Za-z0-9]/_/g')_upstream"
  domains_text="$(join_by ' ' "${SITE_DOMAINS[@]}")"

  if [ -e "$available_file" ] || [ -L "$available_file" ]; then
    warn "站点文件 [$available_file] 已存在，已停止。"
    return 1
  fi

  if [ -e "$enabled_file" ] || [ -L "$enabled_file" ]; then
    warn "站点链接 [$enabled_file] 已存在，已停止。"
    return 1
  fi

  request_certificate || return 1

  temp_file="$(mktemp /tmp/npctl-site.XXXXXX.conf)" || return 1
  build_site_config "$temp_file" "$upstream_name" "$domains_text" || {
    rm -f "$temp_file"
    return 1
  }

  mv "$temp_file" "$available_file" || {
    rm -f "$temp_file"
    return 1
  }
  file_created=1

  ln -s "$available_file" "$enabled_file" || {
    rm -f "$available_file"
    return 1
  }
  link_created=1

  log "检查 Nginx 配置"
  if ! nginx -t; then
    warn "Nginx 配置校验失败，已回滚本次创建的站点文件和链接。"
    if [ "$link_created" -eq 1 ]; then
      rm -f "$enabled_file"
    fi
    if [ "$file_created" -eq 1 ]; then
      rm -f "$available_file"
    fi
    return 1
  fi

  log "重载 Nginx"
  if ! systemctl reload nginx; then
    warn "Nginx 重载失败，已回滚本次创建的站点文件和链接。"
    rm -f "$enabled_file"
    rm -f "$available_file"
    return 1
  fi

  log "执行 Certbot 续期演练"
  if ! certbot renew --dry-run; then
    warn "续期演练失败，请稍后手动检查 certbot renew --dry-run。"
  fi

  log "站点创建完成"
  echo "站点文件: ${available_file}"
  echo "启用链接: ${enabled_file}"
  echo "域名: ${domains_text}"
  echo "反代目标: ${UPSTREAM_IP}:${UPSTREAM_PORT}"
}

show_menu() {
  cat <<'EOF'

================ nginx proxy control ================
 1. 创建新的反向代理站点
 q. 退出
====================================================
每次请输入一个编号
EOF
}

run_task() {
  local choice="$1"

  case "$choice" in
    1) create_proxy_site ;;
    *)
      warn "无效选项 [$choice]"
      return 1
      ;;
  esac
}

main() {
  local selection

  require_root
  check_environment || exit 1

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
    esac

    if ! run_task "$selection"; then
      warn "步骤 [$selection] 执行失败。"
    fi

    echo
    echo "本次选择执行完成。"
  done
}

main "$@"
