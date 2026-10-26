#!/bin/bash
# Nginx management only. This file never reads or runs sing-box.

NGINX_MAIN_CONFIG="${NGINX_MAIN_CONFIG:-/etc/nginx/nginx.conf}"
NPCTL_STREAM_DIR="${NPCTL_STREAM_DIR:-/etc/nginx/npctl-stream}"
NPCTL_STREAM_BACKUPS="${NPCTL_STREAM_BACKUPS:-/var/backups/npctl}"
NPCTL_STREAM_LOCK="${NPCTL_STREAM_LOCK:-/run/npctl-stream.lock}"
NPCTL_FALLBACK_ROOT="${NPCTL_FALLBACK_ROOT:-/var/www/npctl-fallback}"
NPCTL_STREAM_PARSER="${NPCTL_STREAM_PARSER:-${BASH_SOURCE[0]%/*}/npctl_stream_config.py}"
STREAM_INCLUDE="include $NPCTL_STREAM_DIR/stream.conf; # Managed by npctl SNI"
STREAM_FALLBACK_MARKER='# Managed by npctl fallback website'
declare -a STREAM_SITES=() STREAM_SNAPSHOT_PATHS=()

stream_validate_ownership() {
  local path have_metadata=0
  [[ ! -L $NPCTL_STREAM_DIR ]] || { warn 'SNI 配置目录不能是符号链接。'; return 1; }
  for path in .owner enabled stream.conf nodes.tsv listeners.json; do
    [[ ! -L $NPCTL_STREAM_DIR/$path && ( ! -e $NPCTL_STREAM_DIR/$path || -f $NPCTL_STREAM_DIR/$path ) ]] || {
      warn "SNI 元数据路径不兼容: $path"; return 1;
    }
    [[ ! -e $NPCTL_STREAM_DIR/$path ]] || have_metadata=1
  done
  if [[ $have_metadata == 1 ]] && ! grep -Fqx 'cetaceang/setup_script npctl-stream v1' "$NPCTL_STREAM_DIR/.owner" 2>/dev/null; then
    warn '已有同路径的 SNI 元数据未标记为本项目文件，拒绝覆盖。'; return 1
  fi
  if [[ -f $NPCTL_STREAM_DIR/enabled ]] && ! grep -Fqx '# Managed by npctl SNI' "$NPCTL_STREAM_DIR/enabled"; then
    warn 'SNI 状态文件不属于 npctl，拒绝覆盖。'; return 1
  fi
  if [[ -f $NPCTL_STREAM_DIR/stream.conf ]] && ! grep -Fqx '# Managed by npctl SNI; edit with npctl.' "$NPCTL_STREAM_DIR/stream.conf"; then
    warn 'Stream 配置不属于 npctl，拒绝覆盖。'; return 1
  fi
}

stream_enabled() { [[ -f $NPCTL_STREAM_DIR/enabled ]]; }

site_https_listener() {
  if stream_enabled; then printf '%s' '127.0.0.1:8443'; else printf '%s' '443'; fi
}

stream_require() {
  check_nginx_environment || return 1
  require_command python3 '请先更新 setup 依赖。' || return 1
  require_command openssl '请先安装 openssl。' || return 1
  require_command ss '请先安装 iproute2。' || return 1
  require_path "$NPCTL_STREAM_PARSER" '请使用 setup 选项 9 更新完整 npctl。' || return 1
  [[ ! -L $NGINX_MAIN_CONFIG && -f $NGINX_MAIN_CONFIG ]] || {
    warn 'nginx.conf 不是受支持的普通文件。'; return 1;
  }
  stream_validate_ownership
}

