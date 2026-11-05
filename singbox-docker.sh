#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_VERSION="2026.11.06.2"

SING_BOX_VERSION="${SING_BOX_VERSION:-latest}"
SING_BOX_IMAGE="${SING_BOX_IMAGE:-ghcr.io/sagernet/sing-box:${SING_BOX_VERSION}}"
WORK_DIR="${WORK_DIR:-/opt/sing-box}"
CONFIG_DIR="$WORK_DIR/config"
DATA_DIR="$WORK_DIR/data"
CONFIG_FILE="$CONFIG_DIR/config.json"
INFO_FILE="$WORK_DIR/nodes.txt"
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
BACKUP_DIR="$WORK_DIR/backup"
SCRIPT_PATH="${SCRIPT_PATH:-/usr/local/bin/sb}"
DEFAULT_SCRIPT_URL="https://api.github.com/repos/MISThelio/singbox-docker/contents/singbox-docker.sh?ref=main"
FALLBACK_SCRIPT_URL="https://raw.githubusercontent.com/MISThelio/singbox-docker/main/singbox-docker.sh"
SCRIPT_URL="${SCRIPT_URL:-$DEFAULT_SCRIPT_URL}"
SCRIPT_ACCEPT="${SCRIPT_ACCEPT:-application/vnd.github.raw}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:stable-alpine}"

green(){ printf '\033[32m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }
red(){ printf '\033[31m%s\033[0m\n' "$1"; }

check_root(){
  [ "${EUID:-$(id -u)}" -eq 0 ] || { red "请用 root 运行"; exit 1; }
}

pause(){
  echo
  read -rp "按回车继续..."
}

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { red "缺少命令：$1"; exit 1; }
}

install_shortcut(){
  if [ "$(realpath "$0" 2>/dev/null || printf '%s' "$0")" = "$SCRIPT_PATH" ]; then
    chmod +x "$SCRIPT_PATH"
  else
    install -m 0755 "$0" "$SCRIPT_PATH"
  fi
  green "快捷命令已安装：sb"
}

install_packages(){
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl wget openssl jq uuid-runtime util-linux ca-certificates iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget openssl jq util-linux ca-certificates iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget openssl jq util-linux ca-certificates iproute
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive refresh
    zypper --non-interactive install curl wget openssl jq util-linux ca-certificates iproute2
  elif command -v apk >/dev/null 2>&1; then
    apk update
    apk add --no-cache bash curl wget openssl jq util-linux ca-certificates iproute2 gcompat
  else
    red "暂不支持当前系统包管理器，请手动安装 bash/curl/wget/openssl/jq/uuidgen/iproute2"
    exit 1
  fi
}

install_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  fi

  if ! docker compose version >/dev/null 2>&1; then
    red "Docker Compose 插件不可用，请安装 docker compose plugin 后重试"
    exit 1
  fi
}

write_default_config(){
  [ -f "$CONFIG_FILE" ] && return

  cat > "$CONFIG_FILE" <<'JSON'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
JSON
}

write_compose_file(){
  if [ -f "$COMPOSE_FILE" ]; then
    yellow "已存在 docker-compose.yml，跳过覆盖"
    return
  fi

  cat > "$COMPOSE_FILE" <<YAML
services:
  sing-box:
    image: ${SING_BOX_IMAGE}
    container_name: sing-box
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config:/etc/sing-box
      - ./data:/var/lib/sing-box
    command: -D /var/lib/sing-box -C /etc/sing-box run
YAML
}

sync_compose_image(){
  local tmp
  tmp=$(mktemp "$WORK_DIR/.compose.XXXXXX")
  if ! compose config --no-interpolate --no-env-resolution --no-path-resolution --format json \
    | jq --arg image "${1:-$SING_BOX_IMAGE}" '.services["sing-box"].image = $image' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! docker compose --project-directory "$WORK_DIR" -f "$tmp" config -q; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$COMPOSE_FILE"
}

compose(){
  docker compose --project-directory "$WORK_DIR" -f "$COMPOSE_FILE" "$@"
}

compose_image(){
  docker compose --project-directory "$WORK_DIR" -f "${1:-$COMPOSE_FILE}" config --format json \
    | jq -er '.services["sing-box"].image | select(type == "string" and length > 0)'
}

runtime_image(){
  local id
  id=$(service_container) || return 1
  if [ -n "$id" ]; then
    docker inspect --format '{{.Image}}' "$id"
  else
    compose_image
  fi
}

service_container(){
  local ids
  ids=$(compose ps -a -q sing-box) || return 1
  [ -n "$ids" ] || return 0
  docker inspect $ids | jq -r '
    map(select(.State.Status != "created"))
    | sort_by(.State.Running, .State.StartedAt) | last | .Id // empty'
}

wait_service(){
  local id="$1" state stable=0 attempt
  for ((attempt=0; attempt<20; attempt++)); do
    state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id") || return 1
    case "$state" in
      'running healthy'|'running none')
        stable=$((stable + 1))
        [ "$stable" -ge 3 ] && return 0
        ;;
      'running starting'|'restarting '*) stable=0 ;;
      *) red "sing-box 未正常运行：$state"; return 1 ;;
    esac
    sleep 1
  done
  red "等待 sing-box 启动超时"
  return 1
}

recover_service(){
  local old_id="$1" old_image="$2" id replacements
  [ -n "$old_image" ] || { red "没有可恢复的旧容器镜像"; return 1; }
  replacements=$(compose ps -a -q sing-box) || return 1
  for id in $replacements; do
    if [ "$id" != "$old_id" ]; then
      docker stop "$id" || return 1
    fi
  done
  sync_compose_image "$old_image" || return 1
  if [ -n "$old_id" ] && docker container inspect "$old_id" >/dev/null 2>&1; then
    docker restart "$old_id" || return 1
    wait_service "$old_id" || return 1
  else
    # A pulled tag can point at a new image; recovery must use the old image ID.
    compose up -d --no-deps --force-recreate sing-box || return 1
    id=$(service_container) || return 1
    [ -n "$id" ] && wait_service "$id" || return 1
  fi
  yellow "旧服务已恢复；本次变更未成功"
}

run_locked(){
  need_cmd flock
  mkdir -p "$WORK_DIR"
  (
    if ! flock -n 9; then
      red "另一个管理操作正在执行，请完成后重试"
      return 1
    fi
    "$@"
  ) 9>"$WORK_DIR/.operation.lock"
}

install_base(){
  install_packages
  install_docker

  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_DIR"
  write_default_config
  write_compose_file
  install_shortcut
  green "基础环境初始化完成"
}

prepare_runtime(){
  local missing=0

  for cmd in docker jq openssl curl ss uuidgen; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      red "缺少命令：$cmd"
      missing=1
    fi
  done

  if ! docker compose version >/dev/null 2>&1; then
    red "Docker Compose 插件不可用"
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    yellow "请先进入：系统优化 -> 初始化/修复 sing-box Docker 环境"
    return 1
  fi

  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_DIR"
  write_default_config
  write_compose_file
  install_shortcut
}

ensure_singbox_image(){
  local image
  image="${1:-$(runtime_image)}" || return 1
  [ -n "$image" ] || return 1
  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi

  yellow "本地没有 sing-box 镜像，正在拉取：$image"
  local pull_log
  pull_log=$(mktemp)

  if docker pull "$image" 2>&1 | tee "$pull_log"; then
    rm -f "$pull_log"
    return 0
  fi

  if grep -qi 'denied' "$pull_log" && printf '%s' "$image" | grep -q '^ghcr\.io/'; then
    red "GHCR 返回 denied。常见原因是 Docker 保存了失效的 ghcr.io 登录凭据，或当前网络无法匿名拉取 GHCR。"
    read -rp "是否执行 docker logout ghcr.io 后重试？输入 y: " retry_ghcr
    if [ "$retry_ghcr" = "y" ]; then
      docker logout ghcr.io || true
      if docker pull "$image"; then
        rm -f "$pull_log"
        return 0
      fi
    fi
  fi

  rm -f "$pull_log"
  red "sing-box 镜像不可用，已停止操作；配置文件不会继续写入。"
  yellow "可尝试手动执行：docker logout ghcr.io && docker pull $image"
  yellow "如果仍失败，可设置 SING_BOX_IMAGE=可用镜像 sb，再进入更新管理 -> 更新 sing-box 镜像"
  return 1
}

public_ip(){
  curl -4fsS https://api.ipify.org || curl -4fsS https://ifconfig.me || printf 'SERVER_IP'
}

port_used(){
  local port="$1" proto="$2" sockets
  case "$proto" in
    tcp) sockets=$(ss -H -lnt "sport = :$port") || return 2 ;;
    udp) sockets=$(ss -H -lnu "sport = :$port") || return 2 ;;
    *) return 2 ;;
  esac
  [ -z "$sockets" ] || return 0
  [ -f "$CONFIG_FILE" ] || return 1
  jq -e --argjson port "$port" --arg proto "$proto" '
    .inbounds[]? | select(.listen_port == $port) |
    (if (.type == "hysteria2" or .type == "hysteria" or .type == "tuic") then "udp"
     elif (.type == "vless" or .type == "anytls" or .type == "trojan") then "tcp"
     else (.network // "tcp,udp") end) |
    split(",") | index($proto) != null' "$CONFIG_FILE" >/dev/null
}

tag_exists(){
  local tag="$1"
  jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null
}

uri_escape(){
  jq -rn --arg value "$1" '$value | @uri'
}

cert_pin_sha256_hex(){
  local cert_file="$1"
  openssl x509 -in "$cert_file" -outform der \
    | openssl dgst -sha256 -hex \
    | awk '{print tolower($2)}'
}

cert_is_self_signed(){
  local cert_file="$1"
  local subject issuer
  subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/^subject=//')
  issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  [ -n "$subject" ] && [ "$subject" = "$issuer" ]
}

valid_domain(){
  local domain="$1" label
  [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *..* && "$domain" != *. ]] || return 1
  local labels
  IFS=. read -ra labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
}

valid_node_tag(){
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]]
}

validate_certificate(){
  local domain="$1" cert="$2" key="$3" cert_public key_public
  [ -r "$cert" ] && [ -r "$key" ] || { red "证书或私钥不可读"; return 1; }
  openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || {
    red "证书不匹配域名：$domain"; return 1;
  }
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
  # Trusting the leaf here checks its validity dates, not its public CA trust chain.
  openssl verify -verify_hostname "$domain" -partial_chain -trusted "$cert" "$cert" >/dev/null 2>&1 || return 1
  cert_public=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256) || return 1
  key_public=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER | openssl dgst -sha256) || return 1
  [ "$cert_public" = "$key_public" ] || { red "证书与私钥不匹配"; return 1; }
}

