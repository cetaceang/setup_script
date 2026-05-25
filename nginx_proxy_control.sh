#!/bin/bash

set -uo pipefail

readonly PROGRAM_NAME="npctl"
readonly ACME_WEBROOT="/var/www/acme"
readonly NGINX_SNIPPETS_DIR="/etc/nginx/snippets"
readonly NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
readonly NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
readonly LETSENCRYPT_DIR="/etc/letsencrypt"
readonly ASSET_LOCATION_PATTERN='~* \.(?:avif|bmp|css|gif|ico|jpe?g|js|json|mjs|png|svg|txt|webp|woff2?)$'
readonly CLOUDFLARE_CREDENTIALS_DIR="/root/.secrets/certbot"
readonly CLOUDFLARE_CREDENTIALS_FILE="${CLOUDFLARE_CREDENTIALS_DIR}/cloudflare.ini"

SITE_DOMAIN=""
UPSTREAM_IP=""
UPSTREAM_PORT=""
ENABLE_BLOCK_COMMON_EXPLOITS=0
ENABLE_PROXY_CACHE_ASSETS=0
ENABLE_BROWSER_CACHE_HEADERS=0
SELECTED_CERT_NAME=""
SELECTED_CERT_DOMAINS=""
SELECTED_CERT_EXPIRY=""

declare -a CERTIFICATE_NAMES=()
declare -a CERTIFICATE_DOMAINS=()
declare -a CERTIFICATE_EXPIRIES=()
declare -a ENABLED_SITE_NAMES=()

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

validate_domain() {
  local domain="${1,,}"

  if [[ "$domain" == \*.* ]]; then
    return 1
  fi

  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
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

check_certificate_environment() {
  require_command "certbot" "请先完成 Nginx / Certbot 安装步骤。" || return 1
}

check_cloudflare_plugin() {
  local plugin_output

  check_certificate_environment || return 1

  plugin_output="$(certbot plugins 2>/dev/null)" || {
    warn "执行 certbot plugins 失败，请确认 Certbot 已正确安装。"
    return 1
  }

  if ! printf '%s\n' "$plugin_output" | grep -q "dns-cloudflare"; then
    warn "未检测到 certbot dns-cloudflare 插件，请先重新执行安装步骤。"
    return 1
  fi
}

check_nginx_environment() {
  require_command "nginx" "请先完成 Nginx 安装步骤。" || return 1
  require_command "systemctl" "当前系统不支持 systemd。" || return 1
  require_path "$NGINX_SITES_AVAILABLE_DIR" "请确认 Nginx 安装完整。" || return 1
  require_path "$NGINX_SITES_ENABLED_DIR" "请确认 Nginx 安装完整。" || return 1
}

check_site_template_environment() {
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
}

reset_create_site_state() {
  SITE_DOMAIN=""
  UPSTREAM_IP=""
  UPSTREAM_PORT=""
  ENABLE_BLOCK_COMMON_EXPLOITS=0
  ENABLE_PROXY_CACHE_ASSETS=0
  ENABLE_BROWSER_CACHE_HEADERS=0
  SELECTED_CERT_NAME=""
  SELECTED_CERT_DOMAINS=""
  SELECTED_CERT_EXPIRY=""
}

collect_site_domain() {
  local input

  while true; do
    read -rp "请输入站点域名: " input
    input="$(trim "$input")"
    input="${input,,}"

    if [ -z "$input" ]; then
      warn "域名不能为空。"
      continue
    fi

    if ! validate_domain "$input"; then
      warn "域名 [$input] 格式无效。当前站点配置只支持单个普通域名。"
      continue
    fi

    SITE_DOMAIN="$input"
    return 0
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

append_certificate_record() {
  local cert_name="$1"
  local cert_domains="$2"
  local cert_expiry="$3"

  if [ -z "$cert_name" ]; then
    return 0
  fi

  CERTIFICATE_NAMES+=("$cert_name")
  CERTIFICATE_DOMAINS+=("$cert_domains")
  CERTIFICATE_EXPIRIES+=("$cert_expiry")
}

load_certificates() {
  local certbot_output
  local line
  local current_name=""
  local current_domains=""
  local current_expiry=""

  CERTIFICATE_NAMES=()
  CERTIFICATE_DOMAINS=()
  CERTIFICATE_EXPIRIES=()

  certbot_output="$(certbot certificates 2>&1)" || {
    warn "执行 certbot certificates 失败。"
    printf '%s\n' "$certbot_output" >&2
    return 1
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*Certificate[[:space:]]Name:[[:space:]]+(.+)$ ]]; then
      append_certificate_record "$current_name" "$current_domains" "$current_expiry"
      current_name="$(trim "${BASH_REMATCH[1]}")"
      current_domains=""
      current_expiry=""
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*Domains:[[:space:]]+(.+)$ ]]; then
      current_domains="$(trim "${BASH_REMATCH[1]}")"
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*Expiry[[:space:]]Date:[[:space:]]+(.+)$ ]]; then
      current_expiry="$(trim "${BASH_REMATCH[1]}")"
      continue
    fi
  done <<< "$certbot_output"

  append_certificate_record "$current_name" "$current_domains" "$current_expiry"
}

