#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/singbox-docker.sh"
TEST_ROOT=$(mktemp -d)
pids=()
cleanup(){
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
WORK_DIR="$TEST_ROOT/runtime"
CONFIG_DIR="$WORK_DIR/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"; INFO_FILE="$WORK_DIR/nodes.txt"
mkdir -p "$CONFIG_DIR/gateway/certs" "$CONFIG_DIR/gateway/acme"
chmod 755 "$TEST_ROOT" "$WORK_DIR" "$CONFIG_DIR" "$CONFIG_DIR/gateway" "$CONFIG_DIR/gateway/acme"
printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$CONFIG_FILE"
printf '%s\n' '{"services":{"sing-box":{"image":"fixture"}}}' > "$COMPOSE_FILE"
printf '' > "$INFO_FILE"

for domain in vless.test.example anytls.test.example hy2.test.example www.test.example; do
  valid_domain "$domain"
done
for domain in 'a.b.' 'a..b' 'a;evil.test' '*.test.example' 'UPPER.test' '-bad.test'; do
  if valid_domain "$domain"; then echo "Accepted invalid domain: $domain"; exit 1; fi
done
valid_website_upstream http://127.0.0.1:18080
valid_website_upstream 'http://[::1]:18080'
for upstream in http://127.0.0.1:443 http://127.0.0.1:80 'http://127.0.0.1:8080;evil' http://example.com:8080; do
  if valid_website_upstream "$upstream"; then echo "Accepted invalid upstream: $upstream"; exit 1; fi
done
echo 'PASS domain and upstream validation'

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TEST_ROOT/key.pem" -out "$TEST_ROOT/cert.pem" \
  -days 1 -subj /CN=www.test.example \
  -addext 'subjectAltName=DNS:www.test.example,DNS:vless.test.example,DNS:anytls.test.example,DNS:hy2.test.example' >/dev/null 2>&1
validate_certificate www.test.example "$TEST_ROOT/cert.pem" "$TEST_ROOT/key.pem"
if validate_certificate wrong.test.example "$TEST_ROOT/cert.pem" "$TEST_ROOT/key.pem"; then exit 1; fi
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TEST_ROOT/wrong-key.pem" >/dev/null 2>&1
if validate_certificate www.test.example "$TEST_ROOT/cert.pem" "$TEST_ROOT/wrong-key.pem"; then exit 1; fi
echo 'PASS certificate hostname and key validation'

jq -n --argjson dynamic "$(if nginx -V 2>&1 | grep -q -- '--with-stream=dynamic'; then echo true; else echo false; fi)" \
  '{version:1,nginx_image:"fixture",tls_port:28443,dynamic_stream:$dynamic,domains:{}}' > "$CONFIG_DIR/.shared-443"

# Exercise the real shared-node builder, substituting only infrastructure actions.
gateway_initialize(){ :; }
gateway_certificate(){
  GW_SOURCE_CERT="$TEST_ROOT/cert.pem"; GW_SOURCE_KEY="$TEST_ROOT/key.pem"
  mkdir -p "$CONFIG_DIR/gateway/certs/$1"
  cp "$GW_SOURCE_CERT" "$CONFIG_DIR/gateway/certs/$1/cert.pem"
  cp "$GW_SOURCE_KEY" "$CONFIG_DIR/gateway/certs/$1/private.key"
}
ensure_singbox_image(){ :; }; runtime_image(){ echo fixture; }
docker(){
  if [ "$1" = run ]; then shift 3; sing-box "$@"; else echo "Unexpected Docker call: $*" >&2; return 1; fi
}
uuidgen(){ cat /proc/sys/kernel/random/uuid; }
add_inbound(){
  jq --argjson inbound "$1" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$CONFIG_FILE.next"
  mv "$CONFIG_FILE.next" "$CONFIG_FILE"
}
gateway_apply(){ :; }; install_gateway_renewal(){ :; }; open_port(){ :; }
shared_add_node vless vless.test.example <<< '' > "$TEST_ROOT/vless-output"
shared_add_node anytls anytls.test.example <<< $'\np"@:/?&$' > "$TEST_ROOT/anytls-output"
gateway_certificate hy2.test.example
jq --arg cert "$TEST_ROOT/cert.pem" --arg key "$TEST_ROOT/key.pem" \
  '.domains["hy2.test.example"]={kind:"website",source_cert:$cert,source_key:$key,website_upstream:"http://127.0.0.1:18080"}' \
  "$CONFIG_DIR/.shared-443" > "$CONFIG_DIR/.state-next"
mv "$CONFIG_DIR/.state-next" "$CONFIG_DIR/.shared-443"
shared_add_node hysteria2 hy2.test.example <<< $'\n' > "$TEST_ROOT/hy2-output"
grep -q '@vless.test.example:443?' "$TEST_ROOT/vless-output"
grep -q 'UUID：' "$TEST_ROOT/vless-output"
grep -q 'PublicKey：' "$TEST_ROOT/vless-output"
grep -q 'ShortID：' "$TEST_ROOT/vless-output"
grep -q '@anytls.test.example:443?' "$TEST_ROOT/anytls-output"
grep -q '@hy2.test.example:443?' "$TEST_ROOT/hy2-output"
jq -e '.domains["hy2.test.example"].kind == "hysteria2" and .domains["hy2.test.example"].website_upstream == "http://127.0.0.1:18080"' "$CONFIG_DIR/.shared-443" >/dev/null
if shared_add_node hysteria2 second-hy2.test.example <<< $'\n'; then echo 'Duplicate UDP 443 accepted'; exit 1; fi
jq -e 'all(.inbounds[]; if .type == "hysteria2" then .listen_port == 443 else .listen == "127.0.0.1" and .listen_port != 443 end)' "$CONFIG_FILE" >/dev/null
grep -q '@anytls.test.example:443?' "$INFO_FILE"
grep -q 'p%22%40%3A%2F%3F%26%24@anytls.test.example:443?' "$INFO_FILE"
grep -q '@vless.test.example:443?' "$INFO_FILE"
grep -q '@hy2.test.example:443?' "$INFO_FILE"
echo 'PASS generated inbounds, public links and UDP exclusivity'

gateway_certificate www.test.example
jq --arg cert "$TEST_ROOT/cert.pem" --arg key "$TEST_ROOT/key.pem" \
  '.domains["www.test.example"]={kind:"website",source_cert:$cert,source_key:$key,website_upstream:"http://127.0.0.1:18080"}' \
  "$CONFIG_DIR/.shared-443" > "$CONFIG_DIR/.state-next"
mv "$CONFIG_DIR/.state-next" "$CONFIG_DIR/.shared-443"
gateway_render "$CONFIG_DIR/gateway/nginx.conf"
# Insert a deterministic local website into the generated HTTP context.
sed -i '/^http {/a\ server { listen 127.0.0.1:18080; location / { return 200 "fixture-website"; } }' "$CONFIG_DIR/gateway/nginx.conf"
ln -s "$CONFIG_DIR/gateway" /etc/sb-gateway
ln -s "$CONFIG_DIR" /etc/sing-box
nginx -t -c /etc/sb-gateway/nginx.conf
sing-box check -C /etc/sing-box
nginx -c /etc/sb-gateway/nginx.conf -g 'daemon off;' > "$TEST_ROOT/nginx.log" 2>&1 &
pids+=("$!")
sing-box run -C /etc/sing-box > "$TEST_ROOT/server.log" 2>&1 &
pids+=("$!")
sleep 1
curl -fsS --noproxy '*' --cacert "$TEST_ROOT/cert.pem" --resolve www.test.example:443:127.0.0.1 \
  https://www.test.example/ | grep -q fixture-website
echo 'PASS real HTTPS website on TCP 443'
curl -fsS --noproxy '*' --cacert "$TEST_ROOT/cert.pem" --resolve hy2.test.example:443:127.0.0.1 \
  https://hy2.test.example/ | grep -q fixture-website
echo 'PASS existing website domain also serves HTTPS alongside Hy2'

for kind in vless anytls hysteria2; do
  domain=$(jq -r --arg kind "$kind" '.domains | to_entries[] | select(.value.kind == $kind) | .key' "$CONFIG_DIR/.shared-443")
  jq --arg kind "$kind" --arg domain "$domain" --rawfile cert "$TEST_ROOT/cert.pem" '
    (.inbounds[] | select(.type == $kind)) as $inbound |
    {log:{level:"error"},inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:18081}],outbounds:[
      {type:$kind,tag:"proxy",server:"127.0.0.1",server_port:443,
        tls:({enabled:true,server_name:$domain} +
          if $kind == "vless" then {utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,short_id:$inbound.tls.reality.short_id[0]}}
          else {certificate:[$cert]} end)} +
        if $kind == "vless" then {uuid:$inbound.users[0].uuid,flow:"xtls-rprx-vision"}
        else {password:$inbound.users[0].password} end]}' "$CONFIG_FILE" > "$TEST_ROOT/client.json"
  if [ "$kind" = vless ]; then
    public=$(sed -n 's/.*pbk=\([^&]*\).*/\1/p' "$INFO_FILE")
    jq --arg public "$public" '.outbounds[0].tls.reality.public_key=$public' "$TEST_ROOT/client.json" > "$TEST_ROOT/client-next"
    mv "$TEST_ROOT/client-next" "$TEST_ROOT/client.json"
  fi
  sing-box run -c "$TEST_ROOT/client.json" > "$TEST_ROOT/client.log" 2>&1 &
  client_pid=$!
  pids+=("$client_pid")
  sleep 1
  if ! curl -fsS --max-time 8 --noproxy '' --socks5-hostname 127.0.0.1:18081 http://127.0.0.1:18080/ | grep -q fixture-website; then
    cat "$TEST_ROOT/client.log" "$TEST_ROOT/server.log" "$TEST_ROOT/nginx.log"
    exit 1
  fi
  kill "$client_pid"
  wait "$client_pid" || true
  echo "PASS real $kind through shared public port 443"
