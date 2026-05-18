#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/sb}"
SCRIPT_URL="${SCRIPT_URL:-}"

red(){ printf '\033[31m%s\033[0m\n' "$1"; }
green(){ printf '\033[32m%s\033[0m\n' "$1"; }

[ "${EUID:-$(id -u)}" -eq 0 ] || { red "请用 root 运行"; exit 1; }

if [ -f "./singbox-docker.sh" ]; then
  install -m 0755 "./singbox-docker.sh" "$INSTALL_PATH"
else
  [ -n "$SCRIPT_URL" ] || { red "未找到 ./singbox-docker.sh，请通过 SCRIPT_URL 指定远程脚本地址"; exit 1; }
  curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
fi

green "已安装快捷命令：sb"
"$INSTALL_PATH"