show_certificates_list() {
  local idx

  if [ "${#CERTIFICATE_NAMES[@]}" -eq 0 ]; then
    echo "当前没有可用证书。"
    return 0
  fi

  for idx in "${!CERTIFICATE_NAMES[@]}"; do
    echo " $((idx + 1)). ${CERTIFICATE_NAMES[$idx]}"
    echo "    覆盖域名: ${CERTIFICATE_DOMAINS[$idx]:-(未解析)}"

    if [ -n "${CERTIFICATE_EXPIRIES[$idx]}" ]; then
      echo "    到期: ${CERTIFICATE_EXPIRIES[$idx]}"
    fi
  done
}

list_certificates_action() {
  check_certificate_environment || return 1
  load_certificates || return 1

  log "本机已有证书"
  show_certificates_list
}

write_cloudflare_credentials() {
  local api_token="$1"

  mkdir -p /root/.secrets || return 1
  chmod 0700 /root/.secrets || return 1
  mkdir -p "$CLOUDFLARE_CREDENTIALS_DIR" || return 1
  chmod 0700 "$CLOUDFLARE_CREDENTIALS_DIR" || return 1

  (
    umask 077
    cat > "$CLOUDFLARE_CREDENTIALS_FILE" <<EOF
dns_cloudflare_api_token = ${api_token}
EOF
  ) || return 1

  chmod 0600 "$CLOUDFLARE_CREDENTIALS_FILE" || return 1
}

ensure_cloudflare_credentials() {
  local api_token

  mkdir -p /root/.secrets || return 1
  chmod 0700 /root/.secrets || return 1
  mkdir -p "$CLOUDFLARE_CREDENTIALS_DIR" || return 1
  chmod 0700 "$CLOUDFLARE_CREDENTIALS_DIR" || return 1

  if [ -s "$CLOUDFLARE_CREDENTIALS_FILE" ]; then
    echo "已检测到 Cloudflare 凭据文件: $CLOUDFLARE_CREDENTIALS_FILE"

    if prompt_yes_no "是否复用现有 Cloudflare API Token" "y"; then
      chmod 0600 "$CLOUDFLARE_CREDENTIALS_FILE" || return 1
      return 0
    fi
  fi

  while true; do
    read -rsp "请输入 Cloudflare API Token: " api_token
    echo
    api_token="$(trim "$api_token")"

    if [ -z "$api_token" ]; then
      warn "API Token 不能为空。"
      continue
    fi

    write_cloudflare_credentials "$api_token" || return 1
    echo "已写入 Cloudflare 凭据文件。"
    return 0
  done
}

collect_wildcard_apex_domain() {
  local input

  while true; do
    read -rp "请输入要申请通配证书的裸域（例如 example.com）: " input
    input="$(trim "$input")"
    input="${input,,}"

    if [ -z "$input" ]; then
      warn "域名不能为空。"
      continue
    fi

    if ! validate_domain "$input"; then
      warn "域名 [$input] 格式无效，请输入裸域，例如 example.com。"
      continue
    fi

    printf '%s' "$input"
    return 0
  done
}

run_certbot_renew_dry_run() {
  log "执行 Certbot 续期演练"

  if ! certbot renew --dry-run; then
    warn "续期演练失败，请稍后手动检查 certbot renew --dry-run。"
  fi
}