shared_domain_for_tag(){
  [ -f "$CONFIG_DIR/.shared-443" ] || return 1
  jq -er --arg tag "$1" '.domains | to_entries[] | select(.value.tag == $tag) | .key' "$CONFIG_DIR/.shared-443"
}

gateway_container(){
  local ids
  ids=$(docker ps -a -q --filter "label=com.docker.compose.project.working_dir=$WORK_DIR" \
    --filter label=com.docker.compose.service=singbox-gateway --filter label=io.singbox-docker.gateway=true) || return 1
  [ -n "$ids" ] || return 0
  docker inspect $ids | jq -r 'sort_by(.State.Running, .State.StartedAt) | last | .Id // empty'
}

gateway_running(){
  local id
  id=$(gateway_container) || return 1
  [ -n "$id" ] && [ "$(docker inspect --format '{{.State.Running}}' "$id")" = true ]
}

gateway_preflight(){
  local port existing renewal
  existing=$(compose config --format json | jq -r '.services["singbox-gateway"].labels["io.singbox-docker.gateway"] // empty') || return 1
  [ -z "$existing" ] || [ "$existing" = true ] || return 1
  if compose config --format json | jq -e '.services | has("singbox-gateway")' >/dev/null; then
    [ "$existing" = true ] || { red "singbox-gateway 服务名称已被其他配置占用"; return 1; }
  fi
  if ! gateway_running; then
    for renewal in /etc/letsencrypt/renewal/*.conf; do
      if [ -f "$renewal" ] && grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' "$renewal"; then
        red "发现依赖独占 80/TCP 的已有证书续期：$renewal"
        yellow "请先将该证书改为 DNS 或持续可用的网站目录验证，再启用共享入口，避免破坏旧证书续期。"
        return 1
      fi
    done
    for port in 80 443; do
      if port_used "$port" tcp; then
        red "$port/TCP 已被占用，不能自动启用共享入口；不会停止或修改现有网站。"
        yellow "已有网站需先安排迁移到本机其他 HTTP 端口，再接入网站管理。"
        return 1
      fi
    done
  fi
}

allocate_private_port(){
  local port attempt
  for ((attempt=0; attempt<100; attempt++)); do
    port=$((20000 + RANDOM % 20000))
    if port_used "$port" tcp || port_used "$port" udp; then continue; fi
    if [ -f "$CONFIG_DIR/.shared-443" ] && jq -e --argjson p "$port" \
      '.tls_port == $p or any(.domains[]; .backend_port == $p)' "$CONFIG_DIR/.shared-443" >/dev/null; then continue; fi
    printf '%s' "$port"
    return 0
  done
  red "未找到空闲内部端口" >&2
  return 1
}

gateway_initialize(){
  local state="$CONFIG_DIR/.shared-443" tls_port flags
  gateway_preflight || return 1
  if [ -f "$state" ]; then
    if ! gateway_running; then gateway_apply || return 1; fi
    return 0
  fi
  docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1 || docker pull "$NGINX_IMAGE" || return 1
  flags=$(docker run --rm --entrypoint nginx "$NGINX_IMAGE" -V 2>&1) || return 1
  [[ "$flags" == *--with-stream_ssl_preread_module* ]] || { red "Nginx 镜像不支持 SNI 分流"; return 1; }
  tls_port=$(allocate_private_port) || return 1
  mkdir -p "$CONFIG_DIR/gateway/acme" "$CONFIG_DIR/gateway/certs"
  chmod 755 "$CONFIG_DIR/gateway" "$CONFIG_DIR/gateway/acme"
  jq -n --arg image "$NGINX_IMAGE" --argjson tls_port "$tls_port" \
    --argjson dynamic "$(if [[ "$flags" == *--with-stream=dynamic* ]]; then echo true; else echo false; fi)" \
    '{version:1,nginx_image:$image,tls_port:$tls_port,dynamic_stream:$dynamic,domains:{}}' > "$state"
  # Bootstrap HTTP-01 before issuing certificates; renewals then keep using webroot, never standalone.
  gateway_apply
}

gateway_certificate(){
  local domain="$1" cert_dir="$CONFIG_DIR/gateway/certs/$1" choice email=""
  GW_SOURCE_CERT="/etc/letsencrypt/live/$domain/fullchain.pem"
  GW_SOURCE_KEY="/etc/letsencrypt/live/$domain/privkey.pem"
  echo "证书来源：1. 自动申请 / 复用 Let's Encrypt（默认）  2. 导入已有证书"
  read -rp "请选择 [默认 1]: " choice
  case "${choice:-1}" in
      1)
        install_certbot || return 1
        open_port 80 tcp
        if validate_certificate "$domain" "$GW_SOURCE_CERT" "$GW_SOURCE_KEY" >/dev/null 2>&1; then
          certbot reconfigure --cert-name "$domain" --webroot -w "$CONFIG_DIR/gateway/acme" --non-interactive || return 1
        else
        local args=(certonly --non-interactive --agree-tos --preferred-challenges http --cert-name "$domain" -d "$domain")
        read -rp "Let's Encrypt 邮箱 [可留空]: " email
        if [ -n "$email" ]; then args+=(-m "$email"); else args+=(--register-unsafely-without-email); fi
        args+=(--webroot -w "$CONFIG_DIR/gateway/acme")
        yellow "请确认域名已直接解析到本机，且云安全组和系统防火墙允许 80/TCP"
        certbot "${args[@]}" || return 1
        fi
        ;;
      2)
        read -rp "宿主机证书完整链绝对路径: " GW_SOURCE_CERT
        read -rp "宿主机私钥绝对路径: " GW_SOURCE_KEY
        [[ "$GW_SOURCE_CERT" = /* && "$GW_SOURCE_KEY" = /* ]] || { red "请使用绝对路径"; return 1; }
        yellow "原证书管理器仍负责续期；若它使用 standalone 验证，请先改为 DNS 或网站目录验证。"
        ;;
      *) return 1 ;;
  esac
  validate_certificate "$domain" "$GW_SOURCE_CERT" "$GW_SOURCE_KEY" || return 1
  mkdir -p "$cert_dir"
  install -m 0600 "$GW_SOURCE_CERT" "$cert_dir/cert.pem" || return 1
  install -m 0600 "$GW_SOURCE_KEY" "$cert_dir/private.key" || return 1
  validate_certificate "$domain" "$cert_dir/cert.pem" "$cert_dir/private.key"
}

gateway_render(){
  local state="$CONFIG_DIR/.shared-443" output="$1" tls_port domain kind port upstream
  jq -e '.version == 1 and (.tls_port | type == "number") and (.domains | type == "object")' "$state" >/dev/null || return 1
  tls_port=$(jq -r '.tls_port' "$state")
  [[ "$tls_port" =~ ^[0-9]+$ ]] && [ "$tls_port" -ge 1024 ] && [ "$tls_port" -le 65535 ] || return 1
  {
    if [ "$(jq -r '.dynamic_stream' "$state")" = true ]; then echo 'load_module /usr/lib/nginx/modules/ngx_stream_module.so;'; fi
    printf 'worker_processes auto;\nerror_log /dev/stderr warn;\npid /tmp/nginx.pid;\nevents { worker_connections 2048; }\n'
    printf 'stream {\n log_format ingress "$remote_addr $ssl_preread_server_name $status $bytes_sent $bytes_received $session_time";\n access_log /dev/stdout ingress;\n map $ssl_preread_server_name $destination {\n default 127.0.0.1:%s;\n' "$tls_port"
    while IFS=$'\t' read -r domain kind port; do
      valid_domain "$domain" || return 1
      case "$kind" in
        vless|anytls)
          [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || return 1
          printf ' %s 127.0.0.1:%s;\n' "$domain" "$port" ;;
        hysteria2|website) : ;;
        *) return 1 ;;
      esac
    done < <(jq -r '.domains | to_entries | sort_by(.key)[] | [.key,.value.kind,(.value.backend_port // 0)] | @tsv' "$state")
    printf ' }\n server { listen 443; listen [::]:443; ssl_preread on; proxy_connect_timeout 5s; proxy_timeout 1h; proxy_pass $destination; }\n}\n'
    printf 'http {\n access_log off;\n server_tokens off;\n client_max_body_size 64m;\n map $http_upgrade $upgrade_connection { default upgrade; "" close; }\n'
    printf ' server { listen 80; listen [::]:80; server_name _; location /.well-known/acme-challenge/ { root /etc/sb-gateway/acme; } location / { return 404; } }\n'
    printf ' server { listen 127.0.0.1:%s ssl default_server; ssl_reject_handshake on; }\n' "$tls_port"
    while IFS=$'\t' read -r domain upstream; do
      valid_domain "$domain" || return 1
      printf ' server { listen 127.0.0.1:%s ssl; server_name %s;\n' "$tls_port" "$domain"
      printf ' ssl_certificate /etc/sb-gateway/certs/%s/cert.pem; ssl_certificate_key /etc/sb-gateway/certs/%s/private.key;\n' "$domain" "$domain"
      printf ' ssl_protocols TLSv1.2 TLSv1.3;\n'
      if [ -n "$upstream" ]; then
        valid_website_upstream "$upstream" || return 1
        printf ' location / { proxy_pass %s; proxy_http_version 1.1; proxy_buffering off; proxy_read_timeout 300s; proxy_send_timeout 300s; proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $upgrade_connection; }\n' "$upstream"
      else
        printf ' location / { return 404; }\n'
      fi
      printf ' }\n'
    done < <(jq -r '.domains | to_entries | sort_by(.key)[] | [.key,(.value.website_upstream // "")] | @tsv' "$state")
    printf '}\n'
  } > "$output"
}

valid_website_upstream(){
  local port
  [[ "$1" =~ ^http://(127\.0\.0\.1|\[::1\]):([0-9]{1,5})/?$ ]] || return 1
  port="${BASH_REMATCH[2]}"
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && [ "$port" -ne 80 ] && [ "$port" -ne 443 ]
}

gateway_apply(){
  local state="$CONFIG_DIR/.shared-443" image tmp id
  [ -f "$state" ] || return 0
  image=$(jq -er '.nginx_image' "$state") || return 1
  tmp=$(mktemp "$CONFIG_DIR/gateway/.nginx.XXXXXX") || return 1
  gateway_render "$tmp" || { rm -f "$tmp"; return 1; }
  docker run --rm --entrypoint nginx -v "$CONFIG_DIR/gateway:/etc/sb-gateway:ro" \
    "$image" -t -c "/etc/sb-gateway/${tmp##*/}" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$CONFIG_DIR/gateway/nginx.conf" || return 1
  if gateway_running; then
    docker exec "$(gateway_container)" nginx -s reload -c /etc/sb-gateway/nginx.conf || return 1
  else
    gateway_preflight || return 1
    tmp=$(mktemp "$WORK_DIR/.gateway-compose.XXXXXX") || return 1
    if ! compose config --no-interpolate --no-env-resolution --no-path-resolution --format json | jq \
      --arg image "$image" --arg source "$CONFIG_DIR/gateway" '
      .services["singbox-gateway"] = {image:$image,restart:"unless-stopped",network_mode:"host",
        labels:{"io.singbox-docker.gateway":"true"},entrypoint:["nginx"],
        command:["-c","/etc/sb-gateway/nginx.conf","-g","daemon off;"],
        volumes:[{type:"bind",source:$source,target:"/etc/sb-gateway",read_only:true}],
        logging:{driver:"json-file",options:{"max-size":"10m","max-file":"3"}}}' > "$tmp"; then
      rm -f "$tmp"; return 1
    fi
    docker compose --project-directory "$WORK_DIR" -f "$tmp" config -q || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$COMPOSE_FILE" || return 1
    if [ "${1:-}" = restore ]; then
      compose up -d --no-deps --force-recreate singbox-gateway || return 1
    else
      compose up -d --no-deps singbox-gateway || return 1
    fi
    id=$(gateway_container) || return 1
    [ -n "$id" ] && wait_service "$id" || return 1
  fi
}

