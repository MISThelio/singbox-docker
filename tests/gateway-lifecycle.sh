#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/singbox-docker.sh"
WORK_DIR=$(mktemp -d)
CONFIG_DIR="$WORK_DIR/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"; INFO_FILE="$WORK_DIR/nodes.txt"
BACKUP_DIR="$WORK_DIR/backup"
export COMPOSE_PROJECT_NAME="sb-gateway-test-$BASHPID-$RANDOM"
website_name="$COMPOSE_PROJECT_NAME-website"
cleanup(){
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$website_name" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
mkdir -p "$CONFIG_DIR" "$WORK_DIR/data" "$BACKUP_DIR" "$WORK_DIR/site"
printf '<h1>fixture-website</h1>\n' > "$WORK_DIR/site/index.html"
chmod 755 "$WORK_DIR/site"
chmod 644 "$WORK_DIR/site/index.html"
printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$CONFIG_FILE"
jq -n --arg image "$SING_BOX_IMAGE" '{services:{"sing-box":{image:$image,network_mode:"host",volumes:["./config:/etc/sing-box","./data:/var/lib/sing-box"],command:["-C","/etc/sing-box","run"]}}}' > "$COMPOSE_FILE"
printf '' > "$INFO_FILE"
# Certificate issuance is tested without contacting a public CA or installing host timers.
install_gateway_renewal(){ :; }; open_port(){ :; }
new_certificate(){
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK_DIR/new-key.pem" -out "$WORK_DIR/new-cert.pem" \
    -days 1 -subj /CN=www.test.example \
    -addext 'subjectAltName=DNS:www.test.example,DNS:anytls.test.example,DNS:vless.test.example,DNS:broken.test.example' >/dev/null 2>&1
  mv "$WORK_DIR/new-key.pem" "$WORK_DIR/source-key.pem"
  mv "$WORK_DIR/new-cert.pem" "$WORK_DIR/source-cert.pem"
}
new_certificate
start_service
core_id=$(service_container)
shared_transaction shared_add_node anytls anytls.test.example <<INPUT

2
$WORK_DIR/source-cert.pem
$WORK_DIR/source-key.pem

INPUT
gateway_id=$(gateway_container)
[ -n "$gateway_id" ]
[ "$(service_container)" = "$core_id" ]
echo 'PASS real gateway bootstrap and loopback AnyTLS backend'

shared_transaction shared_add_node vless vless.test.example <<INPUT

2
$WORK_DIR/source-cert.pem
$WORK_DIR/source-key.pem
INPUT
[ "$(gateway_container)" = "$gateway_id" ]
[ "$(service_container)" = "$core_id" ]
echo 'PASS additional SNI route preserves both container IDs'

website_port=$(allocate_private_port)
docker run -d --name "$website_name" --network host -v "$WORK_DIR/site:/www:ro" \
  alpine:3.22 httpd -f -p "127.0.0.1:$website_port" -h /www >/dev/null
website_id=$(docker inspect --format '{{.Id}}' "$website_name")
shared_transaction shared_add_website <<INPUT
www.test.example
http://127.0.0.1:$website_port
2
$WORK_DIR/source-cert.pem
$WORK_DIR/source-key.pem
INPUT
check_website(){
  curl -fsS --noproxy '*' --cacert "$WORK_DIR/source-cert.pem" \
    --resolve www.test.example:443:127.0.0.1 https://www.test.example/ | grep -q fixture-website
}
check_website
[ "$(docker inspect --format '{{.Id}}' "$website_name")" = "$website_id" ]
echo 'PASS normal Docker website shares HTTPS without app recreation'

node_tag=$(jq -r '.inbounds[] | select(.type == "vless") | .tag' "$CONFIG_FILE")
shared_transaction shared_delete_node "$node_tag"
check_website
jq -e '.domains | has("vless.test.example") | not' "$CONFIG_DIR/.shared-443" >/dev/null
echo 'PASS removing node does not remove website or its application'

cp "$CONFIG_FILE" "$WORK_DIR/before-config"
cp "$CONFIG_DIR/.shared-443" "$WORK_DIR/before-state"
cp "$INFO_FILE" "$WORK_DIR/before-info"
eval "$(declare -f gateway_render | sed '1s/gateway_render/real_gateway_render/')"
gateway_render(){
  real_gateway_render "$1" || return 1
  printf '\ninvalid_directive;\n' >> "$1"
}
if shared_transaction shared_add_node anytls broken.test.example <<INPUT

2
$WORK_DIR/source-cert.pem
$WORK_DIR/source-key.pem

INPUT
then echo 'FAIL invalid Nginx configuration accepted'; exit 1; fi
cmp "$CONFIG_FILE" "$WORK_DIR/before-config"
cmp "$CONFIG_DIR/.shared-443" "$WORK_DIR/before-state"
cmp "$INFO_FILE" "$WORK_DIR/before-info"
[ "$(gateway_container)" = "$gateway_id" ]
[ "$(service_container)" = "$core_id" ]
check_website
echo 'PASS failed gateway update restores node state while website stays usable'
gateway_render(){ real_gateway_render "$@"; }

new_certificate
shared_transaction sync_shared_certificates
sleep 1
check_website
[ "$(gateway_container)" = "$gateway_id" ]
[ "$(service_container)" = "$core_id" ]
[ "$(docker inspect --format '{{.Id}}' "$website_name")" = "$website_id" ]
echo 'PASS real certificate rotation preserves all three container IDs'
