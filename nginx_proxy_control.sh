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
readonly NPCTL_MANAGED_MARKER="# Managed by npctl"

SITE_DOMAIN=""
UPSTREAM_IP=""
UPSTREAM_PORT=""
ENABLE_BLOCK_COMMON_EXPLOITS=0
ENABLE_PROXY_CACHE_ASSETS=0
ENABLE_BROWSER_CACHE_HEADERS=0
CLIENT_MAX_BODY_SIZE=""
SELECTED_CERT_NAME=""
SELECTED_CERT_DOMAINS=""
SELECTED_CERT_EXPIRY=""

declare -a CERTIFICATE_NAMES=()
declare -a CERTIFICATE_DOMAINS=()
declare -a CERTIFICATE_EXPIRIES=()
declare -a ENABLED_SITE_NAMES=()
declare -a DISABLED_SITE_NAMES=()

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

check_apt_environment() {
  require_command "apt" "当前系统不支持 apt 包管理。" || return 1
}

read_nginx_package_version() {
  if ! command_exists "dpkg-query"; then
    return 1
  fi

  dpkg-query -W -f='${Version}' nginx 2>/dev/null
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
  CLIENT_MAX_BODY_SIZE=""
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

normalize_client_max_body_size() {
  local value

  value="$(trim "$1")"
  printf '%s' "${value^^}"
}

validate_client_max_body_size() {
  local value

  value="$(normalize_client_max_body_size "$1")"

  [[ "$value" = "0" || "$value" =~ ^[1-9][0-9]*[KMG]$ ]]
}

prompt_client_max_body_size_value() {
  local input
  local normalized

  while true; do
    read -rp "请输入 client_max_body_size 的值（例如 1024M、2G、0）: " input
    normalized="$(normalize_client_max_body_size "$input")"

    if validate_client_max_body_size "$normalized"; then
      printf '%s' "$normalized"
      return 0
    fi

    warn "client_max_body_size 仅支持 0 或正整数加单位 K/M/G，例如 64M、2G。"
  done
}

collect_optional_client_max_body_size() {
  CLIENT_MAX_BODY_SIZE=""

  if ! prompt_yes_no "是否设置 client_max_body_size"; then
    return 0
  fi

  CLIENT_MAX_BODY_SIZE="$(prompt_client_max_body_size_value)" || return 1
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
  local cert_name="${1:-}"
  local -a certbot_args=(certbot renew --dry-run)

  log "执行 Certbot 续期演练"

  if [ -n "$cert_name" ]; then
    echo "目标证书: ${cert_name}"
    certbot_args+=(--cert-name "$cert_name")
  else
    echo "目标证书: 全部证书"
  fi

  if ! "${certbot_args[@]}"; then
    if [ -n "$cert_name" ]; then
      warn "证书 [$cert_name] 续期演练失败，请稍后手动检查 certbot renew --dry-run --cert-name ${cert_name}。"
    else
      warn "续期演练失败，请稍后手动检查 certbot renew --dry-run。"
    fi
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

  run_certbot_renew_dry_run "$cert_domain"

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

  run_certbot_renew_dry_run "$apex_domain"

  log "证书申请完成"
  echo "cert-name: ${apex_domain}"
  echo "覆盖域名: ${apex_domain} *.${apex_domain}"
}

certificate_pattern_covers_domain() {
  local pattern="${1,,}"
  local domain="${2,,}"
  local suffix
  local prefix

  if [ -z "$pattern" ] || [ -z "$domain" ]; then
    return 1
  fi

  if [ "$pattern" = "$domain" ]; then
    return 0
  fi

  case "$pattern" in
    \*.*)
      suffix="${pattern#*.}"

      case "$domain" in
        *."$suffix")
          prefix="${domain%.$suffix}"

          if [ -z "$prefix" ]; then
            return 1
          fi

          case "$prefix" in
            *.*) return 1 ;;
            *) return 0 ;;
          esac
          ;;
      esac
      ;;
  esac

  return 1
}

certificate_covers_domain() {
  local cert_domains="$1"
  local domain="${2,,}"
  local cert_domain

  for cert_domain in $cert_domains; do
    cert_domain="${cert_domain,,}"

    if certificate_pattern_covers_domain "$cert_domain" "$domain"; then
      return 0
    fi
  done

  return 1
}