restore_gateway_service(){
  local id
  id=$(gateway_container) || return 1
  [ -z "$id" ] || docker stop "$id" >/dev/null || return 1
  if [ -f "$CONFIG_DIR/.shared-443" ]; then
    gateway_apply restore || return 1
    install_gateway_renewal || return 1
  fi
}

shared_transaction() (
  local snapshot completed=0 old_id old_image="" gateway_id gateway_was_running=0 core_was_running=0
  snapshot=$(mktemp -d "$WORK_DIR/.shared-operation.XXXXXX") || return 1
  cp -a "$CONFIG_DIR" "$snapshot/config" || return 1
  cp -p "$COMPOSE_FILE" "$snapshot/compose" || return 1
  [ ! -f "$INFO_FILE" ] || cp -p "$INFO_FILE" "$snapshot/info" || return 1
  old_id=$(service_container) || return 1
  if [ -n "$old_id" ]; then
    old_image=$(docker inspect --format '{{.Image}}' "$old_id") || return 1
    [ "$(docker inspect --format '{{.State.Running}}' "$old_id")" != true ] || core_was_running=1
  fi
  gateway_id=$(gateway_container) || return 1
  if gateway_running; then gateway_was_running=1; fi
  trap shared_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  "$@" || return 1
  completed=1
)

shared_cleanup(){
  local result=$? id recovered=1 core_changed=0 gateway_changed=0
  trap - EXIT HUP INT TERM
  if [ "$completed" -ne 1 ]; then
    cmp -s "$snapshot/config/config.json" "$CONFIG_FILE" || core_changed=1
    id=$(service_container) || recovered=0
    [ "$id" = "$old_id" ] || core_changed=1
    if [ -n "$id" ] && [ "$(docker inspect --format '{{.State.Running}}' "$id")" != "$(if [ "$core_was_running" -eq 1 ]; then echo true; else echo false; fi)" ]; then core_changed=1; fi
    if [ -f "$snapshot/config/gateway/nginx.conf" ] || [ -f "$CONFIG_DIR/gateway/nginx.conf" ]; then
      cmp -s "$snapshot/config/gateway/nginx.conf" "$CONFIG_DIR/gateway/nginx.conf" || gateway_changed=1
    fi
    id=$(gateway_container) || recovered=0
    [ "$id" = "$gateway_id" ] || gateway_changed=1
    # Keep the mounted config directory inode; replacing it would leave running containers on old files.
    cp -a "$snapshot/config/." "$CONFIG_DIR/" || recovered=0
    for id in .shared-443 gateway/nginx.conf; do
      if [ ! -f "$snapshot/config/$id" ]; then rm -f "$CONFIG_DIR/$id" || recovered=0; fi
    done
    cp -p "$snapshot/compose" "$COMPOSE_FILE" || recovered=0
    if [ -f "$snapshot/info" ]; then cp -p "$snapshot/info" "$INFO_FILE" || recovered=0; else rm -f "$INFO_FILE"; fi
    if [ "$core_changed" -eq 1 ] && [ -n "$old_image" ]; then
      recover_service "$old_id" "$old_image" || recovered=0
      if [ "$core_was_running" -eq 0 ]; then docker stop "$old_id" >/dev/null || recovered=0; fi
    elif [ "$core_changed" -eq 1 ]; then
      id=$(service_container) || recovered=0
      [ -z "$id" ] || docker rm -f "$id" >/dev/null || recovered=0
    fi
    if [ "$gateway_changed" -eq 1 ] && [ "$gateway_was_running" -eq 1 ]; then
      if gateway_running; then
        docker exec "$gateway_id" nginx -s reload -c /etc/sb-gateway/nginx.conf || recovered=0
      else
        docker start "$gateway_id" >/dev/null && wait_service "$gateway_id" || recovered=0
      fi
    elif [ "$gateway_changed" -eq 1 ]; then
      id=$(gateway_container) || recovered=0
      if [ -n "$id" ] && [ "$id" != "$gateway_id" ]; then docker rm -f "$id" >/dev/null || recovered=0; fi
      if [ -n "$id" ] && [ "$id" = "$gateway_id" ]; then docker stop "$id" >/dev/null || recovered=0; fi
    fi
    [ "$result" -ne 0 ] || result=1
    if [ "$recovered" -ne 1 ]; then red "自动恢复未完成，备份保留：$snapshot"; exit 1; fi
    red "共享入口操作失败，已恢复原配置和服务"
  fi
  rm -rf "$snapshot"
  exit "$result"
}

shared_add_node(){
  local kind="$1" domain="$2" state="$CONFIG_DIR/.shared-443" backend tag password="" uuid="" short_id="" key_output private_key="" public_key="" tls_port inbound tmp uri password_uri existing_kind
  valid_domain "$domain" || { red "域名格式无效，请填写小写完整域名，不含协议和端口"; return 1; }
  gateway_initialize || return 1
  existing_kind=$(jq -r --arg d "$domain" '.domains[$d].kind // empty' "$state") || return 1
  if [ -n "$existing_kind" ] && { [ "$kind" != hysteria2 ] || [ "$existing_kind" != website ]; }; then
    red "该域名已被共享入口使用；TCP 节点请使用另一个子域名"; return 1
  fi
  if [ "$kind" = hysteria2 ] && port_used 443 udp; then
    red "443/UDP 已被占用；请复用现有 Hy2 入站，或留空域名使用其他 UDP 端口。"; return 1
  fi
  if [ "$kind" = hysteria2 ]; then backend=443; else backend=$(allocate_private_port) || return 1; fi
  tag="$kind-$backend"
  read -rp "节点标签 [默认 $tag]: " tmp
  tag=${tmp:-$tag}
  valid_node_tag "$tag" && ! tag_exists "$tag" || { red "标签已存在或格式无效（仅字母、数字、点、横线和下划线，最多64字符）"; return 1; }
  ensure_singbox_image || return 1
  if [ "$existing_kind" = website ]; then
    GW_SOURCE_CERT=$(jq -er --arg d "$domain" '.domains[$d].source_cert' "$state") || return 1
    GW_SOURCE_KEY=$(jq -er --arg d "$domain" '.domains[$d].source_key' "$state") || return 1
    validate_certificate "$domain" "$CONFIG_DIR/gateway/certs/$domain/cert.pem" "$CONFIG_DIR/gateway/certs/$domain/private.key" || return 1
  else
    gateway_certificate "$domain" || return 1
  fi
  tls_port=$(jq -r '.tls_port' "$state")
  if [ "$kind" = vless ]; then
    uuid=$(uuidgen); short_id=$(openssl rand -hex 8)
    key_output=$(docker run --rm "$(runtime_image)" generate reality-keypair) || return 1
    private_key=$(printf '%s\n' "$key_output" | awk '/PrivateKey/ {print $2}')
    public_key=$(printf '%s\n' "$key_output" | awk '/PublicKey/ {print $2}')
    [ -n "$private_key" ] && [ -n "$public_key" ] || return 1
  else
    read -rp "密码 [留空自动生成]: " password
    password=${password:-$(openssl rand -hex 16)}
  fi
  inbound=$(jq -n --arg type "$kind" --arg tag "$tag" --arg domain "$domain" --arg password "$password" \
    --arg uuid "$uuid" --arg private_key "$private_key" --arg sid "$short_id" --argjson port "$backend" --argjson tls_port "$tls_port" '
    {type:$type,tag:$tag,listen:(if $type == "hysteria2" then "::" else "127.0.0.1" end),listen_port:$port,
      users:[(if $type == "vless" then {uuid:$uuid,flow:"xtls-rprx-vision"} else {name:$tag,password:$password} end)],
      tls:({enabled:true,server_name:$domain} +
        if $type == "vless" then {reality:{enabled:true,handshake:{server:"127.0.0.1",server_port:$tls_port},private_key:$private_key,short_id:[$sid]}}
        else {certificate_path:("/etc/sing-box/gateway/certs/"+$domain+"/cert.pem"),key_path:("/etc/sing-box/gateway/certs/"+$domain+"/private.key")} end)}') || return 1
  tmp=$(mktemp "$CONFIG_DIR/.gateway-state.XXXXXX") || return 1
  jq --arg domain "$domain" --arg kind "$kind" --arg tag "$tag" --arg cert "$GW_SOURCE_CERT" --arg key "$GW_SOURCE_KEY" --argjson port "$backend" \
    '.domains[$domain]=((.domains[$domain] // {}) + {kind:$kind,tag:$tag,backend_port:$port,source_cert:$cert,source_key:$key})' "$state" > "$tmp" || return 1
  mv "$tmp" "$state" || return 1
  add_inbound "$inbound" || return 1
  gateway_apply || return 1
  if [ "$kind" = vless ]; then
    uri="vless://$uuid@$domain:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#$(uri_escape "$tag")"
  else
    password_uri=$(uri_escape "$password")
    uri="$kind://$password_uri@$domain:443?sni=$domain#$(uri_escape "$tag")"
  fi
  {
    printf '\n==============================\n类型：%s\n标签：%s\n地址：%s\n端口：443\n内部端口：%s\nSNI：%s\n' \
      "$kind" "$tag" "$domain" "$backend" "$domain"
    if [ "$kind" = vless ]; then
      printf 'UUID：%s\nFlow：xtls-rprx-vision\nPublicKey：%s\nShortID：%s\n' "$uuid" "$public_key" "$short_id"
    else
      printf '密码：%s\n' "$password"
    fi
    printf '链接：\n%s\n==============================\n' "$uri"
  } >> "$INFO_FILE"
  install_gateway_renewal || return 1
  open_port 80 tcp
  open_port 443 tcp
  [ "$kind" != hysteria2 ] || open_port 443 udp
  green "共享 443 入站已添加；内部端口仅监听本机，不需要对公网放行"
  print_created_node "$tag"
}

shared_add_website(){
  prepare_runtime || return 1
  local domain upstream state="$CONFIG_DIR/.shared-443" tmp kind
  read -rp "网站域名（已解析到本机）: " domain
  valid_domain "$domain" || { red "域名格式无效"; return 1; }
  read -rp "网站本机 HTTP 地址，例如 http://127.0.0.1:8080: " upstream
  valid_website_upstream "$upstream" || { red "仅支持本机 HTTP 地址，不能使用 80 或 443，避免入口循环"; return 1; }
  gateway_initialize || return 1
  kind=$(jq -r --arg d "$domain" '.domains[$d].kind // empty' "$state")
  case "$kind" in
    vless|anytls) red "TCP 节点与网站请使用不同子域名，以便网站不依赖节点运行"; return 1 ;;
  esac
  if [ -z "$kind" ]; then gateway_certificate "$domain" || return 1; fi
  tmp=$(mktemp "$CONFIG_DIR/.gateway-state.XXXXXX") || return 1
  jq --arg d "$domain" --arg upstream "$upstream" --arg cert "${GW_SOURCE_CERT:-}" --arg key "${GW_SOURCE_KEY:-}" \
    '.domains[$d] = ((.domains[$d] // {kind:"website",source_cert:$cert,source_key:$key}) + {website_upstream:$upstream})' "$state" > "$tmp" || return 1
  mv "$tmp" "$state" || return 1
  gateway_apply || return 1
  install_gateway_renewal || return 1
  open_port 80 tcp; open_port 443 tcp
  green "网站已接入 HTTPS 443；原应用仍运行在原来的本机 HTTP 端口"
}

