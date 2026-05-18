#!/usr/bin/env bash
set -Eeuo pipefail

SING_BOX_VERSION="${SING_BOX_VERSION:-v1.13.12}"
SING_BOX_IMAGE="${SING_BOX_IMAGE:-ghcr.io/sagernet/sing-box:${SING_BOX_VERSION}}"
WORK_DIR="${WORK_DIR:-/opt/sing-box}"
CONFIG_DIR="$WORK_DIR/config"
DATA_DIR="$WORK_DIR/data"
CONFIG_FILE="$CONFIG_DIR/config.json"
INFO_FILE="$WORK_DIR/nodes.txt"
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
BACKUP_DIR="$WORK_DIR/backup"
SCRIPT_PATH="${SCRIPT_PATH:-/usr/local/bin/sb}"
SCRIPT_URL="${SCRIPT_URL:-}"

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
    apt-get install -y curl wget openssl jq uuid-runtime ca-certificates iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget openssl jq util-linux ca-certificates iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget openssl jq util-linux ca-certificates iproute
  else
    red "暂不支持当前系统包管理器，请手动安装 curl/wget/openssl/jq/uuidgen/iproute2"
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

install_base(){
  install_packages
  install_docker

  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_DIR"
  write_default_config
  write_compose_file
  install_shortcut
  green "基础环境初始化完成"
}

public_ip(){
  curl -4fsS https://api.ipify.org || curl -4fsS https://ifconfig.me || printf 'SERVER_IP'
}

port_used(){
  local port="$1"
  ss -lntup 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

tag_exists(){
  local tag="$1"
  jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null
}

add_inbound(){
  local inbound_json="$1"
  local tmp
  tmp=$(mktemp)
  jq --argjson inbound "$inbound_json" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

check_config(){
  mkdir -p "$CONFIG_DIR"
  docker run --rm \
    -v "$CONFIG_DIR:/etc/sing-box" \
    "$SING_BOX_IMAGE" \
    check -C /etc/sing-box
}

restart_service(){
  cd "$WORK_DIR"
  docker compose up -d --force-recreate
  green "sing-box 已重启"
}

start_service(){
  cd "$WORK_DIR"
  docker compose up -d
  green "sing-box 已启动"
}

stop_service(){
  cd "$WORK_DIR"
  docker compose down
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
  install_base

  local port tag sni uuid short_id server_ip key_output private_key public_key inbound
  port=$(read_port "监听端口 [默认 443]: " 443) || return

  if port_used "$port"; then
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

  key_output=$(docker run --rm "$SING_BOX_IMAGE" generate reality-keypair)
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

  add_inbound "$inbound"

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

  check_config
  restart_service
  open_port "$port" tcp
  green "VLESS Reality 入站已添加"
}

add_hysteria2(){
  install_base

  local port tag password sni cert_dir server_ip inbound
  port=$(read_port "监听端口 [默认 8443]: " 8443) || return

  if port_used "$port"; then
    red "端口 $port 可能已被占用，请换一个端口"
    return
  fi

  read -rp "节点标签 [默认 hy2-$port]: " tag
  tag=${tag:-hy2-$port}
  if tag_exists "$tag"; then
    red "标签 $tag 已存在，请换一个标签"
    return
  fi

  read -rp "密码 [留空自动生成]: " password
  password=${password:-$(openssl rand -hex 16)}

  read -rp "SNI/证书域名 [默认 bing.com]: " sni
  sni=${sni:-bing.com}

  cert_dir="$CONFIG_DIR/cert-$tag"
  mkdir -p "$cert_dir"

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$cert_dir/private.key" \
    -out "$cert_dir/cert.pem" \
    -days 3650 \
    -subj "/CN=$sni" >/dev/null 2>&1

  server_ip=$(public_ip)

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

  add_inbound "$inbound"

  cat >> "$INFO_FILE" <<EOFINFO

==============================
类型：Hysteria2
标签：$tag
地址：$server_ip
端口：$port
密码：$password
SNI：$sni
证书：自签证书，客户端需要开启 insecure / allowInsecure
链接：
hysteria2://$password@$server_ip:$port?insecure=1&sni=$sni#$tag
==============================
EOFINFO

  check_config
  restart_service
  open_port "$port" udp
  open_port "$port" tcp
  green "Hysteria2 入站已添加"
}

add_door(){
  install_base

  local port tag target target_port network inbound
  port=$(read_port "本地监听端口，例如 2080: " "") || return

  if port_used "$port"; then
    red "端口 $port 可能已被占用，请换一个端口"
    return
  fi

  read -rp "节点标签 [默认 door-$port]: " tag
  tag=${tag:-door-$port}
  if tag_exists "$tag"; then
    red "标签 $tag 已存在，请换一个标签"
    return
  fi

  read -rp "转发目标地址，例如 1.1.1.1 或 example.com: " target
  [ -n "$target" ] || { red "目标地址不能为空"; return; }

  target_port=$(read_port "转发目标端口，例如 443: " "") || return

  read -rp "网络类型 tcp/udp [默认 tcp]: " network
  network=${network:-tcp}
  case "$network" in
    tcp|udp) ;;
    *) red "网络类型只能是 tcp 或 udp"; return ;;
  esac

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

  add_inbound "$inbound"

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

  check_config
  restart_service
  open_port "$port" "$network"
  green "Door 转发入站已添加"
}

