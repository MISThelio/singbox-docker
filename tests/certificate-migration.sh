#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/singbox-docker.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
passed=0
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
  -subj /CN=old.test.example -addext 'subjectAltName=DNS:old.test.example,DNS:second.test.example' \
  -keyout "$TEST_ROOT/key.pem" -out "$TEST_ROOT/cert.pem" >/dev/null 2>&1

fixture(){
  WORK_DIR=$(mktemp -d "$TEST_ROOT/case-XXXXXX")
  CONFIG_DIR="$WORK_DIR/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
  INFO_FILE="$WORK_DIR/nodes.txt"; COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
  BACKUP_DIR="$WORK_DIR/backup"; LETSENCRYPT_DIR="$WORK_DIR/letsencrypt"
  TRACE="$WORK_DIR/trace"; VERSION=3.0.0; FAIL_NAME=""; FAIL_BEFORE=0
  mkdir -p "$CONFIG_DIR" "$LETSENCRYPT_DIR/renewal" "$LETSENCRYPT_DIR/renewal-hooks/deploy"
  echo '{"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$CONFIG_FILE"
  echo '{"services":{"sing-box":{"image":"fixture"}}}' > "$COMPOSE_FILE"
  echo original-info > "$INFO_FILE"
  service_container(){ :; }
  gateway_container(){ if [ -f "$WORK_DIR/running" ]; then echo gateway-id; fi; }
  gateway_running(){ [ -f "$WORK_DIR/running" ]; }
  compose(){ if [ "$1" = config ]; then cat "$COMPOSE_FILE"; else return 1; fi; }
  port_used(){ return 1; }
  install_certbot(){ :; }; open_port(){ :; }
  docker(){
    case "$1" in
      image) return 0 ;;
      run) echo '--with-stream_ssl_preread_module' ;;
      inspect) echo true ;;
      rm|stop) rm -f "$WORK_DIR/running" ;;
      *) return 1 ;;
    esac
  }
  gateway_apply(){
    mkdir -p "$CONFIG_DIR/gateway/acme"
    echo nginx > "$CONFIG_DIR/gateway/nginx.conf"
    touch "$WORK_DIR/running"
    jq '.services["singbox-gateway"]={labels:{"io.singbox-docker.gateway":"true"}}' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp"
    mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
  }
  certbot(){
    if [ "$1" = --version ]; then echo "certbot $VERSION"; return 0; fi
    printf '%s\n' "$*" >> "$TRACE"
    [ "$1" = reconfigure ]
    local name="" previous="" arg
    for arg in "$@"; do
      if [ "$previous" = --cert-name ]; then name="$arg"; fi
      previous="$arg"
    done
    [[ "$*" == *--no-directory-hooks* && "$*" == *--webroot* && "$*" != *--force-renewal* ]]
    if [ "$FAIL_BEFORE" = 1 ]; then return 1; fi
    # Only the mock CLI rewrites fixture INIs; the production manager calls Certbot reconfigure.
    python3 - "$LETSENCRYPT_DIR/renewal/$name.conf" "$CONFIG_DIR/gateway/acme" <<'PYMOCK'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('authenticator = standalone', 'authenticator = webroot') +
             '\nwebroot_path = ' + sys.argv[2] + ',\n[[webroot_map]]\nold.test.example = ' + sys.argv[2] + '\n')
PYMOCK
    [ "$name" != "$FAIL_NAME" ]
  }
}