install_gateway_renewal(){
  local hook=/etc/letsencrypt/renewal-hooks/deploy/singbox-shared-443.sh
  mkdir -p "$(dirname "$hook")"
  {
    echo '#!/usr/bin/env bash'
    printf 'exec env WORK_DIR=%q SCRIPT_PATH=%q %q --sync-shared-certificates\n' "$WORK_DIR" "$SCRIPT_PATH" "$SCRIPT_PATH"
  } > "$hook"
  chmod 700 "$hook"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    # Polling also supports certificates renewed by Caddy/acme.sh instead of Certbot.
    printf '[Unit]\nDescription=Sync sing-box shared HTTPS certificates\n[Service]\nType=oneshot\nExecStart=%s\n' "$hook" > /etc/systemd/system/singbox-shared-certificates.service
    printf '[Unit]\nDescription=Check shared HTTPS certificates\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/singbox-shared-certificates.timer
    systemctl daemon-reload || return 1
    systemctl enable --now singbox-shared-certificates.timer || return 1
    if command -v certbot >/dev/null 2>&1; then
      if systemctl cat certbot.timer >/dev/null 2>&1; then
        systemctl enable --now certbot.timer || return 1
      elif systemctl cat certbot-renew.timer >/dev/null 2>&1; then
        systemctl enable --now certbot-renew.timer || return 1
      else
        yellow "未发现 Certbot 续期定时器，请确认原系统已有 certbot renew 定时任务。"
      fi
    fi
  else
    yellow "此系统未运行 systemd，请在原证书管理器续期后执行：$SCRIPT_PATH --sync-shared-certificates"
  fi
}

sync_shared_certificates(){
  local state="$CONFIG_DIR/.shared-443" domain source_cert source_key destination staged changed=0
  [ -f "$state" ] || return 0
  while IFS= read -r domain; do
    valid_domain "$domain" || return 1
    source_cert=$(jq -er --arg d "$domain" '.domains[$d].source_cert' "$state") || return 1
    source_key=$(jq -er --arg d "$domain" '.domains[$d].source_key' "$state") || return 1
    destination="$CONFIG_DIR/gateway/certs/$domain"
    if ! validate_certificate "$domain" "$source_cert" "$source_key"; then
      red "续期证书尚不可用，未替换：$domain"; return 1
    fi
    if cmp -s "$source_cert" "$destination/cert.pem" && cmp -s "$source_key" "$destination/private.key"; then continue; fi
    staged=$(mktemp -d "$destination/.renew.XXXXXX") || return 1
    install -m 0600 "$source_cert" "$staged/cert.pem" && install -m 0600 "$source_key" "$staged/private.key" || return 1
    validate_certificate "$domain" "$staged/cert.pem" "$staged/private.key" || return 1
    mv "$staged/private.key" "$destination/private.key" && mv "$staged/cert.pem" "$destination/cert.pem" || return 1
    rmdir "$staged"
    changed=1
  done < <(jq -r '.domains | keys[]' "$state")
  if [ "$changed" -eq 1 ]; then
    check_config || return 1
    gateway_apply || return 1
    green "共享证书已同步，Nginx 已平滑重载；未重启网站应用或 sing-box"
  fi
}

shared_gateway_menu(){
  local choice domain state="$CONFIG_DIR/.shared-443"
  while true; do
    echo "======================================"
    echo " 共享 443 / 网站管理"
    echo "1. 接入 / 修改网站（本机 HTTP 服务）"
    echo "2. 查看共享域名与内部端口"
    echo "3. 删除网站接入"
    echo "4. 同步续期证书 / 修复续期任务"
    echo "0. 返回"
    read -rp "请选择: " choice
    case "$choice" in
      1) prepare_runtime && run_locked shared_transaction shared_add_website; pause ;;
      2) if [ -f "$state" ]; then jq '.domains | to_entries | map({domain:.key,type:.value.kind,public_port:443,internal_port:.value.backend_port,website:.value.website_upstream})' "$state"; else yellow "尚未启用共享入口"; fi; pause ;;
      3)
        read -rp "要移除网站接入的域名: " domain
        if [ -f "$state" ]; then run_locked shared_transaction shared_remove_website "$domain"; fi; pause ;;
      4) if [ -f "$state" ]; then run_locked shared_transaction sync_shared_certificates && install_gateway_renewal; fi; pause ;;
      0) break ;;
      *) red "无效选择" ;;
    esac
  done
}

shared_remove_website(){
  local domain="$1" state="$CONFIG_DIR/.shared-443" tmp
  valid_domain "$domain" && [ -f "$state" ] || return 1
  tmp=$(mktemp "$CONFIG_DIR/.gateway-state.XXXXXX") || return 1
  jq --arg d "$domain" 'if .domains[$d].kind == "website" then del(.domains[$d]) else del(.domains[$d].website_upstream) end' "$state" > "$tmp" || return 1
  mv "$tmp" "$state" || return 1
  gateway_apply
}

install_certbot(){
  if command -v certbot >/dev/null 2>&1; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y certbot
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y certbot
  elif command -v yum >/dev/null 2>&1; then
    yum install -y certbot
  else
    red "暂不支持当前系统包管理器自动安装 certbot"
    exit 1
  fi
}

issue_letsencrypt_cert(){
  local domain="$1"
  local email="$2"
  local tag="$3"
  local cert_dir="$4"
  local renew_hook="/etc/letsencrypt/renewal-hooks/deploy/singbox-docker-$tag.sh"
  valid_domain "$domain" && valid_node_tag "$tag" || { red "域名或标签格式无效"; return 1; }

  install_certbot

  yellow "即将通过 Let's Encrypt HTTP-01 申请证书，请确保："
  yellow "1. 域名 $domain 已解析到本服务器"
  yellow "2. 服务器 80/tcp 已放行；已有共享入口时自动使用其验证目录"
  yellow "3. 云服务器安全组已放行 80/tcp"

  local args=(certonly --non-interactive --agree-tos --preferred-challenges http --cert-name "$domain" -d "$domain")
  if gateway_running; then
    args+=(--webroot -w "$CONFIG_DIR/gateway/acme")
  elif port_used 80 tcp; then
    red "80 端口已被占用，certbot standalone 无法申请证书"
    return 1
  else
    args+=(--standalone)
  fi
  if [ -n "$email" ]; then
    args+=(-m "$email")
  else
    args+=(--register-unsafely-without-email)
  fi
  certbot "${args[@]}" || return 1

  mkdir -p "$cert_dir"
  cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$cert_dir/cert.pem"
  cp "/etc/letsencrypt/live/$domain/privkey.pem" "$cert_dir/private.key"
  chmod 600 "$cert_dir/private.key"

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > "$renew_hook" <<EOFHOOK
#!/usr/bin/env bash
set -e
if [ "\$RENEWED_LINEAGE" = "/etc/letsencrypt/live/$domain" ]; then
  cp "\$RENEWED_LINEAGE/fullchain.pem" "$cert_dir/cert.pem"
  cp "\$RENEWED_LINEAGE/privkey.pem" "$cert_dir/private.key"
  chmod 600 "$cert_dir/private.key"
  cd "$WORK_DIR"
  docker compose --project-directory "$WORK_DIR" -f "$COMPOSE_FILE" restart sing-box
fi
EOFHOOK
  chmod +x "$renew_hook"
}

add_inbound(){
  local inbound_json="$1"
  local tmp
  tmp=$(mktemp "$CONFIG_DIR/.candidate.XXXXXX")
  if ! jq --argjson inbound "$inbound_json" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  apply_config "$tmp"
}

latest_info_block_by_tag(){
  local tag="$1"
  [ -f "$INFO_FILE" ] || return 1

  awk -v want="$tag" '
    BEGIN { RS="=============================="; block="" }
    {
      found=0
      n=split($0, lines, "\n")
      for (i=1; i<=n; i++) {
        if (lines[i] == "标签：" want) found=1
      }
      if (found) block=$0
    }
    END {
      if (block != "") {
        print "==============================" block "=============================="
      }
    }
  ' "$INFO_FILE"
}

remove_info_by_tag(){
  local tag="$1"
  local tmp
  [ -f "$INFO_FILE" ] || return 0

  tmp=$(mktemp)
  awk -v remove="$tag" '
    BEGIN { RS="=============================="; ORS="" }
    {
      found=0
      n=split($0, lines, "\n")
      for (i=1; i<=n; i++) {
        if (lines[i] == "标签：" remove) found=1
      }
      if (!found && $0 ~ /[^[:space:]]/) {
        print "==============================" $0 "=============================="
      }
    }
  ' "$INFO_FILE" > "$tmp"
  mv "$tmp" "$INFO_FILE"
}