find_certificate_index_by_name() {
  local cert_name="$1"
  local idx

  for idx in "${!CERTIFICATE_NAMES[@]}"; do
    if [ "${CERTIFICATE_NAMES[$idx]}" = "$cert_name" ]; then
      printf '%s' "$idx"
      return 0
    fi
  done

  return 1
}

select_certificate() {
  local target_domain="${1:-$SITE_DOMAIN}"
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

    read -rp "请选择要绑定到域名 [${target_domain}] 的证书编号: " selection
    selection="$(trim "$selection")"

    case "$selection" in
      n|N)
        issue_webroot_certificate "$target_domain"
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
  echo "client_max_body_size: ${CLIENT_MAX_BODY_SIZE:-未设置}"
  echo "可选 snippets:"
  echo "  block-common-exploits.optional.conf: ${ENABLE_BLOCK_COMMON_EXPLOITS}"
  echo "  proxy-cache-assets.optional.conf: ${ENABLE_PROXY_CACHE_ASSETS}"
  echo "  cache-assets.optional.conf: ${ENABLE_BROWSER_CACHE_HEADERS}"
  echo "证书覆盖校验: 已禁用，请自行确认"
}

build_site_config() {
  local site_file="$1"
  local upstream_name="$2"

  cat > "$site_file" <<EOF
${NPCTL_MANAGED_MARKER}

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
EOF

  if [ -n "$CLIENT_MAX_BODY_SIZE" ]; then
    cat >> "$site_file" <<EOF

    client_max_body_size ${CLIENT_MAX_BODY_SIZE};
EOF
  fi

  cat >> "$site_file" <<EOF

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
  collect_optional_client_max_body_size || return 1
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

  run_certbot_renew_dry_run "$SELECTED_CERT_NAME"

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

extract_unique_site_domain_from_config() {
  local site_file="$1"

  awk '
    /^[[:space:]]*server_name[[:space:]]+/ {
      for (i = 2; i <= NF; i++) {
        gsub(/;/, "", $i)

        if ($i != "" && $i != "_") {
          names[$i] = 1
        }
      }
    }
    END {
      count = 0

      for (name in names) {
        count++
        selected = name
      }

      if (count != 1) {
        exit 1
      }

      print selected
    }
  ' "$site_file"
}

extract_cert_name_from_config_directive() {
  local site_file="$1"
  local directive="$2"
  local filename="$3"

  awk -v directive="$directive" -v filename="$filename" '
    $1 == directive {
      path = $2
      sub(/;$/, "", path)

      prefix = "/etc/letsencrypt/live/"
      suffix = "/" filename

      if (index(path, prefix) != 1) {
        invalid = 1
        next
      }

      name = substr(path, length(prefix) + 1)

      if (length(name) <= length(suffix)) {
        invalid = 1
        next
      }

      if (substr(name, length(name) - length(suffix) + 1) != suffix) {
        invalid = 1
        next
      }

      name = substr(name, 1, length(name) - length(suffix))

      if (name == "") {
        invalid = 1
        next
      }

      names[name] = 1
    }
    END {
      count = 0

      for (name in names) {
        count++
        selected = name
      }

      if (invalid || count != 1) {
        exit 1
      }

      print selected
    }
  ' "$site_file"
}

extract_site_certificate_name_from_config() {
  local site_file="$1"
  local cert_name
  local key_name

  cert_name="$(extract_cert_name_from_config_directive "$site_file" "ssl_certificate" "fullchain.pem")" || return 1
  key_name="$(extract_cert_name_from_config_directive "$site_file" "ssl_certificate_key" "privkey.pem")" || return 1

  if [ "$cert_name" != "$key_name" ]; then
    return 1
  fi

  printf '%s' "$cert_name"
}

extract_site_client_max_body_size() {
  local site_file="$1"

  awk '
    function brace_delta(line,    opens, closes, text) {
      text = line
      opens = gsub(/\{/, "{", text)
      closes = gsub(/\}/, "}", text)
      return opens - closes
    }

    function flush_server_block(    i, value, server_name_idx, ssl_idx, invalid_region) {
      if (!in_server) {
        return
      }

      if (target_server) {
        target_count++

        for (i = 1; i <= line_count; i++) {
          if (lines[i] ~ /^[[:space:]]*server_name[[:space:]]+/) {
            if (server_name_idx == 0) {
              server_name_idx = i
            } else {
              invalid = 1
            }
          }

          if (lines[i] ~ /^[[:space:]]*ssl_certificate[[:space:]]+/ && ssl_idx == 0) {
            ssl_idx = i
          }
        }

        if (server_name_idx == 0 || ssl_idx == 0 || ssl_idx <= server_name_idx) {
          invalid = 1
        }

        for (i = server_name_idx + 1; i < ssl_idx; i++) {
          if (lines[i] ~ /^[[:space:]]*$/) {
            continue
          }

          if (lines[i] ~ /^[[:space:]]*client_max_body_size[[:space:]]+/) {
            value = lines[i]
            sub(/^[[:space:]]*client_max_body_size[[:space:]]+/, "", value)
            sub(/[[:space:]]*;[[:space:]]*$/, "", value)
            client_count++
            client_value = value
            continue
          }

          invalid_region = 1
        }

        if (invalid_region) {
          invalid = 1
        }

      }

      delete lines
      line_count = 0
      in_server = 0
      target_server = 0
      server_depth = 0
    }

    /^[[:space:]]*server[[:space:]]*\{/ {
      flush_server_block()
      in_server = 1
      line_count = 0
      target_server = 0
      server_depth = 0
    }

    {
      if (!in_server) {
        next
      }

      lines[++line_count] = $0

      if ($0 ~ /^[[:space:]]*listen[[:space:]]+443[[:space:]]+ssl[[:space:]]+http2;[[:space:]]*$/) {
        target_server = 1
      }

      server_depth += brace_delta($0)

      if (server_depth <= 0) {
        flush_server_block()
      }
    }

    END {
      flush_server_block()

      if (invalid || target_count != 1 || client_count > 1) {
        exit 1
      }

      if (client_count == 1) {
        print client_value
      }
    }
  ' "$site_file"
}

rewrite_site_client_max_body_size_config() {
  local site_file="$1"
  local mode="$2"
  local client_max_body_size="$3"
  local output_file="$4"

  awk -v mode="$mode" -v client_max_body_size="$client_max_body_size" '
    function brace_delta(line,    opens, closes, text) {
      text = line
      opens = gsub(/\{/, "{", text)
      closes = gsub(/\}/, "}", text)
      return opens - closes
    }

    function reset_server_state() {
      delete lines
      line_count = 0
      in_server = 0
      target_server = 0
      server_depth = 0
    }

    function print_server_block(    i, server_name_idx, ssl_idx, client_count, invalid_region) {
      if (!in_server) {
        return
      }

      if (!target_server) {
        for (i = 1; i <= line_count; i++) {
          print lines[i]
        }

        reset_server_state()
        return
      }

      target_count++

      for (i = 1; i <= line_count; i++) {
        if (lines[i] ~ /^[[:space:]]*server_name[[:space:]]+/) {
          if (server_name_idx == 0) {
            server_name_idx = i
          } else {
            invalid = 1
          }
        }

        if (lines[i] ~ /^[[:space:]]*ssl_certificate[[:space:]]+/ && ssl_idx == 0) {
          ssl_idx = i
        }

      }

      if (server_name_idx == 0 || ssl_idx == 0 || ssl_idx <= server_name_idx) {
        invalid = 1
      }

      for (i = server_name_idx + 1; i < ssl_idx; i++) {
        if (lines[i] ~ /^[[:space:]]*$/) {
          continue
        }

        if (lines[i] ~ /^[[:space:]]*client_max_body_size[[:space:]]+/) {
          client_count++
          continue
        }

        invalid_region = 1
      }

      if (invalid_region || client_count > 1) {
        invalid = 1
      }

      if (invalid) {
        reset_server_state()
        return
      }

      for (i = 1; i <= server_name_idx; i++) {
        print lines[i]
      }

      print ""

      if (mode == "set") {
        print "    client_max_body_size " client_max_body_size ";"
        print ""
      }

      for (i = ssl_idx; i <= line_count; i++) {
        print lines[i]
      }

      modified = 1
      reset_server_state()
    }

    /^[[:space:]]*server[[:space:]]*\{/ {
      print_server_block()
      in_server = 1
      line_count = 0
      target_server = 0
      server_depth = 0
    }

    {
      if (!in_server) {
        print
        next
      }

      lines[++line_count] = $0

      if ($0 ~ /^[[:space:]]*listen[[:space:]]+443[[:space:]]+ssl[[:space:]]+http2;[[:space:]]*$/) {
        target_server = 1
      }

      server_depth += brace_delta($0)

      if (server_depth <= 0) {
        print_server_block()
      }
    }

    END {
      print_server_block()

      if (invalid || target_count != 1 || !modified) {
        exit 1
      }
    }
  ' "$site_file" > "$output_file"
}

is_npctl_legacy_site_file() {
  local site_file="$1"

  grep -Fq "listen 80;" "$site_file" || return 1
  grep -Fq "listen 443 ssl http2;" "$site_file" || return 1
  grep -Fq "include /etc/nginx/snippets/acme-webroot.conf;" "$site_file" || return 1
  grep -Fq "include /etc/nginx/snippets/redirect-https-308.conf;" "$site_file" || return 1
  grep -Fq "include /etc/nginx/snippets/security-headers.conf;" "$site_file" || return 1
  grep -Fq "include /etc/nginx/snippets/proxy-common.conf;" "$site_file" || return 1
  grep -Fq "location / {" "$site_file" || return 1
  grep -Fq "proxy_pass http://" "$site_file" || return 1
}

is_npctl_managed_site_file() {
  local site_file="$1"
  local site_name

  if [ ! -f "$site_file" ]; then
    return 1
  fi

  site_name="$(basename "$site_file")"

  if [ "$site_name" = "default" ]; then
    return 1
  fi

  extract_unique_site_domain_from_config "$site_file" >/dev/null 2>&1 || return 1
  extract_site_certificate_name_from_config "$site_file" >/dev/null 2>&1 || return 1

  if grep -Fqx "$NPCTL_MANAGED_MARKER" "$site_file"; then
    return 0
  fi

  is_npctl_legacy_site_file "$site_file"
}

load_enabled_sites() {
  local path
  local site_name
  local available_file

  ENABLED_SITE_NAMES=()

  shopt -s nullglob
  for path in "$NGINX_SITES_ENABLED_DIR"/*; do
    [ -L "$path" ] || continue
    site_name="$(basename "$path")"
    available_file="${NGINX_SITES_AVAILABLE_DIR}/${site_name}"

    if ! is_npctl_managed_site_file "$available_file"; then
      continue
    fi

    ENABLED_SITE_NAMES+=("$site_name")
  done
  shopt -u nullglob
}

load_disabled_sites() {
  local path
  local site_name
  local enabled_file

  DISABLED_SITE_NAMES=()

  shopt -s nullglob
  for path in "$NGINX_SITES_AVAILABLE_DIR"/*; do
    [ -f "$path" ] || continue

    site_name="$(basename "$path")"
    enabled_file="${NGINX_SITES_ENABLED_DIR}/${site_name}"

    if [ -e "$enabled_file" ] || [ -L "$enabled_file" ]; then
      continue
    fi

    if ! is_npctl_managed_site_file "$path"; then
      continue
    fi

    DISABLED_SITE_NAMES+=("$site_name")
  done
  shopt -u nullglob
}

show_enabled_sites() {
  local idx
  local site_name
  local available_file
  local cert_name

  if [ "${#ENABLED_SITE_NAMES[@]}" -eq 0 ]; then
    echo "当前没有已启用的 npctl 站点。"
    return 0
  fi

  for idx in "${!ENABLED_SITE_NAMES[@]}"; do
    site_name="${ENABLED_SITE_NAMES[$idx]}"
    available_file="${NGINX_SITES_AVAILABLE_DIR}/${site_name}"
    cert_name="$(extract_site_certificate_name_from_config "$available_file" 2>/dev/null || true)"
    echo " $((idx + 1)). ${site_name}"
    echo "    server_name: $(extract_server_names_from_config "$available_file")"

    if [ -n "$cert_name" ]; then
      echo "    证书: ${cert_name}"
    fi
  done
}

show_disabled_sites() {
  local idx
  local site_name
  local available_file
  local cert_name

  if [ "${#DISABLED_SITE_NAMES[@]}" -eq 0 ]; then
    echo "当前没有可启用的 npctl 站点。"
    return 0
  fi

  for idx in "${!DISABLED_SITE_NAMES[@]}"; do
    site_name="${DISABLED_SITE_NAMES[$idx]}"
    available_file="${NGINX_SITES_AVAILABLE_DIR}/${site_name}"
    cert_name="$(extract_site_certificate_name_from_config "$available_file" 2>/dev/null || true)"
    echo " $((idx + 1)). ${site_name}"
    echo "    server_name: $(extract_server_names_from_config "$available_file")"

    if [ -n "$cert_name" ]; then
      echo "    证书: ${cert_name}"
    fi
  done
}

enable_site() {
  local selection
  local index
  local site_name
  local enabled_file
  local available_file
  local server_names
  local cert_name

  check_nginx_environment || return 1
  load_disabled_sites

  log "可启用站点"
  show_disabled_sites

  if [ "${#DISABLED_SITE_NAMES[@]}" -eq 0 ]; then
    return 0
  fi

  echo " q. 取消"

  while true; do
    read -rp "请选择要启用的站点编号: " selection
    selection="$(trim "$selection")"

    case "$selection" in
      q|Q)
        echo "已取消。"
        return 0
        ;;
    esac

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#DISABLED_SITE_NAMES[@]}" ]; then
      index=$((selection - 1))
      site_name="${DISABLED_SITE_NAMES[$index]}"
      break
    fi

    warn "无效选项 [$selection]。"
  done

  enabled_file="${NGINX_SITES_ENABLED_DIR}/${site_name}"
  available_file="${NGINX_SITES_AVAILABLE_DIR}/${site_name}"
  server_names="$(extract_server_names_from_config "$available_file")"
  cert_name="$(extract_site_certificate_name_from_config "$available_file" 2>/dev/null || true)"

  log "即将启用以下站点"
  echo "站点名: ${site_name}"
  echo "配置文件: ${available_file}"
  echo "启用链接: ${enabled_file}"
  echo "server_name: ${server_names}"

  if [ -n "$cert_name" ]; then
    echo "证书: ${cert_name}"
  fi

  if ! prompt_yes_no "确认启用此站点" "y"; then
    echo "已取消。"
    return 0
  fi

  if [ -e "$enabled_file" ] || [ -L "$enabled_file" ]; then
    warn "站点链接 [$enabled_file] 已存在，无法启用。"
    return 1
  fi

  ln -s "$available_file" "$enabled_file" || return 1

  log "检查 Nginx 配置"
  if ! nginx -t; then
    warn "Nginx 配置校验失败，已回滚本次启用操作。"
    rm -f "$enabled_file"
    return 1
  fi

  log "重载 Nginx"
  if ! systemctl reload nginx; then
    warn "Nginx 重载失败，已回滚本次启用操作。"
    rm -f "$enabled_file"
    return 1
  fi

  log "站点已启用"
  echo "已创建链接: ${enabled_file}"
  echo "配置文件: ${available_file}"
}

disable_site() {
  local selection
  local index
  local site_name
  local enabled_file
  local available_file
  local server_names
  local cert_name

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
  cert_name="$(extract_site_certificate_name_from_config "$available_file" 2>/dev/null || true)"

  log "即将禁用以下站点"
  echo "站点名: ${site_name}"
  echo "配置文件: ${available_file}"
  echo "启用链接: ${enabled_file}"
  echo "server_name: ${server_names}"

  if [ -n "$cert_name" ]; then
    echo "证书: ${cert_name}"
  fi

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

rewrite_site_certificate_config() {
  local site_file="$1"
  local old_cert_name="$2"
  local new_cert_name="$3"
  local output_file="$4"

  awk -v old_cert="$old_cert_name" -v new_cert="$new_cert_name" '
    {
      line = $0

      if ($1 == "ssl_certificate") {
        path = $2
        sub(/;$/, "", path)
        prefix = "/etc/letsencrypt/live/"
        suffix = "/fullchain.pem"

        if (index(path, prefix) != 1) {
          invalid = 1
        } else {
          name = substr(path, length(prefix) + 1)

          if (length(name) <= length(suffix) || substr(name, length(name) - length(suffix) + 1) != suffix) {
            invalid = 1
          } else {
            name = substr(name, 1, length(name) - length(suffix))

            if (name != old_cert) {
              invalid = 1
            } else {
              sub(/\/etc\/letsencrypt\/live\/[^/]+\/fullchain\.pem/, "/etc/letsencrypt/live/" new_cert "/fullchain.pem", line)
              cert_count++
            }
          }
        }
      } else if ($1 == "ssl_certificate_key") {
        path = $2
        sub(/;$/, "", path)
        prefix = "/etc/letsencrypt/live/"
        suffix = "/privkey.pem"

        if (index(path, prefix) != 1) {
          invalid = 1
        } else {
          name = substr(path, length(prefix) + 1)

          if (length(name) <= length(suffix) || substr(name, length(name) - length(suffix) + 1) != suffix) {
            invalid = 1
          } else {
            name = substr(name, 1, length(name) - length(suffix))

            if (name != old_cert) {
              invalid = 1
            } else {
              sub(/\/etc\/letsencrypt\/live\/[^/]+\/privkey\.pem/, "/etc/letsencrypt/live/" new_cert "/privkey.pem", line)
              key_count++
            }
          }
        }
      }

      print line
    }
    END {
      if (invalid || cert_count != 1 || key_count != 1) {
        exit 1
      }
    }
  ' "$site_file" > "$output_file"
}

change_site_certificate() {
  local selection
  local index
  local site_name
  local available_file
  local site_domain
  local current_cert_name
  local current_cert_index
  local current_cert_domains=""
  local current_cert_expiry=""
  local select_result
  local backup_file
  local temp_file

  check_nginx_environment || return 1
  check_certificate_environment || return 1
  load_enabled_sites

  log "可更换证书的已启用站点"
  show_enabled_sites

  if [ "${#ENABLED_SITE_NAMES[@]}" -eq 0 ]; then
    return 0
  fi

  echo " q. 取消"

  while true; do
    read -rp "请选择要更换证书的站点编号: " selection
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

  available_file="${NGINX_SITES_AVAILABLE_DIR}/${site_name}"
  site_domain="$(extract_unique_site_domain_from_config "$available_file")" || {
    warn "无法从配置文件 [$available_file] 解析唯一站点域名。"
    return 1
  }
  current_cert_name="$(extract_site_certificate_name_from_config "$available_file")" || {
    warn "无法从配置文件 [$available_file] 解析当前证书。"
    return 1
  }

  load_certificates || return 1
  current_cert_index="$(find_certificate_index_by_name "$current_cert_name" || true)"

  if [ -n "$current_cert_index" ]; then
    current_cert_domains="${CERTIFICATE_DOMAINS[$current_cert_index]}"
    current_cert_expiry="${CERTIFICATE_EXPIRIES[$current_cert_index]}"
  fi

  log "当前站点证书信息"
  echo "站点名: ${site_name}"
  echo "配置文件: ${available_file}"
  echo "站点域名: ${site_domain}"
  echo "当前证书: ${current_cert_name}"
  echo "当前证书覆盖域名: ${current_cert_domains:-未在 certbot 列表中找到}"

  if [ -n "$current_cert_expiry" ]; then
    echo "当前证书到期: ${current_cert_expiry}"
  fi

  select_certificate "$site_domain"
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

  if [ "$SELECTED_CERT_NAME" = "$current_cert_name" ]; then
    echo "所选证书与当前证书一致，无需修改。"
    return 0
  fi

  log "即将切换站点证书"
  echo "站点名: ${site_name}"
  echo "站点域名: ${site_domain}"
  echo "当前证书: ${current_cert_name}"
  echo "新证书: ${SELECTED_CERT_NAME}"
  echo "新证书覆盖域名: ${SELECTED_CERT_DOMAINS}"

  if [ -n "$SELECTED_CERT_EXPIRY" ]; then
    echo "新证书到期: ${SELECTED_CERT_EXPIRY}"
  fi

  if ! prompt_yes_no "确认切换此站点使用的证书" "y"; then
    echo "已取消。"
    return 0
  fi

  backup_file="$(mktemp /tmp/npctl-site-backup.XXXXXX.conf)" || return 1
  cp "$available_file" "$backup_file" || {
    rm -f "$backup_file"
    return 1
  }

  temp_file="$(mktemp /tmp/npctl-site-edit.XXXXXX.conf)" || {
    rm -f "$backup_file"
    return 1
  }

  rewrite_site_certificate_config "$available_file" "$current_cert_name" "$SELECTED_CERT_NAME" "$temp_file" || {
    warn "仅支持更换 npctl 模板配置中的单组证书引用。"
    rm -f "$temp_file" "$backup_file"
    return 1
  }

  mv "$temp_file" "$available_file" || {
    rm -f "$temp_file" "$backup_file"
    return 1
  }

  log "检查 Nginx 配置"
  if ! nginx -t; then
    warn "Nginx 配置校验失败，已恢复原证书配置。"

    if ! mv "$backup_file" "$available_file"; then
      warn "恢复配置文件失败，请立即手动检查 [$available_file]。"
    fi

    return 1
  fi

  log "重载 Nginx"
  if ! systemctl reload nginx; then
    warn "Nginx 重载失败，已恢复原证书配置。"

    if ! mv "$backup_file" "$available_file"; then
      warn "恢复配置文件失败，请立即手动检查 [$available_file]。"
    fi

    return 1
  fi

  rm -f "$backup_file"

  log "站点证书已更新"
  echo "站点名: ${site_name}"
  echo "站点域名: ${site_domain}"
  echo "原证书: ${current_cert_name}"
  echo "新证书: ${SELECTED_CERT_NAME}"
}

change_site_client_max_body_size() {
  local selection
  local index
  local site_name
  local available_file
  local site_domain
  local current_client_max_body_size=""
  local new_client_max_body_size=""
  local backup_file
  local temp_file
  local action

  check_nginx_environment || return 1
  load_enabled_sites

  log "可修改上传大小限制的已启用站点"
  show_enabled_sites

  if [ "${#ENABLED_SITE_NAMES[@]}" -eq 0 ]; then
    return 0
  fi

  echo " q. 取消"

  while true; do
    read -rp "请选择要修改的站点编号: " selection
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

  available_file="${NGINX_SITES_AVAILABLE_DIR}/${site_name}"
  site_domain="$(extract_unique_site_domain_from_config "$available_file")" || {
    warn "无法从配置文件 [$available_file] 解析唯一站点域名。"
    return 1
  }
  current_client_max_body_size="$(extract_site_client_max_body_size "$available_file" 2>/dev/null || true)"

  if [ -n "$current_client_max_body_size" ]; then
    current_client_max_body_size="$(normalize_client_max_body_size "$current_client_max_body_size")"
  fi

  log "当前站点上传大小限制"
  echo "站点名: ${site_name}"
  echo "配置文件: ${available_file}"
  echo "站点域名: ${site_domain}"
  echo "当前 client_max_body_size: ${current_client_max_body_size:-未设置}"
  echo " 1. 设置或修改 client_max_body_size"
  echo " 2. 删除 client_max_body_size"
  echo " q. 取消"

  while true; do
    read -rp "请选择要执行的编号: " selection
    selection="$(trim "$selection")"

    case "$selection" in
      1)
        action="set"
        new_client_max_body_size="$(prompt_client_max_body_size_value)" || return 1
        break
        ;;
      2)
        action="remove"
        break
        ;;
      q|Q)
        echo "已取消。"
        return 0
        ;;
      *)
        warn "无效选项 [$selection]。"
        ;;
    esac
  done

  if [ "$action" = "remove" ] && [ -z "$current_client_max_body_size" ]; then
    echo "当前未设置 client_max_body_size，无需修改。"
    return 0
  fi

  log "即将修改站点上传大小限制"
  echo "站点名: ${site_name}"
  echo "站点域名: ${site_domain}"
  echo "当前 client_max_body_size: ${current_client_max_body_size:-未设置}"

  if [ "$action" = "set" ]; then
    echo "新 client_max_body_size: ${new_client_max_body_size}"
  else
    echo "新 client_max_body_size: 未设置"
  fi

  if ! prompt_yes_no "确认修改此站点的 client_max_body_size" "y"; then
    echo "已取消。"
    return 0
  fi

  backup_file="$(mktemp /tmp/npctl-site-backup.XXXXXX.conf)" || return 1
  cp "$available_file" "$backup_file" || {
    rm -f "$backup_file"
    return 1
  }

  temp_file="$(mktemp /tmp/npctl-site-edit.XXXXXX.conf)" || {
    rm -f "$backup_file"
    return 1
  }

  rewrite_site_client_max_body_size_config "$available_file" "$action" "$new_client_max_body_size" "$temp_file" || {
    warn "仅支持修改 npctl 模板站点中 443 server 块里的 client_max_body_size。"
    rm -f "$temp_file" "$backup_file"
    return 1
  }

  mv "$temp_file" "$available_file" || {
    rm -f "$temp_file" "$backup_file"
    return 1
  }

  log "检查 Nginx 配置"
  if ! nginx -t; then
    warn "Nginx 配置校验失败，已恢复原站点配置。"

    if ! mv "$backup_file" "$available_file"; then
      warn "恢复配置文件失败，请立即手动检查 [$available_file]。"
    fi

    return 1
  fi

  log "重载 Nginx"
  if ! systemctl reload nginx; then
    warn "Nginx 重载失败，已恢复原站点配置。"

    if ! mv "$backup_file" "$available_file"; then
      warn "恢复配置文件失败，请立即手动检查 [$available_file]。"
    fi

    return 1
  fi

  rm -f "$backup_file"

  log "站点上传大小限制已更新"
  echo "站点名: ${site_name}"
  echo "站点域名: ${site_domain}"
  echo "原 client_max_body_size: ${current_client_max_body_size:-未设置}"

  if [ "$action" = "set" ]; then
    echo "新 client_max_body_size: ${new_client_max_body_size}"
  else
    echo "新 client_max_body_size: 未设置"
  fi
}

update_nginx_package() {
  local version_before=""
  local version_after=""
  local service_was_active=0

  check_nginx_environment || return 1
  check_apt_environment || return 1

  version_before="$(read_nginx_package_version || true)"
  if [ -n "$version_before" ]; then
    echo "当前 nginx 软件包版本: ${version_before}"
  fi

  if systemctl is-active --quiet nginx; then
    service_was_active=1
  fi

  log "刷新软件包索引"
  apt update || return 1

  log "升级 nginx 软件包"
  DEBIAN_FRONTEND=noninteractive apt install --only-upgrade -y nginx || return 1

  version_after="$(read_nginx_package_version || true)"
  if [ -n "$version_after" ]; then
    echo "升级后 nginx 软件包版本: ${version_after}"
  fi

  if [ -n "$version_before" ] && [ -n "$version_after" ]; then
    if [ "$version_before" = "$version_after" ]; then
      echo "nginx 软件包已是最新版本。"
    else
      echo "nginx 软件包已从 ${version_before} 升级到 ${version_after}。"
    fi
  fi

  log "检查 Nginx 配置"
  nginx -t || return 1

  if [ "$service_was_active" -eq 1 ]; then
    log "重载 Nginx"
    systemctl reload nginx || return 1
    echo "已完成 nginx 更新，配置校验通过并已重载服务。"
  else
    warn "未检测到运行中的 nginx，已跳过 reload。"
    echo "已完成 nginx 更新，配置校验通过。"
  fi
}

show_site_state_menu() {
  cat <<'EOF'

---------------- 站点启用/禁用 ----------------
 1. 启用站点
 2. 禁用站点
 q. 返回上级菜单
----------------------------------------------
EOF
}

manage_site_state() {
  local selection

  while true; do
    show_site_state_menu
    read -rp "请输入要执行的编号: " selection

    if [ -z "${selection}" ]; then
      warn "未输入任何选项，请重新输入。"
      continue
    fi

    case "$selection" in
      1) enable_site ;;
      2) disable_site ;;
      q|Q)
        echo "已返回上级菜单。"
        return 0
        ;;
      *)
        warn "无效选项 [$selection]"
        continue
        ;;
    esac

    echo
    echo "本次站点状态操作完成。"
  done
}

show_site_management_menu() {
  cat <<'EOF'

================ 站点管理 ================
 1. 启用/禁用站点
 2. 更换已有站点证书
 3. 设置站点 client_max_body_size
 q. 返回上级菜单
==========================================
EOF
}

manage_sites() {
  local selection

  while true; do
    show_site_management_menu
    read -rp "请输入要执行的编号: " selection

    if [ -z "${selection}" ]; then
      warn "未输入任何选项，请重新输入。"
      continue
    fi

    case "$selection" in
      1) manage_site_state ;;
      2) change_site_certificate ;;
      3) change_site_client_max_body_size ;;
      q|Q)
        echo "已返回主菜单。"
        return 0
        ;;
      *)
        warn "无效选项 [$selection]"
        continue
        ;;
    esac

    echo
    echo "本次站点管理操作完成。"
  done
}

show_menu() {
  cat <<'EOF'

================ nginx proxy control ================
 1. 创建新的反向代理站点
 2. 申请普通域名证书（Webroot）
 3. 申请 Cloudflare 通配证书
 4. 列出本机已有证书
 5. 站点管理
 6. 更新 nginx
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
    5) manage_sites ;;
    6) update_nginx_package ;;
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