legacy(){
  local name="$1" tag="$2" dir="$CONFIG_DIR/cert-$2"
  mkdir -p "$dir" "$LETSENCRYPT_DIR/live/$name"
  cp "$TEST_ROOT/cert.pem" "$dir/cert.pem"
  cp "$TEST_ROOT/key.pem" "$dir/private.key"
  cp "$TEST_ROOT/cert.pem" "$LETSENCRYPT_DIR/live/$name/fullchain.pem"
  cp "$TEST_ROOT/key.pem" "$LETSENCRYPT_DIR/live/$name/privkey.pem"
  cat > "$LETSENCRYPT_DIR/renewal/$name.conf" <<EOF
version = 2.9.0
archive_dir = $LETSENCRYPT_DIR/archive/$name
fullchain = $LETSENCRYPT_DIR/live/$name/fullchain.pem
privkey = $LETSENCRYPT_DIR/live/$name/privkey.pem
[renewalparams]
account = fixture-account
server = https://acme-v02.api.letsencrypt.org/directory
key_type = ecdsa
authenticator = standalone
EOF
  chmod 640 "$LETSENCRYPT_DIR/renewal/$name.conf"
  cp -p "$LETSENCRYPT_DIR/renewal/$name.conf" "$WORK_DIR/$name.original"
  legacy_cert_hook_contents "$name" "$dir" > "$LETSENCRYPT_DIR/renewal-hooks/deploy/singbox-docker-$tag.sh"
  chmod 700 "$LETSENCRYPT_DIR/renewal-hooks/deploy/singbox-docker-$tag.sh"
  jq --arg tag "$tag" '.inbounds += [{type:"hysteria2",tag:$tag,tls:{
    certificate_path:("/etc/sing-box/cert-"+$tag+"/cert.pem"),key_path:("/etc/sing-box/cert-"+$tag+"/private.key")}}]' \
    "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

unchanged(){
  local name
  for name in "$@"; do cmp "$WORK_DIR/$name.original" "$LETSENCRYPT_DIR/renewal/$name.conf"; done
  [ ! -f "$WORK_DIR/running" ]
  [ ! -f "$CONFIG_DIR/.shared-443" ]
  [ "$(cat "$INFO_FILE")" = original-info ]
}
run_test(){ "$@"; passed=$((passed+1)); echo "PASS $1"; }