print_created_node(){
  local block
  block=$(latest_info_block_by_tag "$1") || { red "节点信息读取失败，请通过配置查看菜单核对"; return 1; }
  echo
  yellow "本次节点配置（含连接凭据，请勿公开）："
  printf '%s\n' "$block"
}

check_config(){
  local file="${1:-$CONFIG_FILE}" directory="${2:-$CONFIG_DIR}" image
  image="${3:-$(runtime_image)}" || return 1
  [ -n "$image" ] || return 1
  ensure_singbox_image "$image" || return 1
  docker run --rm \
    -v "$directory:/etc/sing-box:ro" \
    -v "$file:/etc/sing-box/config.json:ro" \
    "$image" check -C /etc/sing-box
}

apply_config() (
  local candidate="$1" previous old_id old_image="" changed=0 started=0 committed=0
  if ! check_config "$candidate"; then
    rm -f "$candidate"
    red "候选配置检查失败，当前配置未变更"
    return 1
  fi
  previous=$(mktemp "$CONFIG_DIR/.previous.XXXXXX")
  cp -p "$CONFIG_FILE" "$previous" || return 1
  trap config_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  old_id=$(service_container) || return 1
  if [ -n "$old_id" ]; then
    old_image=$(docker inspect --format '{{.Image}}' "$old_id") || return 1
  fi
  chmod 600 "$candidate"
  changed=1
  mv "$candidate" "$CONFIG_FILE" || return 1
  started=1
  restart_service || return 1
  committed=1
)

config_cleanup(){
  local result=$?
  trap - EXIT HUP INT TERM
  if [ "$committed" -ne 1 ]; then
    if [ "$changed" -eq 1 ]; then
      mv "$previous" "$CONFIG_FILE" || { red "还原配置失败，备份保留在 $previous"; exit 1; }
      red "应用配置失败，已还原原配置"
    fi
    if [ "$started" -eq 1 ]; then
      recover_service "$old_id" "$old_image" || red "自动恢复失败，请检查服务日志"
    fi
    [ "$result" -ne 0 ] || result=1
  fi
  rm -f "$previous" "$candidate"
  exit "$result"
}

restart_service(){
  local id
  check_config || return 1
  id=$(service_container) || return 1
  if [ -n "$id" ]; then
    docker restart "$id" || return 1
  else
    compose up -d --no-deps --no-recreate sing-box || return 1
    id=$(service_container) || return 1
  fi
  [ -n "$id" ] && wait_service "$id" || return 1
  green "sing-box 已重启"
}

start_service(){
  local id
  check_config || return 1
  id=$(service_container) || return 1
  if [ -n "$id" ]; then
    docker start "$id" || return 1
  else
    compose up -d --no-deps --no-recreate sing-box || return 1
    id=$(service_container) || return 1
  fi
  [ -n "$id" ] && wait_service "$id" || return 1
  if [ -f "$CONFIG_DIR/.shared-443" ] && ! gateway_running; then gateway_apply || return 1; fi
  green "sing-box 已启动"
}

stop_service(){
  compose stop sing-box
  green "sing-box 已停止"
}

open_port(){
  local port="$1"
  local proto="$2"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$port/$proto" || true
  fi

  yellow "请确认云服务器安全组已放行：$port/$proto"
}

read_port(){
  local prompt="$1"
  local default="$2"
  local port
  read -rp "$prompt" port
  port="${port:-$default}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
    red "端口必须是 1-65535 的数字"
    return 1
  }
  printf '%s' "$port"
}

add_reality(){
  prepare_runtime || return
  local shared_domain
  read -rp "绑定节点域名（先解析到本机）[填写后共享443；留空独立端口]: " shared_domain
  if [ -n "$shared_domain" ]; then
    shared_transaction shared_add_node vless "$shared_domain"
    return $?
  fi
  ensure_singbox_image || return

  local port tag sni uuid short_id server_ip key_output private_key public_key inbound
  port=$(read_port "监听端口 [默认 443]: " 443) || return

  if port_used "$port" tcp; then
    red "端口 $port 可能已被占用，请换一个端口"
    return
  fi

  read -rp "节点标签 [默认 reality-$port]: " tag
  tag=${tag:-reality-$port}
  if tag_exists "$tag"; then
    red "标签 $tag 已存在，请换一个标签"
    return
  fi

  read -rp "伪装域名 SNI [默认 www.microsoft.com]: " sni
  sni=${sni:-www.microsoft.com}

  uuid=$(uuidgen)
  short_id=$(openssl rand -hex 8)
  server_ip=$(public_ip)

  key_output=$(docker run --rm "$(runtime_image)" generate reality-keypair)
  private_key=$(printf '%s\n' "$key_output" | awk '/PrivateKey/ {print $2}')
  public_key=$(printf '%s\n' "$key_output" | awk '/PublicKey/ {print $2}')

  inbound=$(cat <<JSON
{
  "type": "vless",
  "tag": "$tag",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "$sni",
        "server_port": 443
      },
      "private_key": "$private_key",
      "short_id": [
        "$short_id"
      ]
    }
  }
}
JSON
)

  add_inbound "$inbound" || return 1

  cat >> "$INFO_FILE" <<EOFINFO

==============================
类型：VLESS Reality
标签：$tag
地址：$server_ip
端口：$port
UUID：$uuid
Flow：xtls-rprx-vision
SNI：$sni
PublicKey：$public_key
ShortID：$short_id
链接：
vless://$uuid@$server_ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#$tag
==============================
EOFINFO

  open_port "$port" tcp
  green "VLESS Reality 入站已添加"
  print_created_node "$tag"
}

add_hysteria2(){
  prepare_runtime || return
  local shared_domain
  read -rp "绑定节点域名（先解析到本机）[填写后共享443；留空独立端口]: " shared_domain
  if [ -n "$shared_domain" ]; then
    shared_transaction shared_add_node hysteria2 "$shared_domain"
    return $?
  fi

  local port tag password sni cert_dir server_ip inbound cert_pin_hex password_uri tag_uri cert_mode cert_note link_host email
  port=$(read_port "监听端口 [默认 8443]: " 8443) || return

  if port_used "$port" udp; then
    red "端口 $port 可能已被占用，请换一个端口"
    return
  fi

  read -rp "节点标签 [默认 hy2-$port]: " tag
  tag=${tag:-hy2-$port}
  if tag_exists "$tag"; then
    red "标签 $tag 已存在，请换一个标签"
    return
  fi

  ensure_singbox_image || return

  read -rp "密码 [留空自动生成]: " password
  password=${password:-$(openssl rand -hex 16)}

  cert_dir="$CONFIG_DIR/cert-$tag"
  mkdir -p "$cert_dir"

  echo "证书模式："
  echo "1. 自签证书（默认，客户端需 insecure 或 pinSHA256）"
  echo "2. Let's Encrypt 真实证书（推荐，需域名解析到本机并放行 80/tcp）"
  read -rp "请选择 [默认 1]: " cert_mode
  cert_mode=${cert_mode:-1}

  case "$cert_mode" in
    1)
      read -rp "SNI/证书域名 [默认 bing.com]: " sni
      sni=${sni:-bing.com}
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$cert_dir/private.key" \
        -out "$cert_dir/cert.pem" \
        -days 3650 \
        -subj "/CN=$sni" >/dev/null 2>&1
      cert_note="自签证书"
      link_host="$(public_ip)"
      ;;
    2)
      read -rp "证书域名，例如 hy2.example.com: " sni
      [ -n "$sni" ] || { red "证书域名不能为空"; return; }
      read -rp "Let's Encrypt 邮箱 [可留空]: " email
      issue_letsencrypt_cert "$sni" "$email" "$tag" "$cert_dir" || return
      cert_note="Let's Encrypt 真实证书"
      link_host="$sni"
      ;;
    *)
      red "证书模式只能选择 1 或 2"
      return
      ;;
  esac

  server_ip=$(public_ip)
  cert_pin_hex=$(cert_pin_sha256_hex "$cert_dir/cert.pem")
  password_uri=$(uri_escape "$password")
  tag_uri=$(uri_escape "$tag")

  inbound=$(cat <<JSON
{
  "type": "hysteria2",
  "tag": "$tag",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {
      "password": "$password"
    }
  ],
  "masquerade": "https://www.bing.com",
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "certificate_path": "/etc/sing-box/cert-$tag/cert.pem",
    "key_path": "/etc/sing-box/cert-$tag/private.key"
  }
}
JSON
)

  add_inbound "$inbound" || return 1

  cat >> "$INFO_FILE" <<EOFINFO

==============================
类型：Hysteria2
标签：$tag
地址：$server_ip
端口：$port
密码：$password
SNI：$sni
证书：$cert_note
证书 Pin SHA256 Hex：$cert_pin_hex
旧客户端链接（insecure=1）：
hysteria2://$password_uri@$link_host:$port?insecure=1&sni=$sni#$tag_uri
新客户端链接（pinSHA256 hex，适合移除 allowInsecure 的客户端）：
hysteria2://$password_uri@$link_host:$port?sni=$sni&pinSHA256=$cert_pin_hex#$tag_uri
真实证书标准链接（Let's Encrypt 模式优先使用）：
hysteria2://$password_uri@$link_host:$port?sni=$sni#$tag_uri
Xray 手动配置字段：
pinnedPeerCertSha256: $cert_pin_hex
==============================
EOFINFO

  open_port "$port" udp
  green "Hysteria2 入站已添加"
  print_created_node "$tag"
}