done

mkdir -p "$CONFIG_DIR/gateway/acme/.well-known/acme-challenge"
chmod 755 "$CONFIG_DIR/gateway/acme/.well-known" "$CONFIG_DIR/gateway/acme/.well-known/acme-challenge"
printf test-token > "$CONFIG_DIR/gateway/acme/.well-known/acme-challenge/token"
chmod 644 "$CONFIG_DIR/gateway/acme/.well-known/acme-challenge/token"
curl -fsS --noproxy '*' http://127.0.0.1/.well-known/acme-challenge/token | grep -q test-token
echo 'PASS renewal webroot remains available with HTTPS and nodes running'

check_config(){ sing-box check -C /etc/sing-box; }
gateway_apply(){
  gateway_render "$CONFIG_DIR/gateway/nginx.conf"
  sed -i '/^http {/a\ server { listen 127.0.0.1:18080; location / { return 200 "fixture-website"; } }' "$CONFIG_DIR/gateway/nginx.conf"
  nginx -t -c /etc/sb-gateway/nginx.conf
  nginx -s reload -c /etc/sb-gateway/nginx.conf
}
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TEST_ROOT/new-key.pem" -out "$TEST_ROOT/new-cert.pem" \
  -days 1 -subj /CN=www.test.example \
  -addext 'subjectAltName=DNS:www.test.example,DNS:vless.test.example,DNS:anytls.test.example,DNS:hy2.test.example' >/dev/null 2>&1
mv "$TEST_ROOT/new-key.pem" "$TEST_ROOT/key.pem"
mv "$TEST_ROOT/new-cert.pem" "$TEST_ROOT/cert.pem"
sync_shared_certificates
sleep 1
curl -fsS --noproxy '*' --cacert "$TEST_ROOT/cert.pem" --resolve www.test.example:443:127.0.0.1 \
  https://www.test.example/ | grep -q fixture-website
for pid in "${pids[@]:0:2}"; do kill -0 "$pid"; done
echo 'PASS certificate rotation without restarting website or sing-box'