managed_success() (
  fixture; legacy old.test.example hy2-old; legacy second.test.example anytls-old
  cp "$CONFIG_FILE" "$WORK_DIR/config.original"
  shared_transaction gateway_initialize <<< y
  jq -e 'length == 2 and all(.[]; .params.authenticator == "webroot")' < <(certificate_inventory) >/dev/null
  cmp "$WORK_DIR/config.original" "$CONFIG_FILE"
  cmp "$TEST_ROOT/cert.pem" "$LETSENCRYPT_DIR/live/old.test.example/fullchain.pem"
  cmp "$TEST_ROOT/key.pem" "$LETSENCRYPT_DIR/live/old.test.example/privkey.pem"
  cmp "$LETSENCRYPT_DIR/renewal-hooks/deploy/singbox-docker-hy2-old.sh" <(legacy_cert_hook_contents old.test.example "$CONFIG_DIR/cert-hy2-old")
  [ "$(stat -c %a "$LETSENCRYPT_DIR/renewal/old.test.example.conf")" = 640 ]
  local count
  count=$(wc -l < "$TRACE"); [ "$count" -eq 2 ]
  shared_transaction gateway_initialize </dev/null
  [ "$(wc -l < "$TRACE")" -eq "$count" ]
  if certificate_guard_gateway_removal; then exit 1; fi
)
declined() (
  fixture; legacy old.test.example hy2-old
  if shared_transaction gateway_initialize <<< n; then exit 1; fi
  unchanged old.test.example; [ ! -f "$TRACE" ]
)
unknown_owner() (
  fixture; legacy old.test.example hy2-old
  echo '# changed by another manager' >> "$LETSENCRYPT_DIR/renewal-hooks/deploy/singbox-docker-hy2-old.sh"
  if shared_transaction gateway_initialize <<< y; then exit 1; fi
  unchanged old.test.example; [ ! -f "$TRACE" ]
)
wrong_fingerprint() (
  fixture; legacy old.test.example hy2-old
  cp /dev/null "$CONFIG_DIR/cert-hy2-old/cert.pem"
  if shared_transaction gateway_initialize <<< y; then exit 1; fi
  unchanged old.test.example; [ ! -f "$TRACE" ]
)
unsafe_hooks() (
  local kind
  for kind in lineage global directory; do
    fixture; legacy old.test.example hy2-old
    case "$kind" in
      lineage) echo "pre_hook = touch $WORK_DIR/should-not-run" >> "$LETSENCRYPT_DIR/renewal/old.test.example.conf" ;;
      global) echo "post-hook = touch $WORK_DIR/should-not-run" > "$LETSENCRYPT_DIR/cli.ini" ;;
      directory)
        mkdir -p "$LETSENCRYPT_DIR/renewal-hooks/pre"
        printf '#!/bin/sh\ntouch "%s"\n' "$WORK_DIR/should-not-run" > "$LETSENCRYPT_DIR/renewal-hooks/pre/unsafe"
        chmod +x "$LETSENCRYPT_DIR/renewal-hooks/pre/unsafe" ;;
    esac
    if shared_transaction gateway_initialize <<< y; then exit 1; fi
    [ ! -f "$WORK_DIR/running" ]; [ ! -f "$TRACE" ]; [ ! -f "$WORK_DIR/should-not-run" ]
  done
)
old_certbot() (
  fixture; legacy old.test.example hy2-old; VERSION=2.2.0
  if shared_transaction gateway_initialize <<< y; then exit 1; fi
  unchanged old.test.example; [ ! -f "$TRACE" ]
)
partial_failure() (
  fixture; legacy old.test.example hy2-old; legacy second.test.example hy2-second
  FAIL_NAME=second.test.example
  if shared_transaction gateway_initialize <<< y; then exit 1; fi
  unchanged old.test.example second.test.example
  [ "$(stat -c %a "$LETSENCRYPT_DIR/renewal/old.test.example.conf")" = 640 ]
)
staging_failure() (
  fixture; legacy old.test.example hy2-old; FAIL_BEFORE=1
  if shared_transaction gateway_initialize <<< y; then exit 1; fi
  unchanged old.test.example
)
later_failure() (
  fixture; legacy old.test.example hy2-old
  operation(){ gateway_initialize || return 1; echo bad > "$CONFIG_FILE"; echo changed > "$INFO_FILE"; return 1; }
  cp "$CONFIG_FILE" "$WORK_DIR/config.original"
  if shared_transaction operation <<< y; then exit 1; fi
  unchanged old.test.example; cmp "$CONFIG_FILE" "$WORK_DIR/config.original"
)
disconnect_after_migration() (
  fixture; legacy old.test.example hy2-old
  operation(){ gateway_initialize || return 1; kill -HUP "$BASHPID"; return 1; }
  if shared_transaction operation <<< y; then exit 1; fi
  unchanged old.test.example
)
concurrent_change() (
  fixture; legacy old.test.example hy2-old
  operation(){ gateway_initialize || return 1; echo 'external_change = keep-me' >> "$LETSENCRYPT_DIR/renewal/old.test.example.conf"; return 1; }
  if shared_transaction operation <<< y; then exit 1; fi
  grep -q 'external_change = keep-me' "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
  [ -f "$WORK_DIR/running" ]; [ -f "$CONFIG_DIR/.shared-443" ]
  compgen -G "$WORK_DIR/.shared-operation.*" >/dev/null
  compgen -G "$BACKUP_DIR/certbot-migration-*/*.conf" >/dev/null
)
occupied_port() (
  fixture; legacy old.test.example hy2-old
  port_used(){ [ "$1" = 80 ]; }
  if shared_transaction gateway_initialize <<< y; then exit 1; fi
  unchanged old.test.example; [ ! -f "$TRACE" ]
)
empty_inventory() (
  fixture
  shared_transaction gateway_initialize </dev/null
  [ -f "$WORK_DIR/running" ]; [ ! -f "$TRACE" ]
)
map_only_webroot() (
  fixture; legacy old.test.example hy2-old
  shared_transaction gateway_initialize <<< y
  sed -i '/^webroot_path =/d' "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
  certificate_uses_gateway old.test.example "$(certificate_inventory)"
  sed -i "s|^old.test.example = .*|old.test.example = $CONFIG_DIR/gateway/acme-other|" "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
  if certificate_uses_gateway old.test.example "$(certificate_inventory)"; then exit 1; fi
)
unknown_new_renewal_keeps_entry() (
  fixture
  operation(){
    gateway_initialize || return 1
    legacy old.test.example hy2-new
    sed -i 's/authenticator = standalone/authenticator = webroot/' "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
    echo "webroot_path = $CONFIG_DIR/gateway/acme," >> "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
    return 1
  }
  if shared_transaction operation </dev/null; then exit 1; fi
  [ -f "$WORK_DIR/running" ]; [ -f "$CONFIG_DIR/.shared-443" ]
  certificate_gateway_required
)
changed_after_approval() (
  fixture; legacy old.test.example hy2-old
  operation(){
    certificate_migration_plan || return 1
    echo '# concurrent edit' >> "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
    gateway_preflight
  }
  if shared_transaction operation <<< y; then exit 1; fi
  [ ! -f "$WORK_DIR/running" ]; [ ! -f "$TRACE" ]
  grep -q 'concurrent edit' "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
)
symlink_renewal_refused() (
  fixture; legacy old.test.example hy2-old
  mv "$LETSENCRYPT_DIR/renewal/old.test.example.conf" "$WORK_DIR/real-renewal"
  ln -s "$WORK_DIR/real-renewal" "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
  if shared_transaction gateway_initialize <<< y; then exit 1; fi
  [ ! -f "$WORK_DIR/running" ]; [ ! -f "$TRACE" ]
  cmp "$WORK_DIR/old.test.example.original" "$WORK_DIR/real-renewal"
)
restore_and_uninstall_preserve_validation() (
  fixture; legacy old.test.example hy2-old
  mkdir -p "$BACKUP_DIR"
  tar -czf "$BACKUP_DIR/before-gateway.tar.gz" -C "$WORK_DIR" config docker-compose.yml nodes.txt
  shared_transaction gateway_initialize <<< y
  cp "$CONFIG_FILE" "$WORK_DIR/active.original"
  prepare_runtime(){ :; }
  recreate_service(){ touch "$WORK_DIR/should-not-recreate"; }
  if restore_config <<INPUT
$BACKUP_DIR/before-gateway.tar.gz
y
INPUT
  then exit 1; fi
  cmp "$CONFIG_FILE" "$WORK_DIR/active.original"
  [ -f "$WORK_DIR/running" ]; [ -f "$CONFIG_DIR/.shared-443" ]
  [ ! -f "$WORK_DIR/should-not-recreate" ]
  if uninstall <<< y; then exit 1; fi
  [ -f "$WORK_DIR/running" ]; [ -f "$CONFIG_DIR/.shared-443" ]
)
certbot_lock() (
  fixture; legacy old.test.example hy2-old
  python3 - "$LETSENCRYPT_DIR" <<'PYLOCK' &
import fcntl, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
with (root / '.certbot.lock').open('w') as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX)
    (root / 'locked').touch()
    time.sleep(30)
PYLOCK
  local pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
  for ((i=0;i<100;i++)); do [ ! -f "$LETSENCRYPT_DIR/locked" ] || break; sleep .05; done
  mkdir "$WORK_DIR/journal"
  local sha
  sha=$(jq -r '.[0].sha' < <(certificate_inventory))
  if certificate_state snapshot old.test.example "$WORK_DIR/journal" "$sha"; then exit 1; fi
  cmp "$WORK_DIR/old.test.example.original" "$LETSENCRYPT_DIR/renewal/old.test.example.conf"
)

for test in managed_success declined unknown_owner wrong_fingerprint unsafe_hooks old_certbot partial_failure \
  staging_failure later_failure disconnect_after_migration concurrent_change occupied_port empty_inventory \
  map_only_webroot unknown_new_renewal_keeps_entry changed_after_approval symlink_renewal_refused \
  restore_and_uninstall_preserve_validation certbot_lock; do
  run_test "$test"
done
echo "$passed certificate migration tests passed"