add_anytls(){
  prepare_runtime || return
  local shared_domain
  read -rp "绑定节点域名（先解析到本机）[填写后共享443；留空独立端口]: " shared_domain
  if [ -n "$shared_domain" ]; then
    shared_transaction shared_add_node anytls "$shared_domain"
    return $?
  fi

  local port tag password sni cert_dir server_ip inbound cert_pin_hex password_uri tag_uri cert_mode cert_note link_host email
  port=$(read_port "监听端口 [默认 8444]: " 8444) || return

  if port_used "$port" tcp; then
    red "端口 $port 可能已被占用，请换一个端口"
    return
  fi

  read -rp "节点标签 [默认 anytls-$port]: " tag
  tag=${tag:-anytls-$port}
  if tag_exists "$tag"; then
    red "标签 $tag 已存在，请换一个标签"
    return
  fi

  ensure_singbox_image || return

  read -rp "密码 [留空自动生成]: " password
  password=${password:-$(openssl rand -base64 18)}

  cert_dir="$CONFIG_DIR/cert-$tag"
  mkdir -p "$cert_dir"

  echo "证书模式："
  echo "1. 自签证书（默认，客户端需 insecure 或 pinSHA256）"
  echo "2. Let's Encrypt 真实证书（推荐，需域名解析到本机并放行 80/tcp）"
  read -rp "请选择 [默认 1]: " cert_mode
  cert_mode=${cert_mode:-1}

  case "$cert_mode" in
    1)
      read -rp "SNI/证书域名 [默认 www.microsoft.com]: " sni
      sni=${sni:-www.microsoft.com}
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$cert_dir/private.key" \
        -out "$cert_dir/cert.pem" \
        -days 3650 \
        -subj "/CN=$sni" >/dev/null 2>&1
      cert_note="自签证书"
      link_host="$(public_ip)"
      ;;
    2)
      read -rp "证书域名，例如 anytls.example.com: " sni
      [ -n "$sni" ] || { red "证书域名不能为空"; return; }
      read -rp "Let's Encrypt 邮箱 [可留空]: " email
      issue_letsencrypt_cert "$sni" "$email" "$tag" "$cert_dir" || return
      cert_note="Let's Encrypt 真实证书"
      link_host="$sni"
      ;;
    *)
      red "证书模式只能选择 1 或 2"
      return
      ;;
  esac

  server_ip=$(public_ip)
  cert_pin_hex=$(cert_pin_sha256_hex "$cert_dir/cert.pem")
  password_uri=$(uri_escape "$password")
  tag_uri=$(uri_escape "$tag")

  inbound=$(cat <<JSON
{
  "type": "anytls",
  "tag": "$tag",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {
      "name": "$tag",
      "password": "$password"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "certificate_path": "/etc/sing-box/cert-$tag/cert.pem",
    "key_path": "/etc/sing-box/cert-$tag/private.key"
  }
}
JSON
)

  add_inbound "$inbound" || return 1

  cat >> "$INFO_FILE" <<EOFINFO

==============================
类型：AnyTLS
标签：$tag
地址：$server_ip
推荐地址：$link_host
端口：$port
密码：$password
SNI：$sni
证书：$cert_note
证书 Pin SHA256 Hex：$cert_pin_hex
AnyTLS URI（客户端支持时可尝试）：
anytls://$password_uri@$link_host:$port?sni=$sni#$tag_uri
sing-box 客户端出站配置：
{
  "type": "anytls",
  "tag": "$tag",
  "server": "$link_host",
  "server_port": $port,
  "password": "$password",
  "tls": {
    "enabled": true,
    "server_name": "$sni"
  }
}
自签证书客户端提示：
如使用自签证书，客户端需要开启 insecure 或填写证书 pin：$cert_pin_hex
==============================
EOFINFO

  open_port "$port" tcp
  green "AnyTLS 入站已添加"
  print_created_node "$tag"
}

add_door(){
  prepare_runtime || return

  local port tag target target_port network inbound
  port=$(read_port "本地监听端口，例如 2080: " "") || return

  read -rp "节点标签 [默认 door-$port]: " tag
  tag=${tag:-door-$port}
  if tag_exists "$tag"; then
    red "标签 $tag 已存在，请换一个标签"
    return
  fi

  ensure_singbox_image || return

  read -rp "转发目标地址，例如 1.1.1.1 或 example.com: " target
  [ -n "$target" ] || { red "目标地址不能为空"; return; }

  target_port=$(read_port "转发目标端口，例如 443: " "") || return

  read -rp "网络类型 tcp/udp [默认 tcp]: " network
  network=${network:-tcp}
  case "$network" in
    tcp|udp) ;;
    *) red "网络类型只能是 tcp 或 udp"; return ;;
  esac
  if port_used "$port" "$network"; then
    red "端口 $port/$network 已被占用，请换一个端口"
    return 1
  fi

  inbound=$(cat <<JSON
{
  "type": "direct",
  "tag": "$tag",
  "listen": "::",
  "listen_port": $port,
  "network": "$network",
  "override_address": "$target",
  "override_port": $target_port
}
JSON
)

  add_inbound "$inbound" || return 1

  cat >> "$INFO_FILE" <<EOFINFO

==============================
类型：Door 转发
标签：$tag
监听端口：$port
网络：$network
转发目标：$target:$target_port
说明：访问本机 $port 会被转发到 $target:$target_port
==============================
EOFINFO

  open_port "$port" "$network"
  green "Door 转发入站已添加"
  print_created_node "$tag"
}

delete_inbound(){
  prepare_runtime || return
  ensure_singbox_image || return

  show_inbounds
  echo
  read -rp "请输入要删除的入站标签: " tag
  [ -n "$tag" ] || { red "标签不能为空"; return; }

  if ! tag_exists "$tag"; then
    red "标签 $tag 不存在"
    return
  fi

  backup_config || return 1
  if shared_domain_for_tag "$tag" >/dev/null; then
    shared_transaction shared_delete_node "$tag"
    return $?
  fi
  local tmp
  tmp=$(mktemp "$CONFIG_DIR/.candidate.XXXXXX")
  if ! jq --arg tag "$tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  apply_config "$tmp" || return 1
  remove_info_by_tag "$tag"
  green "入站 $tag 已删除"
}

shared_delete_node(){
  local tag="$1" state="$CONFIG_DIR/.shared-443" tmp
  tmp=$(mktemp "$CONFIG_DIR/.candidate.XXXXXX") || return 1
  jq --arg tag "$tag" '.inbounds |= map(select(.tag != $tag))' "$CONFIG_FILE" > "$tmp" || return 1
  apply_config "$tmp" || return 1
  tmp=$(mktemp "$CONFIG_DIR/.gateway-state.XXXXXX") || return 1
  jq --arg tag "$tag" '.domains |= with_entries(
    if .value.tag == $tag then
      if .value.website_upstream then .value |= (del(.tag,.backend_port) | .kind = "website") else empty end
    else . end)' "$state" > "$tmp" || return 1
  mv "$tmp" "$state" || return 1
  gateway_apply || return 1
  remove_info_by_tag "$tag"
  green "入站及共享分流规则已删除；同域名的网站接入会保留"
}

show_info(){
  if [ ! -f "$CONFIG_FILE" ]; then
    red "未找到配置文件"
    return
  fi

  local count server_ip
  count=$(jq '.inbounds | length' "$CONFIG_FILE")
  if [ "$count" -eq 0 ]; then
    yellow "当前没有入站节点"
    return
  fi

  server_ip=$(public_ip)
  jq -c '.inbounds[]?' "$CONFIG_FILE" | while IFS= read -r inbound; do
    local type tag port block address shared_domain
    type=$(printf '%s' "$inbound" | jq -r '.type')
    tag=$(printf '%s' "$inbound" | jq -r '.tag')
    port=$(printf '%s' "$inbound" | jq -r '.listen_port')
    address="$server_ip"
    if shared_domain=$(shared_domain_for_tag "$tag"); then address="$shared_domain"; port=443; fi

    case "$type" in
      vless)
        block=$(latest_info_block_by_tag "$tag" || true)
        if [ -n "$block" ]; then
          printf '%s\n' "$block"
        else
          echo
          echo "=============================="
          echo "类型：VLESS Reality"
          echo "标签：$tag"
          echo "地址：$address"
          echo "端口：$port"
          echo "UUID：$(printf '%s' "$inbound" | jq -r '.users[0].uuid // empty')"
          echo "Flow：$(printf '%s' "$inbound" | jq -r '.users[0].flow // empty')"
          echo "SNI：$(printf '%s' "$inbound" | jq -r '.tls.server_name // empty')"
          echo "提示：缺少历史节点记录，无法从 config.json 反推出 Reality PublicKey。"
          echo "=============================="
        fi
        ;;
      hysteria2|anytls)
        block=$(latest_info_block_by_tag "$tag" || true)
        if [ -n "$block" ]; then
          printf '%s\n' "$block"
        else
          echo
          echo "=============================="
          echo "类型：$type"
          echo "标签：$tag"
          echo "地址：$address"
          echo "端口：$port"
          echo "密码：$(printf '%s' "$inbound" | jq -r '.users[0].password // empty')"
          echo "SNI：$(printf '%s' "$inbound" | jq -r '.tls.server_name // empty')"
          echo "提示：缺少历史节点记录，可使用协议专用菜单重新生成链接。"
          echo "=============================="
        fi
        ;;
      direct)
        echo
        echo "=============================="
        echo "类型：Door 转发"
        echo "标签：$tag"
        echo "监听端口：$port"
        echo "网络：$(printf '%s' "$inbound" | jq -r '.network // empty')"
        echo "转发目标：$(printf '%s' "$inbound" | jq -r '.override_address // empty'):$(printf '%s' "$inbound" | jq -r '.override_port // empty')"
        echo "=============================="
        ;;
      *)
        echo
        echo "=============================="
        echo "类型：$type"
        echo "标签：$tag"
        echo "端口：$port"
        echo "提示：未知入站类型，仅显示基础信息。"
        echo "=============================="
        ;;
    esac
  done
}

show_config(){
  [ -f "$CONFIG_FILE" ] && jq . "$CONFIG_FILE" || red "未找到配置文件"
}

show_inbounds(){
  if [ -f "$CONFIG_FILE" ]; then
    if [ -f "$CONFIG_DIR/.shared-443" ]; then
      jq --slurpfile gateway "$CONFIG_DIR/.shared-443" '.inbounds[]? | . as $i |
        ([$gateway[0].domains | to_entries[] | select(.value.tag == $i.tag) | .key][0]) as $domain |
        {tag,type,listen,listen_port,network,override_address,override_port} +
        (if $domain then {shared_domain:$domain,public_port:443} else {} end)' "$CONFIG_FILE"
    else
      jq '.inbounds[]? | {tag,type,listen,listen_port,network,override_address,override_port}' "$CONFIG_FILE"
    fi
  else
    red "未找到配置文件"
  fi
}