delete_inbound(){
  install_base

  show_inbounds
  echo
  read -rp "请输入要删除的入站标签: " tag
  [ -n "$tag" ] || { red "标签不能为空"; return; }

  if ! tag_exists "$tag"; then
    red "标签 $tag 不存在"
    return
  fi

  backup_config
  local tmp
  tmp=$(mktemp)
  jq --arg tag "$tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  check_config
  restart_service
  green "入站 $tag 已删除"
}

show_info(){
  [ -f "$INFO_FILE" ] && cat "$INFO_FILE" || yellow "暂无节点信息"
}

show_config(){
  [ -f "$CONFIG_FILE" ] && jq . "$CONFIG_FILE" || red "未找到配置文件"
}

show_inbounds(){
  if [ -f "$CONFIG_FILE" ]; then
    jq '.inbounds[]? | {tag,type,listen_port,network,override_address,override_port}' "$CONFIG_FILE"
  else
    red "未找到配置文件"
  fi
}

logs(){
  docker logs -f sing-box
}

backup_config(){
  mkdir -p "$BACKUP_DIR"
  local backup_file
  backup_file="$BACKUP_DIR/sing-box-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

  tar -czf "$backup_file" -C "$WORK_DIR" config nodes.txt docker-compose.yml 2>/dev/null || true
  green "配置已备份：$backup_file"
}

restore_config(){
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
    tar -xzf "$file" -C "$WORK_DIR"
    check_config
    restart_service
    green "配置已恢复并重启"
  else
    yellow "已取消"
  fi
}

show_version(){
  echo "目标镜像：$SING_BOX_IMAGE"
  echo
  echo "当前 sing-box 容器版本："
  docker exec sing-box sing-box version || true

  echo
  echo "当前本地镜像："
  docker images "$SING_BOX_IMAGE" || true

  echo
  echo "当前容器状态："
  docker ps -a --filter name=sing-box
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
    echo "0. 返回主菜单"
    echo "======================================"
    read -rp "请选择: " s

    case "$s" in
      1) show_bbr_status; pause ;;
      2) enable_bbr; pause ;;
      0) break ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

update_singbox_image(){
  install_base

  yellow "更新前自动备份配置..."
  backup_config

  cd "$WORK_DIR"
  yellow "拉取 sing-box 镜像：$SING_BOX_IMAGE"
  docker compose pull

  yellow "使用目标镜像检查配置..."
  check_config

  yellow "配置检查通过，正在重启..."
  docker compose up -d --force-recreate

  green "sing-box 镜像已更新"
  docker exec sing-box sing-box version || true
}

update_script(){
  if [ -z "$SCRIPT_URL" ]; then
    red "当前未配置 SCRIPT_URL，不能自动更新脚本自身"
    echo
    echo "可以把脚本上传到 GitHub Raw / Gitee Raw / 自己的网站，然后设置环境变量："
    echo "SCRIPT_URL=\"https://你的地址/singbox-docker.sh\" sb"
    return
  fi

  yellow "备份当前脚本..."
  cp "$SCRIPT_PATH" "$SCRIPT_PATH.bak.$(date +%Y%m%d-%H%M%S)"

  yellow "下载新脚本..."
  curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH.tmp"

  if bash -n "$SCRIPT_PATH.tmp"; then
    mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    green "脚本自身已更新"
  else
    rm -f "$SCRIPT_PATH.tmp"
    red "新脚本语法检查失败，已取消更新"
  fi
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
      1) update_singbox_image; pause ;;
      2) show_version; pause ;;
      3) backup_config; pause ;;
      4) restore_config; pause ;;
      5) update_script; pause ;;
      6) install_shortcut; pause ;;
      0) break ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

uninstall(){
  echo "即将停止容器并删除目录：$WORK_DIR"
  read -rp "确认卸载？输入 y 确认: " c
  if [ "$c" = "y" ]; then
    backup_config || true
    cd "$WORK_DIR" 2>/dev/null && docker compose down || true
    rm -rf "$WORK_DIR"
    rm -f "$SCRIPT_PATH"
    green "已卸载，并删除快捷命令 sb"
  else
    yellow "已取消"
  fi
}

menu(){
  clear
  echo "======================================"
  echo " sing-box Docker 多入站管理脚本"
  echo " 镜像：$SING_BOX_IMAGE"
  echo "======================================"
  echo "1. 初始化 sing-box Docker"
  echo "2. 添加 VLESS Reality 入站"
  echo "3. 添加 Hysteria2 入站"
  echo "4. 添加 Door 转发入站"
  echo "5. 删除入站"
  echo "6. 查看节点信息"
  echo "7. 查看所有入站"
  echo "8. 查看完整配置"
  echo "9. 检查配置"
  echo "10. 启动 sing-box"
  echo "11. 重启 sing-box"
  echo "12. 停止 sing-box"
  echo "13. 查看日志"
  echo "14. 更新管理"
  echo "15. 系统优化"
  echo "16. 安装/修复快捷命令 sb"
  echo "17. 卸载"
  echo "0. 退出"
  echo "======================================"
  read -rp "请选择: " num

  case "$num" in
    1) install_base; start_service ;;
    2) add_reality ;;
    3) add_hysteria2 ;;
    4) add_door ;;
    5) delete_inbound ;;
    6) show_info ;;
    7) show_inbounds ;;
    8) show_config ;;
    9) check_config ;;
    10) start_service ;;
    11) restart_service ;;
    12) stop_service ;;
    13) logs ;;
    14) update_menu ;;
    15) system_menu ;;
    16) install_shortcut ;;
    17) uninstall ;;
    0) exit 0 ;;
    *) red "无效选择" ;;
  esac

  pause
}

main(){
  check_root
  need_cmd bash
  while true; do
    menu
  done
}

main "$@"