collect_webroot_certificate_domain() {
  local input

  while true; do
    read -rp "请输入要申请 Webroot 证书的域名: " input
    input="$(trim "$input")"
    input="${input,,}"

    if [ -z "$input" ]; then
      warn "域名不能为空。"
      continue
    fi

    if ! validate_domain "$input"; then
      warn "域名 [$input] 格式无效，请输入普通域名，例如 api.example.com。"
      continue
    fi

    printf '%s' "$input"
    return 0
  done
}

issue_webroot_certificate() {
  local cert_domain="$1"
  local -a certbot_args=()

  check_certificate_environment || return 1
  check_nginx_environment || return 1
  check_site_template_environment || return 1

  log "即将申请 Webroot 证书"
  echo "cert-name: ${cert_domain}"
  echo "覆盖域名: ${cert_domain}"
  echo "Webroot 目录: ${ACME_WEBROOT}"

  if ! prompt_yes_no "确认申请该 Webroot 证书" "y"; then
    echo "已取消。"
    return 2
  fi

  certbot_args=(
    certbot certonly
    --webroot
    -w "$ACME_WEBROOT"
    --cert-name "$cert_domain"
    -d "$cert_domain"
  )

  log "申请 Webroot 证书"
  "${certbot_args[@]}" || return 1

  run_certbot_renew_dry_run

  log "证书申请完成"
  echo "cert-name: ${cert_domain}"
  echo "覆盖域名: ${cert_domain}"
}

issue_webroot_certificate_interactive() {
  local cert_domain
  local result

  cert_domain="$(collect_webroot_certificate_domain)" || return 1
  issue_webroot_certificate "$cert_domain"
  result=$?

  case "$result" in
    0|2) return 0 ;;
    *) return 1 ;;
  esac
}

issue_cloudflare_wildcard_certificate() {
  local apex_domain
  local -a certbot_args=()

  check_cloudflare_plugin || return 1

  apex_domain="$(collect_wildcard_apex_domain)" || return 1
  ensure_cloudflare_credentials || return 1

  log "即将申请 Cloudflare 通配证书"
  echo "cert-name: ${apex_domain}"
  echo "覆盖域名: ${apex_domain} *.${apex_domain}"
  echo "凭据文件: ${CLOUDFLARE_CREDENTIALS_FILE}"

  if ! prompt_yes_no "确认申请该通配证书" "y"; then
    echo "已取消。"
    return 0
  fi

  certbot_args=(
    certbot certonly
    --dns-cloudflare
    --dns-cloudflare-credentials "$CLOUDFLARE_CREDENTIALS_FILE"
    --cert-name "$apex_domain"
    -d "$apex_domain"
    -d "*.$apex_domain"
  )

  log "申请 Cloudflare 通配证书"
  "${certbot_args[@]}" || return 1

  run_certbot_renew_dry_run

  log "证书申请完成"
  echo "cert-name: ${apex_domain}"
  echo "覆盖域名: ${apex_domain} *.${apex_domain}"
}

select_certificate() {
  local selection
  local index
  local issue_result

  while true; do
    load_certificates || return 1

    log "请选择要绑定的证书"
    show_certificates_list

    if [ "${#CERTIFICATE_NAMES[@]}" -eq 0 ]; then
      echo " n. 为当前站点申请新的 Webroot 证书"
      echo " w. 申请新的 Cloudflare 通配证书"
      echo " q. 取消"
    else
      echo " n. 为当前站点申请新的 Webroot 证书"
      echo " w. 申请新的 Cloudflare 通配证书"
      echo " r. 刷新证书列表"
      echo " q. 取消"
    fi

    read -rp "请选择要绑定的证书编号: " selection
    selection="$(trim "$selection")"

    case "$selection" in
      n|N)
        issue_webroot_certificate "$SITE_DOMAIN"
        issue_result=$?

        case "$issue_result" in
          0|2) continue ;;
          *) return 1 ;;
        esac
        ;;
      w|W)
        issue_cloudflare_wildcard_certificate || return 1
        continue
        ;;
      r|R)
        if [ "${#CERTIFICATE_NAMES[@]}" -eq 0 ]; then
          warn "当前没有可刷新的证书列表，请先申请证书。"
        fi
        continue
        ;;
      q|Q)
        return 2
        ;;
    esac

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#CERTIFICATE_NAMES[@]}" ]; then
      index=$((selection - 1))
      SELECTED_CERT_NAME="${CERTIFICATE_NAMES[$index]}"
      SELECTED_CERT_DOMAINS="${CERTIFICATE_DOMAINS[$index]}"
      SELECTED_CERT_EXPIRY="${CERTIFICATE_EXPIRIES[$index]}"
      return 0
    fi

    warn "无效选项 [$selection]。"
  done
}