show_hysteria2_links(){
  if [ ! -f "$CONFIG_FILE" ]; then
    red "未找到配置文件"
    return
  fi

  local count server_ip
  count=$(jq '[.inbounds[]? | select(.type == "hysteria2")] | length' "$CONFIG_FILE")
  if [ "$count" -eq 0 ]; then
    yellow "暂无 Hysteria2 入站"
    return
  fi

  server_ip=$(public_ip)
  jq -c '.inbounds[]? | select(.type == "hysteria2")' "$CONFIG_FILE" | while IFS= read -r inbound; do
    local tag port password sni cert_path host_cert_path cert_pin_hex password_uri tag_uri
    tag=$(printf '%s' "$inbound" | jq -r '.tag')
    port=$(printf '%s' "$inbound" | jq -r '.listen_port')
    if shared_domain_for_tag "$tag" >/dev/null; then port=443; fi
    password=$(printf '%s' "$inbound" | jq -r '.users[0].password')
    sni=$(printf '%s' "$inbound" | jq -r '.tls.server_name // empty')
    cert_path=$(printf '%s' "$inbound" | jq -r '.tls.certificate_path // empty')

    if [ -z "$sni" ]; then
      sni="bing.com"
    fi

    case "$cert_path" in
      /etc/sing-box/*) host_cert_path="$CONFIG_DIR/${cert_path#/etc/sing-box/}" ;;
      *) host_cert_path="$cert_path" ;;
    esac

    echo
    echo "=============================="
    echo "类型：Hysteria2"
    echo "标签：$tag"
    echo "地址：$server_ip"
    echo "端口：$port"
    echo "密码：$password"
    echo "SNI：$sni"

    if [ -f "$host_cert_path" ]; then
      cert_pin_hex=$(cert_pin_sha256_hex "$host_cert_path")
      password_uri=$(uri_escape "$password")
      tag_uri=$(uri_escape "$tag")

      echo "证书 Pin SHA256 Hex：$cert_pin_hex"

      if cert_is_self_signed "$host_cert_path"; then
        echo "证书类型：自签证书"
        echo "旧客户端链接（insecure=1）："
        echo "hysteria2://$password_uri@$server_ip:$port?insecure=1&sni=$sni#$tag_uri"
        echo "新客户端链接（pinSHA256 hex，适合移除 allowInsecure 的客户端）："
        echo "hysteria2://$password_uri@$server_ip:$port?sni=$sni&pinSHA256=$cert_pin_hex#$tag_uri"
        echo "Xray 手动配置字段："
        echo "pinnedPeerCertSha256: $cert_pin_hex"
      else
        echo "证书类型：真实证书"
        echo "标准链接（推荐）："
        echo "hysteria2://$password_uri@$sni:$port?sni=$sni#$tag_uri"
        echo "兼容 pinSHA256 链接："
        echo "hysteria2://$password_uri@$sni:$port?sni=$sni&pinSHA256=$cert_pin_hex#$tag_uri"
      fi
    else
      red "证书文件不存在，无法生成 pin：$host_cert_path"
    fi

    echo "=============================="
  done
}

show_anytls_links(){
  if [ ! -f "$CONFIG_FILE" ]; then
    red "未找到配置文件"
    return
  fi

  local count server_ip
  count=$(jq '[.inbounds[]? | select(.type == "anytls")] | length' "$CONFIG_FILE")
  if [ "$count" -eq 0 ]; then
    yellow "暂无 AnyTLS 入站"
    return
  fi

  server_ip=$(public_ip)
  jq -c '.inbounds[]? | select(.type == "anytls")' "$CONFIG_FILE" | while IFS= read -r inbound; do
    local tag port password sni cert_path host_cert_path cert_pin_hex password_uri tag_uri link_host
    tag=$(printf '%s' "$inbound" | jq -r '.tag')
    port=$(printf '%s' "$inbound" | jq -r '.listen_port')
    if shared_domain_for_tag "$tag" >/dev/null; then port=443; fi
    password=$(printf '%s' "$inbound" | jq -r '.users[0].password')
    sni=$(printf '%s' "$inbound" | jq -r '.tls.server_name // empty')
    cert_path=$(printf '%s' "$inbound" | jq -r '.tls.certificate_path // empty')

    [ -n "$sni" ] || sni="www.microsoft.com"
    case "$cert_path" in
      /etc/sing-box/*) host_cert_path="$CONFIG_DIR/${cert_path#/etc/sing-box/}" ;;
      *) host_cert_path="$cert_path" ;;
    esac

    if [ -f "$host_cert_path" ] && ! cert_is_self_signed "$host_cert_path"; then
      link_host="$sni"
    else
      link_host="$server_ip"
    fi

    password_uri=$(uri_escape "$password")
    tag_uri=$(uri_escape "$tag")

    echo
    echo "=============================="
    echo "类型：AnyTLS"
    echo "标签：$tag"
    echo "地址：$server_ip"
    echo "推荐地址：$link_host"
    echo "端口：$port"
    echo "密码：$password"
    echo "SNI：$sni"
    echo "AnyTLS URI（客户端支持时可尝试）："
    echo "anytls://$password_uri@$link_host:$port?sni=$sni#$tag_uri"

    if [ -f "$host_cert_path" ]; then
      cert_pin_hex=$(cert_pin_sha256_hex "$host_cert_path")
      if cert_is_self_signed "$host_cert_path"; then
        echo "证书类型：自签证书"
        echo "证书 Pin SHA256 Hex：$cert_pin_hex"
        echo "自签证书客户端提示：开启 insecure 或填写证书 pin。"
      else
        echo "证书类型：真实证书"
      fi
    fi

    echo "sing-box 客户端出站配置："
    cat <<EOFANYTLS
{
  "type": "anytls",
  "tag": "$tag",
  "server": "$link_host",
  "server_port": $port,
  "password": "$password",
  "tls": {
    "enabled": true,
    "server_name": "$sni"
  }
}
EOFANYTLS
    echo "=============================="
  done
}

add_config_menu(){
  while true; do
    clear
    echo "======================================"
    echo " 添加配置"
    echo "======================================"
    echo "1. 添加 VLESS Reality 入站"
    echo "2. 添加 Hysteria2 入站"
    echo "3. 添加 AnyTLS 入站"
    echo "4. 添加 Door 转发入站"
    echo "5. 共享 443 / 网站管理"
    echo "0. 返回主菜单"
    echo "======================================"
    read -rp "请选择: " a

    case "$a" in
      1) run_locked add_reality; pause ;;
      2) run_locked add_hysteria2; pause ;;
      3) run_locked add_anytls; pause ;;
      4) run_locked add_door; pause ;;
      5) shared_gateway_menu ;;
      0) break ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

config_menu(){
  while true; do
    clear
    echo "======================================"
    echo " 配置查看 / 检查"
    echo "======================================"
    echo "1. 查看节点信息（仅当前存在的入站）"
    echo "2. 查看 Hysteria2 链接/证书 pin"
    echo "3. 查看 AnyTLS 链接/配置"
    echo "4. 查看所有入站摘要"
    echo "5. 查看完整 config.json"
    echo "6. 检查配置"
    echo "0. 返回主菜单"
    echo "======================================"
    read -rp "请选择: " c

    case "$c" in
      1) show_info; pause ;;
      2) show_hysteria2_links; pause ;;
      3) show_anytls_links; pause ;;
      4) show_inbounds; pause ;;
      5) show_config; pause ;;
      6) check_config; pause ;;
      0) break ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

logs(){
  compose logs -f --tail 100 sing-box
}

backup_config(){
  mkdir -p "$BACKUP_DIR"
  local backup_file tmp
  local files=(config docker-compose.yml)
  backup_file="$BACKUP_DIR/sing-box-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  [ ! -f "$INFO_FILE" ] || files+=(nodes.txt)
  tmp=$(mktemp "$BACKUP_DIR/.backup.XXXXXX")
  if ! tar -czf "$tmp" -C "$WORK_DIR" -- "${files[@]}" || ! tar -tzf "$tmp" >/dev/null; then
    rm -f "$tmp"
    red "配置备份失败，已停止后续操作"
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$backup_file"
  green "配置已备份：$backup_file"
}

begin_deployment(){
  transaction=$(mktemp -d "$WORK_DIR/.deployment.XXXXXX") || return 1
  committed=0 config_swapped=0 restore_info=0 deploy_started=0 old_id="" old_image=""
  trap deployment_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cp -p "$COMPOSE_FILE" "$transaction/compose.original" || return 1
  if [ -f "$INFO_FILE" ]; then
    cp -p "$INFO_FILE" "$transaction/info.original" || return 1
  fi
  old_id=$(service_container) || return 1
  if [ -n "$old_id" ]; then
    old_image=$(docker inspect --format '{{.Image}}' "$old_id") || return 1
  fi
}

deployment_cleanup(){
  local result=$? recovered=1
  trap - EXIT HUP INT TERM
  if [ "$committed" -ne 1 ]; then
    red "部署未完成，正在恢复变更前的配置"
    if [ "$config_swapped" -eq 1 ]; then
      if [ -d "$CONFIG_DIR" ]; then
        mv "$CONFIG_DIR" "$transaction/failed-config" || recovered=0
      fi
      if [ "$recovered" -eq 1 ]; then
        mv "$transaction/original-config" "$CONFIG_DIR" || recovered=0
      fi
    fi
    if [ -f "$transaction/compose.original" ]; then
      cp -p "$transaction/compose.original" "$COMPOSE_FILE" || recovered=0
    fi
    if [ "$restore_info" -eq 1 ]; then
      if [ -f "$transaction/info.original" ]; then
        cp -p "$transaction/info.original" "$INFO_FILE" || recovered=0
      else
        rm -f "$INFO_FILE" || recovered=0
      fi
    fi
    if [ "$deploy_started" -eq 1 ] && [ "$recovered" -eq 1 ]; then
      recover_service "$old_id" "$old_image" || recovered=0
      if [ -f "$CONFIG_DIR/.shared-443" ] || [ -f "$transaction/failed-config/.shared-443" ]; then
        restore_gateway_service || recovered=0
      fi
    fi
    [ "$result" -ne 0 ] || result=1
    if [ "$recovered" -ne 1 ]; then
      red "自动恢复未完成，现场文件保留在：$transaction"
      exit 1
    fi
  fi
  rm -rf "$transaction"
  exit "$result"
}

recreate_service(){
  local id expected actual
  expected=$(docker image inspect "$(compose_image)" --format '{{.Id}}') || return 1
  compose up -d --no-deps --force-recreate sing-box || return 1
  id=$(service_container) || return 1
  [ -n "$id" ] && wait_service "$id" || return 1
  actual=$(docker inspect --format '{{.Image}}' "$id") || return 1
  [ "$actual" = "$expected" ] || { red "运行镜像与目标镜像不一致"; return 1; }
}

restore_config() (
  mkdir -p "$BACKUP_DIR"

  echo "可用备份："
  ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null || {
    red "没有找到备份文件"
    return
  }

  local file c
  read -rp "请输入要恢复的备份完整路径: " file

  if [ ! -f "$file" ]; then
    red "备份文件不存在"
    return
  fi

  read -rp "恢复会覆盖当前配置，确认？输入 y: " c
  if [ "$c" = "y" ]; then
    prepare_runtime || return 1
    backup_config || return 1
    local transaction committed config_swapped restore_info deploy_started old_id old_image image
    begin_deployment || return 1
    mkdir "$transaction/staged" || return 1
    # Only restore the three paths written by backup_config; reject links and traversal.
    tar -tzf "$file" | awk '
      /^\// || /(^|\/)\.\.(\/|$)/ { exit 1 }
      !/^(config(\/|$)|nodes\.txt$|docker-compose\.yml$)/ { exit 1 }' || return 1
    tar -tvzf "$file" | awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" { exit 1 }' || return 1
    tar -xzf "$file" -C "$transaction/staged" --no-same-owner || return 1
    [ -f "$transaction/staged/config/config.json" ] || return 1
    image=$(compose_image "$transaction/staged/docker-compose.yml") || return 1
    check_config "$transaction/staged/config/config.json" "$transaction/staged/config" "$image" || return 1
    mv "$CONFIG_DIR" "$transaction/original-config" || return 1
    config_swapped=1
    mv "$transaction/staged/config" "$CONFIG_DIR" || return 1
    cp -p "$transaction/staged/docker-compose.yml" "$COMPOSE_FILE" || return 1
    restore_info=1
    if [ -f "$transaction/staged/nodes.txt" ]; then
      cp -p "$transaction/staged/nodes.txt" "$INFO_FILE" || return 1
    else
      rm -f "$INFO_FILE"
    fi
    deploy_started=1
    recreate_service || return 1
    if [ -f "$CONFIG_DIR/.shared-443" ] || [ -f "$transaction/original-config/.shared-443" ]; then
      restore_gateway_service || return 1
    fi
    committed=1
    green "配置已恢复并重启"
  else
    yellow "已取消"
  fi
)

show_version(){
  echo "目标镜像：$SING_BOX_IMAGE"
  echo
  echo "当前 sing-box 容器版本："
  local id
  id=$(service_container) || return 1
  if [ -n "$id" ]; then
    docker exec "$id" sing-box version || true
  else
    yellow "没有找到已启动过的 sing-box 服务容器"
  fi

  echo
  echo "当前本地镜像："
  docker images "$(compose_image)" || true

  echo
  echo "当前容器状态："
  compose ps -a sing-box
}

show_bbr_status(){
  echo "内核版本："
  uname -r || true

  echo
  echo "当前 TCP 拥塞控制："
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true

  echo
  echo "当前默认队列算法："
  sysctl net.core.default_qdisc 2>/dev/null || true

  echo
  echo "可用 TCP 拥塞控制算法："
  sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true

  echo
  if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qx bbr; then
    green "BBR 当前已启用"
  else
    yellow "BBR 当前未启用"
  fi
}

enable_bbr(){
  check_root

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || yellow "tcp_bbr 模块加载失败，可能已内建或当前内核不支持"
  else
    yellow "未找到 modprobe，跳过模块加载"
  fi

  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

  cat > /etc/sysctl.d/99-singbox-bbr.conf <<'EOFBBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOFBBR

  if sysctl --system; then
    show_bbr_status
  else
    red "应用 sysctl 配置失败，请检查当前系统内核是否支持 BBR"
    return 1
  fi

  if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qx bbr; then
    green "BBR 启用完成。Reality / TCP 转发会受益，Hysteria2 UDP 基本不受 BBR 影响。"
  else
    red "BBR 未成功启用，当前内核可能不支持 bbr"
    return 1
  fi
}

system_menu(){
  while true; do
    clear
    echo "======================================"
    echo " 系统优化"
    echo "======================================"
    echo "1. 查看 BBR 状态"
    echo "2. 启用 BBR"
    echo "3. 初始化/修复 sing-box Docker 环境"
    echo "0. 返回主菜单"
    echo "======================================"
    read -rp "请选择: " s

    case "$s" in
      1) show_bbr_status; pause ;;
      2) enable_bbr; pause ;;
      3) install_base; start_service; pause ;;
      0) break ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

update_singbox_image() (
  prepare_runtime || return 1

  yellow "更新前自动备份配置..."
  backup_config || return 1
  local transaction committed config_swapped restore_info deploy_started old_id old_image
  begin_deployment || return 1
  sync_compose_image || return 1

  yellow "拉取 sing-box 镜像：$SING_BOX_IMAGE"
  local pull_log
  pull_log=$(mktemp)
  if ! compose pull sing-box 2>&1 | tee "$pull_log"; then
    if grep -qi 'denied' "$pull_log" && printf '%s' "$SING_BOX_IMAGE" | grep -q '^ghcr\.io/'; then
      red "GHCR 返回 denied，常见原因是 Docker 保存了失效的 ghcr.io 登录凭据。"
      read -rp "是否执行 docker logout ghcr.io 后重试？输入 y: " retry_ghcr
      if [ "$retry_ghcr" = "y" ]; then
        docker logout ghcr.io || true
        compose pull sing-box || { rm -f "$pull_log"; return 1; }
      else
        rm -f "$pull_log"
        return 1
      fi
    else
      rm -f "$pull_log"
      return 1
    fi
  fi
  rm -f "$pull_log"

  yellow "使用目标镜像检查配置..."
  check_config "$CONFIG_FILE" "$CONFIG_DIR" "$(compose_image)" || return 1

  yellow "配置检查通过，正在重启..."
  deploy_started=1
  recreate_service || return 1
  committed=1
  green "sing-box 镜像已更新"
  docker exec "$(service_container)" sing-box version || true
)

update_script(){
  local tmp backup urls url ok old_sum new_sum
  tmp="$(mktemp)"
  backup="$SCRIPT_PATH.bak.$(date +%Y%m%d-%H%M%S)"
  ok=0

  urls="$SCRIPT_URL"
  if [ "$SCRIPT_URL" != "$FALLBACK_SCRIPT_URL" ]; then
    urls="$urls $FALLBACK_SCRIPT_URL"
  fi

  yellow "下载新脚本..."
  for url in $urls; do
    echo "尝试：$url"
    if [ "$url" = "$DEFAULT_SCRIPT_URL" ]; then
      if curl -fsSL -H "Accept: $SCRIPT_ACCEPT" -H "Cache-Control: no-cache" "$url" -o "$tmp"; then
        ok=1
        break
      fi
    else
      if curl -fsSL -H "Cache-Control: no-cache" "$url" -o "$tmp"; then
        ok=1
        break
      fi
    fi
  done

  if [ "$ok" -ne 1 ]; then
    rm -f "$tmp"
    red "下载新脚本失败，请检查服务器到 GitHub 的网络"
    return
  fi

  if ! grep -q 'sing-box Docker' "$tmp" || ! grep -q 'add_config_menu' "$tmp"; then
    rm -f "$tmp"
    red "下载内容不像 singbox-docker 脚本，已取消更新"
    return
  fi

  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    red "新脚本语法检查失败，已取消更新"
    return
  fi

  old_sum="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}' || true)"
  new_sum="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}' || true)"
  if [ -n "$old_sum" ] && [ "$old_sum" = "$new_sum" ]; then
    rm -f "$tmp"
    yellow "脚本已是最新，无需更新"
    return
  fi

  yellow "备份当前脚本：$backup"
  cp "$SCRIPT_PATH" "$backup"
  install -m 0755 "$tmp" "$SCRIPT_PATH"
  rm -f "$tmp"

  green "脚本自身已更新"
  yellow "当前正在运行的菜单不会自动变成新版本，请退出后重新执行：sb"
}

update_menu(){
  while true; do
    clear
    echo "======================================"
    echo " sing-box 更新管理"
    echo "======================================"
    echo "1. 更新 sing-box 镜像"
    echo "2. 查看 sing-box 当前版本"
    echo "3. 备份配置"
    echo "4. 恢复配置"
    echo "5. 更新脚本自身"
    echo "6. 安装/修复快捷命令 sb"
    echo "0. 返回主菜单"
    echo "======================================"
    read -rp "请选择: " u

    case "$u" in
      1) run_locked update_singbox_image; pause ;;
      2) show_version; pause ;;
      3) backup_config; pause ;;
      4) run_locked restore_config; pause ;;
      5) update_script; pause ;;
      6) install_shortcut; pause ;;
      0) break ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

uninstall(){
  echo "即将停止容器并删除目录：$WORK_DIR"
  if [ -f "$CONFIG_DIR/.shared-443" ]; then yellow "同时关闭脚本管理的 HTTPS 入口；不会删除网站应用的容器或数据。"; fi
  read -rp "确认卸载？输入 y 确认: " c
  if [ "$c" = "y" ]; then
    backup_config || true
    if [ -f "$COMPOSE_FILE" ]; then compose rm --stop --force sing-box || return 1; fi
    local gateway_id
    gateway_id=$(gateway_container) || return 1
    [ -z "$gateway_id" ] || docker rm -f "$gateway_id" || return 1
    rm -rf "$WORK_DIR"
    rm -f "$SCRIPT_PATH"
    if [ -f /etc/systemd/system/singbox-shared-certificates.timer ]; then
      systemctl disable --now singbox-shared-certificates.timer || true
      rm -f /etc/systemd/system/singbox-shared-certificates.timer /etc/systemd/system/singbox-shared-certificates.service
      systemctl daemon-reload || true
    fi
    rm -f /etc/letsencrypt/renewal-hooks/deploy/singbox-shared-443.sh
    green "已卸载，并删除快捷命令 sb"
  else
    yellow "已取消"
  fi
}

menu(){
  clear
  echo "======================================"
  echo " sing-box Docker 多入站管理脚本"
  echo " 脚本版本：$SCRIPT_VERSION"
  echo " 镜像：$SING_BOX_IMAGE"
  echo "======================================"
  echo "1. 添加配置"
  echo "2. 删除入站"
  echo "3. 配置查看 / 检查"
  echo "4. 启动 sing-box"
  echo "5. 重启 sing-box"
  echo "6. 停止 sing-box"
  echo "7. 查看日志"
  echo "8. 更新管理"
  echo "9. 系统优化"
  echo "10. 安装/修复快捷命令 sb"
  echo "11. 卸载"
  echo "0. 退出"
  echo "======================================"
  read -rp "请选择: " num

  case "$num" in
    1) add_config_menu ;;
    2) run_locked delete_inbound ;;
    3) config_menu ;;
    4) run_locked start_service ;;
    5) run_locked restart_service ;;
    6) run_locked stop_service ;;
    7) logs ;;
    8) update_menu ;;
    9) system_menu ;;
    10) install_shortcut ;;
    11) uninstall ;;
    0) exit 0 ;;
    *) red "无效选择" ;;
  esac

  pause
}

main(){
  check_root
  need_cmd bash
  if [ "${1:-}" = --sync-shared-certificates ]; then
    [ -f "$CONFIG_DIR/.shared-443" ] || return 0
    run_locked shared_transaction sync_shared_certificates
    return $?
  fi
  [ "$#" -eq 0 ] || { red "未知参数"; return 1; }
  while true; do
    menu
  done
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  main "$@"
fi