stream_guard_disable_site() {
  local site=$1 domain path count=0
  stream_enabled || return 0
  domain=$(extract_unique_site_domain_from_config "$site") || return 1
  if [[ -f $NPCTL_STREAM_DIR/nodes.tsv ]] && awk -F '\t' -v domain="$domain" '$1 == domain {found=1} END {exit !found}' "$NPCTL_STREAM_DIR/nodes.tsv"; then
    warn '该网站仍被 SNI 节点用作 HTTPS 回落，请先删除映射。'; return 1
  fi
  stream_collect_sites || return 1
  for path in "${STREAM_SITES[@]}"; do [[ ! -e $NGINX_SITES_ENABLED_DIR/${path##*/} ]] || count=$((count + 1)); done
  [[ $count -gt 1 ]] || { warn '分流模式需保留至少一个已启用的 HTTPS 网站。'; return 1; }
}

stream_collect_sites() {
  local path target
  STREAM_SITES=()
  shopt -s nullglob
  for path in "$NGINX_SITES_AVAILABLE_DIR"/*; do
    if is_npctl_managed_site_file "$path"; then
      [[ ! -L $path ]] || { warn "拒绝修改符号链接站点: $path"; return 1; }
      STREAM_SITES+=("$path")
    fi
  done
  # A link with the expected name must also point at the expected file.
  for path in "$NGINX_SITES_ENABLED_DIR"/*; do
    if [[ -L $path ]]; then
      target=$(readlink -f "$path") || return 1
      if is_npctl_managed_site_file "$target" && [[ $target != "$NGINX_SITES_AVAILABLE_DIR/${path##*/}" ]]; then
        warn "站点链接布局不兼容: $path"; return 1
      fi
    fi
  done
  shopt -u nullglob
}

stream_check_layout() {
  local dump sockets raw argv option service_binary
  local -a service_words
  raw=$(systemctl show nginx --property=ExecStart --value) || return 1
  [[ $raw == *'argv[]='* ]] || { warn '无法识别 Nginx 服务的启动参数。'; return 1; }
  argv=${raw#*argv[]=}
  argv=${argv%% ; ignore_errors=*}
  argv=${argv/ -g daemon on; master_process on;/}
  read -r -a service_words <<<"$argv"
  service_binary=$(command -v nginx)
  [[ ${service_words[0]:-} == "$service_binary" ]] || { warn 'Nginx 服务使用其他内核或包装程序，停止自动迁移。'; return 1; }
  service_words=("${service_words[@]:1}")
  while ((${#service_words[@]})); do
    option=${service_words[0]}
    [[ $option == -c && ${service_words[1]:-} == "$NGINX_MAIN_CONFIG" ]] || {
      warn 'Nginx 服务使用自定义配置/参数，无法安全自动迁移。'; return 1;
    }
    service_words=("${service_words[@]:2}")
  done
  nginx -t || return 1
  stream_collect_sites || return 1
  dump=$(mktemp) || return 1
  if ! nginx -T >"$dump" 2>/dev/null; then rm -f "$dump"; return 1; fi
  python3 "$NPCTL_STREAM_PARSER" probe "$dump" "$NPCTL_STREAM_DIR/stream.conf" "${STREAM_SITES[@]}"
  local result=$?
  rm -f "$dump"
  [[ $result == 0 ]] || return 1
  sockets=$(ss -H -ltnp '( sport = :443 or sport = :8443 )') || return 1
  if [[ $sockets ]] && printf '%s\n' "$sockets" | grep -v '"nginx"' >/dev/null; then
    warn '443 或 8443 被其他程序占用，停止操作。'; return 1
  fi
  if ! stream_enabled && [[ $sockets == *:8443* ]]; then
    warn '8443 已被监听，无法安全迁移。'; return 1
  fi
}

stream_module_available() {
  local temp_dir result
  temp_dir=$(mktemp -d) || return 1
  {
    echo 'include /etc/nginx/modules-enabled/*.conf;'
    printf 'pid %s/nginx.pid;\nerror_log stderr;\nevents {}\nstream { ssl_preread on; }\n' "$temp_dir"
  } >"$temp_dir/nginx.conf"
  nginx -t -c "$temp_dir/nginx.conf" >/dev/null 2>&1
  result=$?
  rm -rf "$temp_dir"
  return "$result"
}

stream_ensure_module() {
  stream_module_available && return 0
  require_command apt '当前仅支持 Debian/Ubuntu 自动安装 Stream 模块。' || return 1
  echo '安装与当前 Nginx 软件包匹配的 libnginx-mod-stream。'
  stream_install_module_package || return 1
  stream_module_available || { warn 'Stream / ssl_preread 模块仍不可用，未迁移网站。'; return 1; }
}

stream_install_module_package() (
  # Debian/Ubuntu package triggers use invoke-rc.d/deb-systemd-invoke. Suppress
  # their Nginx service actions until our complete configuration passes -t.
  # Preserve and delegate to any existing host policy for other services.
  local policy=/usr/sbin/policy-rc.d work='' had_policy=0 installed_policy=0 plan
  apt update || return 1
  plan=$(apt-get -s --no-remove install libnginx-mod-stream) || return 1
  if printf '%s\n' "$plan" | grep -Eq '^Inst (nginx|nginx-core|nginx-full|nginx-light|nginx-extras|nginx-common)( |:)'; then
    warn '安装 Stream 模块需要同时升级 Nginx。请先使用菜单更新 Nginx，再启用分流，避免替换正在运行的内核。'
    return 1
  fi
  mkdir /run/npctl-stream-module.lock 2>/dev/null || { warn '另一个模块安装操作正在进行。'; return 1; }
  restore_policy() {
    local status=$?
    trap - EXIT INT TERM HUP
    [[ $installed_policy == 0 ]] || rm -f "$policy"
    if [[ $had_policy == 1 ]]; then
      mv "$work/original" "$policy" || { warn "请立即恢复系统服务策略: $work/original → $policy"; exit 1; }
    fi
    [[ ! $work ]] || rm -rf "$work"
    rmdir /run/npctl-stream-module.lock
    exit "$status"
  }
  trap restore_policy EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  work=$(mktemp -d /usr/sbin/.npctl-policy-XXXXXX) || return 1
  if [[ -e $policy || -L $policy ]]; then
    if [[ -x $policy ]]; then cp -Lp "$policy" "$work/delegate" || return 1; fi
    mv "$policy" "$work/original" || return 1
    had_policy=1
  fi
  installed_policy=1
  {
    printf '#!/bin/bash\noriginal=%q\n' "$work/delegate"
    cat <<'POLICY'
case ${1##*/} in nginx|nginx.service) exit 101 ;; esac
if [[ -x $original ]]; then exec "$original" "$@"; fi
exit 0
POLICY
  } >"$policy" || return 1
  chmod 755 "$policy" || return 1
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get --no-remove install -y libnginx-mod-stream
)

stream_snapshot() {
  local path=$1 item existing
  for existing in "${STREAM_SNAPSHOT_PATHS[@]}"; do [[ $existing != "$path" ]] || return 0; done
  item=${#STREAM_SNAPSHOT_PATHS[@]}
  STREAM_SNAPSHOT_PATHS+=("$path")
  if [[ -e $path || -L $path ]]; then
    [[ ! -d $path ]] || { warn '事务只允许修改单个文件或链接。'; return 1; }
    cp -a "$path" "$STREAM_BACKUP/files/$item" || return 1
    printf 'restore_item %q %q\n' "$path" "$item" >>"$STREAM_BACKUP/restore-files.sh"
  else
    printf 'remove_item %q\n' "$path" >>"$STREAM_BACKUP/restore-files.sh"
  fi
}

stream_transaction() (
  umask 077
  local action=$1 committed=0 touched=0 reload_attempted=0
  shift
  STREAM_SNAPSHOT_PATHS=()
  stream_validate_ownership || return 1
  mkdir "$NPCTL_STREAM_LOCK" 2>/dev/null || { warn '另一个 SNI 管理操作正在运行。'; return 1; }
  stream_cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [[ $committed == 0 && $touched == 1 ]]; then
      if ! bash "$STREAM_BACKUP/restore-files.sh"; then
        warn "配置恢复失败，请立即执行 $STREAM_BACKUP/rollback.sh"
        status=1
      elif [[ $reload_attempted == 1 ]]; then
        nginx -t && systemctl reload nginx || warn "旧配置已恢复，但恢复运行失败，请执行 $STREAM_BACKUP/rollback.sh"
      fi
      warn "本次操作失败，已恢复原配置。备份: $STREAM_BACKUP"
    fi
    rmdir "$NPCTL_STREAM_LOCK"
    exit "$status"
  }
  trap stream_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  nginx -t || return 1
  systemctl is-active --quiet nginx || { warn 'Nginx 未运行，请先恢复现有网站服务。'; return 1; }
  mkdir -p "$NPCTL_STREAM_BACKUPS" "$NPCTL_STREAM_DIR" || return 1
  chmod 700 "$NPCTL_STREAM_BACKUPS" || return 1
  STREAM_BACKUP=$(mktemp -d "$NPCTL_STREAM_BACKUPS/sni-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || return 1
  mkdir "$STREAM_BACKUP/files" || return 1
  {
    printf '#!/bin/bash\nset -e\nbackup=%q\n' "$STREAM_BACKUP"
    cat <<'RESTORE'
restore_item() { mkdir -p "${1%/*}"; rm -f "$1"; cp -a "$backup/files/$2" "$1"; }
remove_item() { rm -f "$1"; }
RESTORE
  } >"$STREAM_BACKUP/restore-files.sh" || return 1
  {
    printf '#!/bin/bash\nset -e\nlock=%q\nbackup=%q\n' "$NPCTL_STREAM_LOCK" "$STREAM_BACKUP"
    cat <<'ROLLBACK'
mkdir "$lock" 2>/dev/null || { echo '另一个 SNI 管理操作正在运行。' >&2; exit 1; }
trap 'rmdir "$lock"' EXIT
bash "$backup/restore-files.sh"
nginx -t
systemctl reload nginx
echo '已恢复本次操作前的配置并重载 Nginx。'
ROLLBACK
  } >"$STREAM_BACKUP/rollback.sh" || return 1
  chmod 700 "$STREAM_BACKUP/rollback.sh" "$STREAM_BACKUP/restore-files.sh" || return 1
  touched=1
  stream_snapshot "$NPCTL_STREAM_DIR/.owner" || return 1
  printf 'cetaceang/setup_script npctl-stream v1\n' >"$NPCTL_STREAM_DIR/.owner" || return 1
  "$action" "$@" || return 1
  nginx -t || return 1
  reload_attempted=1
  systemctl reload nginx || return 1
  committed=1
  printf '操作已完成。备份及手动回滚: bash %s/rollback.sh\n' "$STREAM_BACKUP"
)

stream_write_config() {
  local domain port index=0
  stream_snapshot "$NPCTL_STREAM_DIR/stream.conf" || return 1
  {
    echo '# Managed by npctl SNI; edit with npctl.'
    echo 'stream {'
    echo '    map $ssl_preread_server_name $npctl_sni_backend {'
    echo '        hostnames;'
    echo '        default npctl_https_fallback;'
    while IFS=$'\t' read -r domain port; do
      [[ $domain ]] || continue
      validate_domain "$domain" && validate_port "$port" || return 1
      printf '        %s npctl_reality_%s;\n' "$domain" "$index"
      index=$((index + 1))
    done <"$NPCTL_STREAM_DIR/nodes.tsv"
    echo '    }'
    echo '    upstream npctl_https_fallback { server 127.0.0.1:8443; }'
    index=0
    while IFS=$'\t' read -r domain port; do
      [[ $domain ]] || continue
      printf '    upstream npctl_reality_%s { server 127.0.0.1:%s; }\n' "$index" "$port"
      index=$((index + 1))
    done <"$NPCTL_STREAM_DIR/nodes.tsv"
    cat <<'STREAM'
    server {
        listen 0.0.0.0:443;
        listen [::]:443 ipv6only=on;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        proxy_pass $npctl_sni_backend;
    }
}
STREAM
  } >"$NPCTL_STREAM_DIR/stream.conf"
}

stream_migrate() {
  local direction=$1 path
  stream_collect_sites || return 1
  stream_snapshot "$NPCTL_STREAM_DIR/listeners.json" || return 1
  for path in "${STREAM_SITES[@]}"; do stream_snapshot "$path" || return 1; done
  python3 "$NPCTL_STREAM_PARSER" migrate "$direction" "$NPCTL_STREAM_DIR/listeners.json" "${STREAM_SITES[@]}"
}

stream_do_enable() {
  stream_check_layout || return 1
  stream_snapshot "$NGINX_MAIN_CONFIG" || return 1
  stream_snapshot "$NPCTL_STREAM_DIR/nodes.tsv" || return 1
  stream_snapshot "$NPCTL_STREAM_DIR/enabled" || return 1
  [[ -f $NPCTL_STREAM_DIR/nodes.tsv ]] || printf '' >"$NPCTL_STREAM_DIR/nodes.tsv"
  stream_migrate enable || return 1
  stream_write_config || return 1
  if ! grep -Fqx "$STREAM_INCLUDE" "$NGINX_MAIN_CONFIG"; then
    printf '\n%s\n' "$STREAM_INCLUDE" >>"$NGINX_MAIN_CONFIG" || return 1
  fi
  printf '# Managed by npctl SNI\n' >"$NPCTL_STREAM_DIR/enabled"
}

stream_confirm_enable() {
  local path domain=${1:-}
  log '将迁移以下 npctl HTTPS 站点（包括暂未启用的站点）'
  [[ ${#STREAM_SITES[@]} -gt 0 ]] || echo '  当前没有已有 HTTPS 站点。'
  for path in "${STREAM_SITES[@]}"; do
    printf '  %s: HTTPS 443 → 127.0.0.1:8443\n' "$path"
  done
  [[ ! $domain ]] || echo "将为节点 $domain 复用或创建 HTTPS 回落网站，并添加 SNI 映射。"
  echo '公网 IPv4/IPv6 TCP 443 将由 Nginx Stream 独占；80、证书和网站内容保留。'
  warn 'HTTPS 后端将看到本地连接 IP。访问日志、X-Real-IP/X-Forwarded-For、IP ACL、限速及 Fail2Ban 的客户端 IP 识别会受影响；本功能不传送或伪造客户端 IP。'
  prompt_yes_no '确认启用 SNI 分流并执行以上变更' n
}

stream_enable() {
  local path active=0
  stream_require || return 1
  if stream_enabled; then echo 'SNI 分流已启用，未重复迁移。'; return 0; fi
  stream_check_layout || return 1
  for path in "${STREAM_SITES[@]}"; do
    [[ ! -e $NGINX_SITES_ENABLED_DIR/${path##*/} ]] || active=$((active + 1))
  done
  if [[ $active == 0 ]]; then
    echo '当前没有已启用的 HTTPS 站点，请添加首个节点；对应的 HTTPS 回落网站与 SNI 分流将一起配置。'
    stream_add_node
    return $?
  fi
  stream_confirm_enable || return 0
  stream_ensure_module || return 1
  stream_transaction stream_do_enable
}

stream_do_disable() {
  local temp
  stream_snapshot "$NGINX_MAIN_CONFIG" || return 1
  stream_snapshot "$NPCTL_STREAM_DIR/enabled" || return 1
  stream_snapshot "$NPCTL_STREAM_DIR/stream.conf" || return 1
  stream_migrate disable || return 1
  temp=$(mktemp) || return 1
  awk -v npctl_include_line="$STREAM_INCLUDE" '$0 != npctl_include_line' "$NGINX_MAIN_CONFIG" >"$temp" || { rm -f "$temp"; return 1; }
  cat "$temp" >"$NGINX_MAIN_CONFIG" || { rm -f "$temp"; return 1; }
  rm -f "$temp" "$NPCTL_STREAM_DIR/enabled" "$NPCTL_STREAM_DIR/stream.conf"
}

stream_disable() {
  stream_require || return 1
  stream_enabled || { echo 'SNI 分流已禁用。'; return 0; }
  stream_check_layout || return 1
  echo '将网站恢复为直接监听原来的公网 443；节点映射、回落网站和证书保留。'
  prompt_yes_no '确认禁用 SNI 分流' n || return 0
  stream_transaction stream_do_disable
}

stream_find_website() {
  local domain=$1 path found=
  stream_collect_sites || return 1
  for path in "${STREAM_SITES[@]}"; do
    if [[ $(extract_unique_site_domain_from_config "$path") == "$domain" ]]; then
      [[ ! $found ]] || { warn "同一域名存在多个 npctl 网站: $domain"; return 1; }
      found=$path
    fi
  done
  printf '%s' "$found"
}

stream_certificate_valid() {
  local domain=$1 name=$2 cert=$LETSENCRYPT_DIR/live/$2/fullchain.pem
  [[ $name && -f $cert && -f $LETSENCRYPT_DIR/live/$name/privkey.pem ]] &&
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 &&
    # OpenSSL 1.1.1/3.0 may exit zero even when -checkhost does not match.
    LC_ALL=C openssl x509 -in "$cert" -noout -checkhost "$domain" 2>/dev/null |
      grep -Fqx "Hostname $domain does match certificate"
}

stream_select_certificate() {
  local domain=$1 name index
  check_certificate_environment || return 1
  load_certificates || return 1
  # Reuse a valid exact/wildcard certificate without requesting another one.
  for index in "${!CERTIFICATE_NAMES[@]}"; do
    name=${CERTIFICATE_NAMES[$index]}
    if certificate_covers_domain "${CERTIFICATE_DOMAINS[$index]}" "$domain" && stream_certificate_valid "$domain" "$name"; then
      SELECTED_CERT_NAME=$name
      echo "复用证书: $name（覆盖 $domain）"
      return 0
    fi
  done
  while true; do
    select_certificate "$domain" || return 1
    stream_certificate_valid "$domain" "$SELECTED_CERT_NAME" && return 0
    warn '所选证书已过期、缺少文件或未覆盖此 SNI；请选择有效证书，或申请 Webroot / Cloudflare 通配证书。'
  done
}

stream_build_fallback() {
  local domain=$1 certificate=$2 available=$NGINX_SITES_AVAILABLE_DIR/$1
  stream_snapshot "$available" || return 1
  stream_snapshot "$NGINX_SITES_ENABLED_DIR/$domain" || return 1
  stream_snapshot "$NPCTL_FALLBACK_ROOT/$domain/index.html" || return 1
  mkdir -p "$NPCTL_FALLBACK_ROOT/$domain" || return 1
  chmod 755 "$NPCTL_FALLBACK_ROOT" "$NPCTL_FALLBACK_ROOT/$domain" || return 1
  printf '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>\n' >"$NPCTL_FALLBACK_ROOT/$domain/index.html" || return 1
  chmod 644 "$NPCTL_FALLBACK_ROOT/$domain/index.html" || return 1
  cat >"$available" <<EOF
$NPCTL_MANAGED_MARKER
$STREAM_FALLBACK_MARKER
server {
    listen 80;
    server_name $domain;
    include /etc/nginx/snippets/acme-webroot.conf;
    include /etc/nginx/snippets/redirect-https-308.conf;
}
server {
    listen $(site_https_listener) ssl http2;
    server_name $domain;
    ssl_certificate /etc/letsencrypt/live/$certificate/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$certificate/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    include /etc/nginx/snippets/security-headers.conf;
    include /etc/nginx/snippets/acme-webroot.conf;
    root $NPCTL_FALLBACK_ROOT/$domain;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  ln -s "$available" "$NGINX_SITES_ENABLED_DIR/$domain"
}

stream_prepare_website() {
  local domain=$1 current_cert
  STREAM_WEBSITE=$(stream_find_website "$domain") || return 1
  STREAM_CERTIFICATE=
  if [[ $STREAM_WEBSITE ]]; then
    current_cert=$(extract_site_certificate_name_from_config "$STREAM_WEBSITE") || return 1
    if stream_certificate_valid "$domain" "$current_cert"; then
      STREAM_CERTIFICATE=$current_cert
      return 0
    fi
    echo "已有网站的证书未覆盖 $domain 或已过期，需要更换有效证书。"
  elif [[ -e $NGINX_SITES_AVAILABLE_DIR/$domain || -L $NGINX_SITES_AVAILABLE_DIR/$domain ||
            -e $NGINX_SITES_ENABLED_DIR/$domain || -L $NGINX_SITES_ENABLED_DIR/$domain ]]; then
    warn '同名网站不是可安全管理的 npctl 网站，停止操作。'; return 1
  else
    check_site_template_environment || return 1
    prompt_yes_no "没有 $domain 的已有网站，是否创建独立的静态 HTTPS 回落网站" y || return 1
  fi
  stream_select_certificate "$domain" || return 1
  STREAM_CERTIFICATE=$SELECTED_CERT_NAME
}

stream_ensure_website() {
  local domain=$1 temp old
  if [[ ! $STREAM_WEBSITE ]]; then
    stream_build_fallback "$domain" "$STREAM_CERTIFICATE" || return 1
  else
    stream_snapshot "$STREAM_WEBSITE" || return 1
    old=$(extract_site_certificate_name_from_config "$STREAM_WEBSITE") || return 1
    if [[ $old != "$STREAM_CERTIFICATE" ]]; then
      temp=$(mktemp) || return 1
      rewrite_site_certificate_config "$STREAM_WEBSITE" "$old" "$STREAM_CERTIFICATE" "$temp" || { rm -f "$temp"; return 1; }
      cat "$temp" >"$STREAM_WEBSITE" || { rm -f "$temp"; return 1; }
      rm -f "$temp"
    fi
    if [[ ! -e $NGINX_SITES_ENABLED_DIR/${STREAM_WEBSITE##*/} ]]; then
      stream_snapshot "$NGINX_SITES_ENABLED_DIR/${STREAM_WEBSITE##*/}" || return 1
      ln -s "$STREAM_WEBSITE" "$NGINX_SITES_ENABLED_DIR/${STREAM_WEBSITE##*/}" || return 1
    fi
  fi
}

stream_validate_node() {
  local domain=$1 port=$2 replacing_domain=${3:-} existing_domain existing_port
  validate_domain "$domain" && validate_port "$port" && [[ $port != 443 && $port != 8443 && $port != 80 ]] || {
    warn '节点需使用有效 SNI 域名与 1–65535 本地端口，不能使用 80、443 或 8443。'; return 1;
  }
  [[ -f $NPCTL_STREAM_DIR/nodes.tsv ]] || return 0
  while IFS=$'\t' read -r existing_domain existing_port; do
    [[ ! $replacing_domain || $existing_domain != "$replacing_domain" ]] || continue
    if [[ $domain == "$existing_domain" || $port == "$existing_port" ]]; then
      warn 'SNI 或节点本地端口已被其他映射使用。'; return 1
    fi
  done <"$NPCTL_STREAM_DIR/nodes.tsv"
}

stream_do_add_node() {
  local domain=$1 port=$2 enable_requested=${3:-0}
  stream_validate_node "$domain" "$port" || return 1
  if ! stream_enabled; then
    [[ $enable_requested == 1 ]] || { warn 'SNI 状态已变化，请重新添加节点并确认启用。'; return 1; }
    stream_check_layout || return 1
  fi
  stream_certificate_valid "$domain" "$STREAM_CERTIFICATE" || {
    warn '节点证书已失效或未覆盖 SNI，未添加映射。'; return 1;
  }
  stream_ensure_website "$domain" || return 1
  # Keep site creation, listener migration and the first mapping in one
  # transaction. No intermediate configuration is reloaded.
  if ! stream_enabled; then stream_do_enable || return 1; fi
  stream_snapshot "$NPCTL_STREAM_DIR/nodes.tsv" || return 1
  printf '%s\t%s\n' "$domain" "$port" >>"$NPCTL_STREAM_DIR/nodes.tsv" || return 1
  stream_write_config
}

stream_add_node() {
  local domain port enable_requested=0
  stream_require || return 1
  read -r -p '节点 SNI 域名（留空取消）: ' domain || return 1
  [[ $domain ]] || { echo '已取消添加节点。'; return 0; }
  domain=${domain,,}
  read -r -p '节点本地监听端口: ' port || return 1
  stream_validate_node "$domain" "$port" || return 1
  stream_check_layout || return 1
  if ! stream_enabled; then
    stream_confirm_enable "$domain" || return 0
    stream_ensure_module || return 1
    enable_requested=1
  fi
  stream_prepare_website "$domain" || return 1
  stream_transaction stream_do_add_node "$domain" "$port" "$enable_requested" || return 1
  echo "客户端: server=$domain, port=443, servername=$domain"
  echo '请在 sing-box 管理脚本中自行设置 REALITY handshake: 127.0.0.1:8443。'
  echo '域名需解析到本机；Cloudflare 应使用仅 DNS（灰云），本工具不修改 DNS。'
}

stream_show_nodes() {
  local domain port site certificate valid website
  if stream_enabled; then echo 'SNI 分流: 已启用'; else echo 'SNI 分流: 已禁用（保留映射）'; fi
  echo '默认目标: Nginx 本地 HTTPS 127.0.0.1:8443'
  [[ -f $NPCTL_STREAM_DIR/nodes.tsv ]] || return 0
  while IFS=$'\t' read -r domain port; do
    [[ $domain ]] || continue
    site=$(stream_find_website "$domain") || return 1
    certificate=无; valid=无有效证书; website=无
    if [[ $site ]]; then
      certificate=$(extract_site_certificate_name_from_config "$site") || return 1
      website=存在但未启用
      [[ ! -e $NGINX_SITES_ENABLED_DIR/${site##*/} ]] || website=存在且已启用
      stream_certificate_valid "$domain" "$certificate" && valid=有效且覆盖SNI
    fi
    printf '%s → 127.0.0.1:%s | 证书 %s (%s) | 回落网站 %s\n' "$domain" "$port" "$certificate" "$valid" "$website"
  done <"$NPCTL_STREAM_DIR/nodes.tsv"
}

stream_node_port() {
  [[ -f $NPCTL_STREAM_DIR/nodes.tsv ]] || return 1
  awk -F '\t' -v sni="$1" '$1 == sni {port=$2; count++} END {if (count == 1) print port; else exit 1}' "$NPCTL_STREAM_DIR/nodes.tsv"
}

stream_do_change_node_port() {
  local domain=$1 port=$2 expected_port=$3 current_port temp
  current_port=$(stream_node_port "$domain") || { warn '未找到唯一的节点映射。'; return 1; }
  [[ $current_port == "$expected_port" ]] || { warn '节点端口已被其他操作修改，请重新选择。'; return 1; }
  stream_validate_node "$domain" "$port" "$domain" || return 1
  stream_snapshot "$NPCTL_STREAM_DIR/nodes.tsv" || return 1
  temp=$(mktemp) || return 1
  awk -F '\t' -v sni="$domain" -v target_port="$port" 'BEGIN {OFS="\t"} $1 == sni {$2=target_port} {print}' \
    "$NPCTL_STREAM_DIR/nodes.tsv" >"$temp" || { rm -f "$temp"; return 1; }
  cat "$temp" >"$NPCTL_STREAM_DIR/nodes.tsv" || { rm -f "$temp"; return 1; }
  rm -f "$temp"
  if stream_enabled; then stream_write_config || return 1; fi
}

stream_change_node_port() {
  local domain port current_port
  stream_require || return 1
  [[ -s $NPCTL_STREAM_DIR/nodes.tsv ]] || { warn '暂无可修改的 SNI 节点映射。'; return 1; }
  stream_show_nodes || return 1
  read -r -p '要修改的节点 SNI（留空取消）: ' domain || return 1
  [[ $domain ]] || { echo '已取消修改。'; return 0; }
  domain=${domain,,}
  validate_domain "$domain" || { warn 'SNI 域名无效。'; return 1; }
  current_port=$(stream_node_port "$domain") || { warn '未找到唯一的节点映射。'; return 1; }
  read -r -p "新后端端口 [$current_port]: " port || return 1
  port=${port:-$current_port}
  stream_validate_node "$domain" "$port" "$domain" || return 1
  [[ $port != "$current_port" ]] || { echo '端口未变化，无需修改。'; return 0; }
  stream_check_layout || return 1
  echo "$domain: 127.0.0.1:$current_port → 127.0.0.1:$port"
  echo '此处只修改 Nginx 转发目标，请确保对应 sing-box 节点已监听新端口。'
  prompt_yes_no '确认修改此节点后端端口' n || return 0
  stream_transaction stream_do_change_node_port "$domain" "$port" "$current_port" || return 1
  echo "已更新节点后端: $domain → 127.0.0.1:$port"
}

stream_do_delete_node() {
  local domain=$1 temp
  stream_snapshot "$NPCTL_STREAM_DIR/nodes.tsv" || return 1
  temp=$(mktemp) || return 1
  awk -F '\t' -v domain="$domain" '$1 != domain' "$NPCTL_STREAM_DIR/nodes.tsv" >"$temp" || { rm -f "$temp"; return 1; }
  cat "$temp" >"$NPCTL_STREAM_DIR/nodes.tsv" || { rm -f "$temp"; return 1; }
  rm -f "$temp"
  if stream_enabled; then stream_write_config; fi
}

stream_delete_node() {
  local domain
  stream_require || return 1
  stream_show_nodes || return 1
  read -r -p '要删除的节点 SNI: ' domain
  domain=${domain,,}
  validate_domain "$domain" || return 1
  [[ -f $NPCTL_STREAM_DIR/nodes.tsv ]] && awk -F '\t' -v domain="$domain" '$1 == domain {found=1} END {exit !found}' "$NPCTL_STREAM_DIR/nodes.tsv" || {
    warn '未找到此映射。'; return 1;
  }
  stream_transaction stream_do_delete_node "$domain" || return 1
  echo '已删除映射；网站和证书继续保留。'
}

stream_create_fallback() {
  local domain
  stream_require && check_site_template_environment || return 1
  read -r -p 'HTTPS 回落网站域名: ' domain
  domain=${domain,,}
  validate_domain "$domain" || { warn '域名无效。'; return 1; }
  stream_prepare_website "$domain" || return 1
  stream_transaction stream_ensure_website "$domain"
}

stream_do_delete_fallback() {
  local domain=$1 path
  for path in "$NGINX_SITES_AVAILABLE_DIR/$domain" "$NGINX_SITES_ENABLED_DIR/$domain" "$NPCTL_FALLBACK_ROOT/$domain/index.html"; do
    stream_snapshot "$path" || return 1
    rm -f "$path" || return 1
  done
}

stream_delete_fallback() {
  local domain site count=0 path
  stream_require || return 1
  read -r -p '要删除的静态回落网站域名: ' domain
  domain=${domain,,}
  validate_domain "$domain" || return 1
  site=$NGINX_SITES_AVAILABLE_DIR/$domain
  [[ -f $site ]] && grep -Fqx "$STREAM_FALLBACK_MARKER" "$site" || {
    warn '仅能删除本功能创建的静态回落网站；普通反代站点请使用站点管理。'; return 1;
  }
  if [[ -f $NPCTL_STREAM_DIR/nodes.tsv ]] && awk -F '\t' -v domain="$domain" '$1 == domain {found=1} END {exit !found}' "$NPCTL_STREAM_DIR/nodes.tsv"; then
    warn '此网站仍被节点使用，请先删除映射。'; return 1
  fi
  if stream_enabled; then
    stream_collect_sites || return 1
    for path in "${STREAM_SITES[@]}"; do [[ ! -e $NGINX_SITES_ENABLED_DIR/${path##*/} ]] || count=$((count + 1)); done
    [[ $count -gt 1 || ! -e $NGINX_SITES_ENABLED_DIR/$domain ]] || { warn '不能删除分流模式下最后一个已启用 HTTPS 网站。'; return 1; }
  fi
  prompt_yes_no '确认删除该静态回落网站（保留证书）' n || return 0
  stream_transaction stream_do_delete_fallback "$domain"
}

stream_manage_fallbacks() {
  local selection path
  while true; do
    echo 'HTTPS 回落网站: 1. 查看  2. 创建/复用  3. 删除静态回落网站  q. 返回'
    read -r -p '请选择: ' selection
    case $selection in
      1)
        stream_collect_sites || return 1
        for path in "${STREAM_SITES[@]}"; do printf '%s | 证书 %s\n' "$(extract_unique_site_domain_from_config "$path")" "$(extract_site_certificate_name_from_config "$path")"; done ;;
      2) stream_create_fallback ;;
      3) stream_delete_fallback ;;
      q|Q) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}

manage_stream() {
  local selection
  while true; do
    echo 'SNI 分流管理: 1. 启用  2. 添加节点  3. 查看映射  4. 删除节点  5. HTTPS 回落网站  6. 禁用  7. 修改节点后端端口  q. 返回'
    read -r -p '请选择: ' selection
    case $selection in
      1) stream_enable ;;
      2) stream_add_node ;;
      3) stream_show_nodes ;;
      4) stream_delete_node ;;
      5) stream_manage_fallbacks ;;
      6) stream_disable ;;
      7) stream_change_node_port ;;
      q|Q) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}