show_create_site_summary() {
  log "即将创建以下站点"
  echo "站点域名: ${SITE_DOMAIN}"
  echo "绑定证书: ${SELECTED_CERT_NAME}"
  echo "证书覆盖域名: ${SELECTED_CERT_DOMAINS:-未解析}"

  if [ -n "$SELECTED_CERT_EXPIRY" ]; then
    echo "证书到期: ${SELECTED_CERT_EXPIRY}"
  fi

  echo "反代目标: ${UPSTREAM_IP}:${UPSTREAM_PORT}"
  echo "可选 snippets:"
  echo "  block-common-exploits.optional.conf: ${ENABLE_BLOCK_COMMON_EXPLOITS}"
  echo "  proxy-cache-assets.optional.conf: ${ENABLE_PROXY_CACHE_ASSETS}"
  echo "  cache-assets.optional.conf: ${ENABLE_BROWSER_CACHE_HEADERS}"
  echo "提示: 当前不会校验证书是否覆盖该站点域名，请自行确认。"
}

build_site_config() {
  local site_file="$1"
  local upstream_name="$2"

  cat > "$site_file" <<EOF
upstream ${upstream_name} {
    server ${UPSTREAM_IP}:${UPSTREAM_PORT};
    keepalive 32;
}

server {
    listen 80;
    server_name ${SITE_DOMAIN};

    include /etc/nginx/snippets/acme-webroot.conf;
    include /etc/nginx/snippets/redirect-https-308.conf;
}

server {
    listen 443 ssl http2;
    server_name ${SITE_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${SELECTED_CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SELECTED_CERT_NAME}/privkey.pem;
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

create_proxy_site() {
  local upstream_name
  local available_file
  local enabled_file
  local temp_file
  local select_result
  local link_created=0
  local file_created=0

  check_nginx_environment || return 1
  check_site_template_environment || return 1
  check_certificate_environment || return 1
  reset_create_site_state

  collect_site_domain || return 1

  available_file="${NGINX_SITES_AVAILABLE_DIR}/${SITE_DOMAIN}"
  enabled_file="${NGINX_SITES_ENABLED_DIR}/${SITE_DOMAIN}"
  upstream_name="$(echo "${SITE_DOMAIN}" | sed 's/[^A-Za-z0-9]/_/g')_upstream"

  if [ -e "$available_file" ] || [ -L "$available_file" ]; then
    warn "站点文件 [$available_file] 已存在，已停止。"
    return 1
  fi

  if [ -e "$enabled_file" ] || [ -L "$enabled_file" ]; then
    warn "站点链接 [$enabled_file] 已存在，已停止。"
    return 1
  fi

  select_certificate
  select_result=$?

  case "$select_result" in
    0) ;;
    2)
      echo "已取消。"
      return 0
      ;;
    *)
      return 1
      ;;
  esac

  collect_upstream || return 1
  collect_optional_snippets || return 1
  show_create_site_summary

  if ! prompt_yes_no "确认按以上配置创建站点" "y"; then
    echo "已取消。"
    return 0
  fi

  temp_file="$(mktemp /tmp/npctl-site.XXXXXX.conf)" || return 1
  build_site_config "$temp_file" "$upstream_name" || {
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

    if [ "$link_created" -eq 1 ]; then
      rm -f "$enabled_file"
    fi

    if [ "$file_created" -eq 1 ]; then
      rm -f "$available_file"
    fi

    return 1
  fi

  run_certbot_renew_dry_run

  log "站点创建完成"
  echo "站点文件: ${available_file}"
  echo "启用链接: ${enabled_file}"
  echo "站点域名: ${SITE_DOMAIN}"
  echo "绑定证书: ${SELECTED_CERT_NAME}"
  echo "反代目标: ${UPSTREAM_IP}:${UPSTREAM_PORT}"
}

extract_server_names_from_config() {
  local site_file="$1"
  local server_names

  if [ ! -f "$site_file" ]; then
    printf '%s' "未找到配置文件"
    return 0
  fi

  server_names="$(awk '
    /^[[:space:]]*server_name[[:space:]]+/ {
      for (i = 2; i <= NF; i++) {
        gsub(/;/, "", $i)

        if ($i != "") {
          if (names != "") {
            names = names " "
          }

          names = names $i
        }
      }
    }
    END { print names }
  ' "$site_file")"

  server_names="$(trim "$server_names")"
  printf '%s' "${server_names:-未解析}"
}

load_enabled_sites() {
  local path

  ENABLED_SITE_NAMES=()

  shopt -s nullglob
  for path in "$NGINX_SITES_ENABLED_DIR"/*; do
    [ -L "$path" ] || continue
    ENABLED_SITE_NAMES+=("$(basename "$path")")
  done
  shopt -u nullglob
}

show_enabled_sites() {
  local idx
  local site_name
  local available_file

  if [ "${#ENABLED_SITE_NAMES[@]}" -eq 0 ]; then
    echo "当前没有已启用站点。"
    return 0
  fi

  for idx in "${!ENABLED_SITE_NAMES[@]}"; do
    site_name="${ENABLED_SITE_NAMES[$idx]}"
    available_file="${NGINX_SITES_AVAILABLE_DIR}/${site_name}"
    echo " $((idx + 1)). ${site_name}"
    echo "    server_name: $(extract_server_names_from_config "$available_file")"
  done
}

disable_site() {
  local selection
  local index
  local site_name
  local enabled_file
  local available_file
  local server_names

  check_nginx_environment || return 1
  load_enabled_sites

  log "已启用站点"
  show_enabled_sites

  if [ "${#ENABLED_SITE_NAMES[@]}" -eq 0 ]; then
    return 0
  fi

  echo " q. 取消"

  while true; do
    read -rp "请选择要禁用的站点编号: " selection
    selection="$(trim "$selection")"

    case "$selection" in
      q|Q)
        echo "已取消。"
        return 0
        ;;
    esac

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#ENABLED_SITE_NAMES[@]}" ]; then
      index=$((selection - 1))
      site_name="${ENABLED_SITE_NAMES[$index]}"
      break
    fi

    warn "无效选项 [$selection]。"
  done

  enabled_file="${NGINX_SITES_ENABLED_DIR}/${site_name}"
  available_file="${NGINX_SITES_AVAILABLE_DIR}/${site_name}"
  server_names="$(extract_server_names_from_config "$available_file")"

  log "即将禁用以下站点"
  echo "站点名: ${site_name}"
  echo "配置文件: ${available_file}"
  echo "启用链接: ${enabled_file}"
  echo "server_name: ${server_names}"

  if ! prompt_yes_no "确认禁用此站点" "n"; then
    echo "已取消。"
    return 0
  fi

  rm -f "$enabled_file" || return 1

  log "检查 Nginx 配置"
  if ! nginx -t; then
    warn "Nginx 配置校验失败，已恢复站点启用链接。"

    if [ -e "$available_file" ] || [ -L "$available_file" ]; then
      ln -s "$available_file" "$enabled_file" || warn "恢复站点链接失败，请手动检查。"
    fi

    return 1
  fi

  log "重载 Nginx"
  if ! systemctl reload nginx; then
    warn "Nginx 重载失败，已恢复站点启用链接。"

    if [ -e "$available_file" ] || [ -L "$available_file" ]; then
      ln -s "$available_file" "$enabled_file" || warn "恢复站点链接失败，请手动检查。"
    fi

    return 1
  fi

  log "站点已禁用"
  echo "已移除链接: ${enabled_file}"
  echo "保留配置: ${available_file}"
}

show_menu() {
  cat <<'EOF'

================ nginx proxy control ================
 1. 创建新的反向代理站点
 2. 申请普通域名证书（Webroot）
 3. 申请 Cloudflare 通配证书
 4. 列出本机已有证书
 5. 禁用站点
 q. 退出
====================================================
每次请输入一个编号
EOF
}

run_task() {
  local choice="$1"

  case "$choice" in
    1) create_proxy_site ;;
    2) issue_webroot_certificate_interactive ;;
    3) issue_cloudflare_wildcard_certificate ;;
    4) list_certificates_action ;;
    5) disable_site ;;
    *)
      warn "无效选项 [$choice]"
      return 1
      ;;
  esac
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
    esac

    if ! run_task "$selection"; then
      warn "步骤 [$selection] 执行失败。"
    fi

    echo
    echo "本次选择执行完成。"
  done
}

main "$@"
