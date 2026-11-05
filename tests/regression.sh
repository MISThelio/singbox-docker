#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/singbox-docker.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
passed=0

fixture(){
  WORK_DIR=$(mktemp -d "$TEST_ROOT/case-XXXXXX")
  CONFIG_DIR="$WORK_DIR/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
  INFO_FILE="$WORK_DIR/nodes.txt"; COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
  BACKUP_DIR="$WORK_DIR/backup"; TRACE="$WORK_DIR/trace"
  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$CONFIG_FILE"
  printf '%s\n' '{"services":{"sing-box":{"image":"fixture:old"}}}' > "$COMPOSE_FILE"
  printf 'original-info\n' > "$INFO_FILE"
  cp "$CONFIG_FILE" "$WORK_DIR/original.json"
  cp "$COMPOSE_FILE" "$WORK_DIR/original-compose"
  green(){ printf '%s\n' "$1"; }; red(){ printf '%s\n' "$1"; }; yellow(){ printf '%s\n' "$1"; }
}

run_test(){
  "$@"
  passed=$((passed + 1))
  printf 'PASS %s\n' "$1"
}

reject_candidate() (
  fixture
  check_config(){ return 1; }
  restart_service(){ echo unexpected > "$TRACE"; }
  if add_inbound '{"type":"unknown","tag":"bad"}'; then exit 1; fi
  cmp "$CONFIG_FILE" "$WORK_DIR/original.json"
  [ ! -f "$TRACE" ]
  [ "$(cat "$INFO_FILE")" = original-info ]
)

commit_candidate() (
  fixture
  check_config(){ jq -e '.inbounds' "$1" >/dev/null; }
  service_container(){ echo old-id; }
  docker(){ echo sha256:old; }
  restart_service(){ jq -e '.inbounds[0].tag == "new"' "$CONFIG_FILE" >/dev/null; }
  add_inbound '{"type":"vless","tag":"new"}'
  jq -e '.inbounds[0].tag == "new"' "$CONFIG_FILE" >/dev/null
)

rollback_candidate() (
  fixture
  check_config(){ return 0; }
  service_container(){ echo old-id; }
  docker(){ echo sha256:old; }
  restart_service(){ return 1; }
  recover_service(){
    [ "$1 $2" = 'old-id sha256:old' ]
    cmp "$CONFIG_FILE" "$WORK_DIR/original.json"
    echo recovered > "$TRACE"
  }
  if add_inbound '{"type":"vless","tag":"new"}'; then exit 1; fi
  cmp "$CONFIG_FILE" "$WORK_DIR/original.json"
  [ "$(cat "$TRACE")" = recovered ]
)

rollback_on_disconnect() (
  fixture
  check_config(){ return 0; }; service_container(){ echo old-id; }; docker(){ echo sha256:old; }
  restart_service(){ kill -HUP "$BASHPID"; return 1; }
  recover_service(){ echo recovered > "$TRACE"; }
  if add_inbound '{"type":"vless","tag":"new"}'; then exit 1; fi
  cmp "$CONFIG_FILE" "$WORK_DIR/original.json"
  [ "$(cat "$TRACE")" = recovered ]
)

backup_failure() (
  fixture
  tar(){ return 2; }
  if backup_config > "$WORK_DIR/output"; then exit 1; fi
  ! grep -q '配置已备份' "$WORK_DIR/output"
  [ -z "$(find "$BACKUP_DIR" -type f -print)" ]
)

backup_without_info() (
  fixture
  rm "$INFO_FILE"
  backup_config
  local archive
  archive=$(find "$BACKUP_DIR" -name '*.tar.gz')
  tar -tzf "$archive" | grep -q 'config/config.json'
)

regular_restart_keeps_container() (
  fixture
  check_config(){ return 0; }; service_container(){ echo renamed-id; }; wait_service(){ [ "$1" = renamed-id ]; }
  docker(){ printf '%s\n' "$*" >> "$TRACE"; }
  compose(){ echo unexpected >> "$TRACE"; return 1; }
  restart_service
  [ "$(cat "$TRACE")" = 'restart renamed-id' ]
)

validate_running_image() (
  fixture
  SING_BOX_IMAGE=fixture:unrelated
  runtime_image(){ echo sha256:running; }
  ensure_singbox_image(){ [ "$1" = sha256:running ]; }
  docker(){ printf '%s\n' "$*" > "$TRACE"; }
  check_config
  grep -q 'sha256:running check -C /etc/sing-box' "$TRACE"
  grep -q '/etc/sing-box:ro' "$TRACE"
)

protocol_specific_ports() (
  fixture
  ss(){ :; }
  printf '%s\n' '{"inbounds":[{"type":"vless","listen_port":443}]}' > "$CONFIG_FILE"
  port_used 443 tcp
  if port_used 443 udp; then exit 1; fi
  ss(){ [[ "$*" != *-lnu* ]] || echo udp-listener; }
  port_used 443 udp
)

find_renamed_container() (
  fixture
  compose(){ echo candidate old-id running-id; }
  docker(){ printf '%s\n' '[{"Id":"candidate","State":{"Status":"created","Running":false,"StartedAt":""}},{"Id":"old-id","State":{"Status":"exited","Running":false,"StartedAt":"2026-11-01"}},{"Id":"running-id","State":{"Status":"running","Running":true,"StartedAt":"2026-11-05"}}]'; }
  [ "$(service_container)" = running-id ]
)

update_failure() (
  fixture
  local phase="$1"
  prepare_runtime(){ :; }; service_container(){ echo old-id; }
  docker(){ echo sha256:old; }
  sync_compose_image(){ printf '%s\n' '{"services":{"sing-box":{"image":"fixture:new"}}}' > "$COMPOSE_FILE"; }
  compose_image(){ echo fixture:new; }
  compose(){ [ "$phase" != pull ]; }
  check_config(){ [ "$phase" != validate ]; }
  recreate_service(){ echo attempted >> "$TRACE"; return 1; }
  recover_service(){
    cmp "$COMPOSE_FILE" "$WORK_DIR/original-compose"
    [ "$1 $2" = 'old-id sha256:old' ]
    echo recovered >> "$TRACE"
  }
  if update_singbox_image; then exit 1; fi
  cmp "$COMPOSE_FILE" "$WORK_DIR/original-compose"
  if [ "$phase" = replace ]; then grep -q recovered "$TRACE"; else [ ! -e "$TRACE" ]; fi
)

recover_deleted_container() (
  fixture
  docker(){ [ "$1" != container ]; }
  sync_compose_image(){ [ "$1" = sha256:old ]; echo pinned >> "$TRACE"; }
  compose(){
    if [ "$1" = ps ]; then return 0; fi
    [ "$*" = 'up -d --no-deps --force-recreate sing-box' ]
  }
  service_container(){ echo replacement-id; }
  wait_service(){ [ "$1" = replacement-id ]; }
  recover_service deleted-id sha256:old
  grep -q pinned "$TRACE"
)

restore_failure() (
  fixture
  local phase="${1:-replace}"
  mkdir -p "$WORK_DIR/staged/config"
  printf '%s\n' '{"inbounds":[{"type":"vless","tag":"restore"}]}' > "$WORK_DIR/staged/config/config.json"
  cp "$COMPOSE_FILE" "$WORK_DIR/staged/docker-compose.yml"
  printf 'restored-info\n' > "$WORK_DIR/staged/nodes.txt"
  tar -czf "$WORK_DIR/input.tar.gz" -C "$WORK_DIR/staged" config nodes.txt docker-compose.yml
  cp "$WORK_DIR/input.tar.gz" "$BACKUP_DIR/input.tar.gz"
  prepare_runtime(){ :; }; service_container(){ echo old-id; }; docker(){ echo sha256:old; }
  compose_image(){ echo fixture:old; }; check_config(){ [ "$phase" != validate ]; }; recreate_service(){ return 1; }
  recover_service(){
    cmp "$CONFIG_FILE" "$WORK_DIR/original.json"
    [ "$(cat "$INFO_FILE")" = original-info ]
    echo recovered > "$TRACE"
  }
  if restore_config <<< "$WORK_DIR/input.tar.gz
y"; then exit 1; fi
  cmp "$CONFIG_FILE" "$WORK_DIR/original.json"
  cmp "$COMPOSE_FILE" "$WORK_DIR/original-compose"
  if [ "$phase" = replace ]; then [ "$(cat "$TRACE")" = recovered ]; else [ ! -f "$TRACE" ]; fi
)

readiness_rejects_crash() (
  fixture
  docker(){ echo 'exited none'; }
  if wait_service crashed; then exit 1; fi
)

structured_image_switch() (
  fixture
  printf '%s\n' 'FIXTURE_ENV=unchanged' > "$WORK_DIR/fixture.env"
  printf '%s\n' '{"services":{"sing-box":{"image":"fixture:old","env_file":["./fixture.env"],"command":["echo","$$FIXTURE_ENV"]},"other":{"image":"fixture:other"}}}' > "$COMPOSE_FILE"
  sync_compose_image fixture:new
  jq -e '.services["sing-box"].image == "fixture:new" and .services.other.image == "fixture:other"' "$COMPOSE_FILE" >/dev/null
  jq -e '.services["sing-box"].command[1] == "$$FIXTURE_ENV"' "$COMPOSE_FILE" >/dev/null
  [ "$(compose_image)" = fixture:new ]
)

backup_integrity_failure() (
  fixture
  tar(){
    if [ "$1" = -czf ]; then printf broken > "$2"; else return 2; fi
  }
  if backup_config; then exit 1; fi
  [ -z "$(find "$BACKUP_DIR" -type f -print)" ]
)

update_requires_backup() (
  fixture
  prepare_runtime(){ :; }; backup_config(){ return 1; }
  sync_compose_image(){ echo unexpected > "$TRACE"; }
  if update_singbox_image; then exit 1; fi
  [ ! -f "$TRACE" ]
  cmp "$COMPOSE_FILE" "$WORK_DIR/original-compose"
)

failed_recovery_retains_evidence() (
  fixture
  service_container(){ echo old-id; }; docker(){ echo sha256:old; }
  recover_service(){ return 1; }
  if (
    local transaction committed config_swapped restore_info deploy_started old_id old_image
    begin_deployment
    deploy_started=1
    exit 1
  ); then exit 1; fi
  [ -n "$(find "$WORK_DIR" -name compose.original -print)" ]
)

stop_replacement_before_recovery() (
  fixture
  compose(){ echo replacement-id; }
  sync_compose_image(){ [ "$1" = sha256:old ]; }
  docker(){
    case "$1" in
      container) return 0 ;;
      stop|restart) printf '%s\n' "$*" >> "$TRACE" ;;
    esac
  }
  wait_service(){ [ "$1" = old-id ]; }
  recover_service old-id sha256:old
  [ "$(head -n 1 "$TRACE")" = 'stop replacement-id' ]
  [ "$(tail -n 1 "$TRACE")" = 'restart old-id' ]
)

shared_operation_rollback() (
  fixture
  mkdir -p "$CONFIG_DIR/gateway"
  echo original-nginx > "$CONFIG_DIR/gateway/nginx.conf"
  echo '{"version":1,"domains":{}}' > "$CONFIG_DIR/.shared-443"
  service_container(){ echo core-id; }; gateway_container(){ echo gateway-id; }; gateway_running(){ return 0; }
  docker(){
    case "$1" in
      inspect) if [[ "$*" = *Image* ]]; then echo sha256:old; else echo true; fi ;;
      exec) echo nginx-reload >> "$TRACE" ;;
      *) echo unexpected >> "$TRACE"; return 1 ;;
    esac
  }
  recover_service(){ cmp "$CONFIG_FILE" "$WORK_DIR/original.json"; echo core-recovered >> "$TRACE"; }
  break_shared_operation(){
    echo '{"inbounds":[{"tag":"bad"}]}' > "$CONFIG_FILE"
    echo changed > "$INFO_FILE"
    echo changed > "$COMPOSE_FILE"
    echo changed > "$CONFIG_DIR/gateway/nginx.conf"
    return 1
  }
  if shared_transaction break_shared_operation; then exit 1; fi
  cmp "$CONFIG_FILE" "$WORK_DIR/original.json"
  cmp "$COMPOSE_FILE" "$WORK_DIR/original-compose"
  [ "$(cat "$INFO_FILE")" = original-info ]
  [ "$(cat "$CONFIG_DIR/gateway/nginx.conf")" = original-nginx ]
  grep -q core-recovered "$TRACE"
  grep -q nginx-reload "$TRACE"
  ! grep -q unexpected "$TRACE"
)

shared_preflight_failure_is_non_disruptive() (
  fixture
  service_container(){ echo core-id; }; gateway_container(){ echo gateway-id; }; gateway_running(){ return 0; }
  docker(){
    if [ "$1" = inspect ]; then
      if [[ "$*" = *Image* ]]; then echo sha256:old; else echo true; fi
    else echo unexpected > "$TRACE"; return 1; fi
  }
  recover_service(){ echo unexpected > "$TRACE"; return 1; }
  if shared_transaction false; then exit 1; fi
  [ ! -f "$TRACE" ]
  cmp "$CONFIG_FILE" "$WORK_DIR/original.json"
)

shared_refuses_unmanaged_ports() (
  fixture
  compose(){ echo '{"services":{"sing-box":{}}}'; }
  gateway_running(){ return 1; }
  port_used(){ [ "$1" = 443 ]; }
  if gateway_preflight; then exit 1; fi
  [ ! -f "$CONFIG_DIR/.shared-443" ]
)

shared_delete_preserves_website() (
  fixture
  printf '%s\n' '{"inbounds":[{"tag":"node"},{"tag":"other"}]}' > "$CONFIG_FILE"
  printf '%s\n' '{"domains":{"node.test":{"kind":"vless","tag":"node","backend_port":22000,"website_upstream":"http://127.0.0.1:8080"},"other.test":{"kind":"anytls","tag":"other"}}}' > "$CONFIG_DIR/.shared-443"
  apply_config(){ mv "$1" "$CONFIG_FILE"; }
  gateway_apply(){ :; }; remove_info_by_tag(){ :; }
  shared_delete_node node
  jq -e '.inbounds | length == 1' "$CONFIG_FILE" >/dev/null
  jq -e '.domains["node.test"].kind == "website" and .domains["node.test"].tag == null and .domains["other.test"].tag == "other"' "$CONFIG_DIR/.shared-443" >/dev/null
)

creation_prints_current_node() (
  fixture
  local kind="$1" input expected
  prepare_runtime(){ :; }; ensure_singbox_image(){ :; }; port_used(){ return 1; }; tag_exists(){ return 1; }
  public_ip(){ echo 203.0.113.10; }; runtime_image(){ echo fixture; }; open_port(){ :; }
  docker(){ printf 'PrivateKey: PRIVATE_MUST_NOT_PRINT\nPublicKey: PUBLIC_FIXTURE\n'; }
  add_inbound(){ jq --argjson inbound "$1" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$CONFIG_FILE.next"; mv "$CONFIG_FILE.next" "$CONFIG_FILE"; }
  printf '\n==============================\n标签：unrelated\n密码：UNRELATED_MUST_NOT_PRINT\n==============================\n' >> "$INFO_FILE"
  case "$kind" in
    reality) input=$'\n5446\nnode-reality\nwww.microsoft.com'; expected='vless://' ;;
    hysteria2) input=$'\n8443\nnode-hysteria2\nfixture-password\n1\nbing.com'; expected='hysteria2://' ;;
    anytls) input=$'\n8444\nnode-anytls\nfixture-password\n1\nwww.microsoft.com'; expected='anytls://' ;;
    door) input=$'2080\nnode-door\nexample.com\n443\ntcp'; expected='example.com:443' ;;
  esac
  "add_$kind" <<< "$input" > "$WORK_DIR/output"
  grep -q "标签：node-$kind" "$WORK_DIR/output"
  grep -q "$expected" "$WORK_DIR/output"
  ! grep -q 'PRIVATE_MUST_NOT_PRINT\|UNRELATED_MUST_NOT_PRINT' "$WORK_DIR/output"
)

failed_creation_prints_no_node() (
  fixture
  prepare_runtime(){ :; }; ensure_singbox_image(){ :; }; port_used(){ return 1; }; tag_exists(){ return 1; }
  public_ip(){ echo 203.0.113.10; }; runtime_image(){ echo fixture; }
  docker(){ printf 'PrivateKey: PRIVATE_FIXTURE\nPublicKey: PUBLIC_FIXTURE\n'; }
  add_inbound(){ return 1; }
  if add_reality <<< $'\n5446\nfailed-node\nwww.microsoft.com' > "$WORK_DIR/output"; then exit 1; fi
  ! grep -q 'vless://\|本次节点配置' "$WORK_DIR/output"
  [ "$(cat "$INFO_FILE")" = original-info ]
)

for test in reject_candidate commit_candidate rollback_candidate rollback_on_disconnect \
  backup_failure backup_without_info regular_restart_keeps_container validate_running_image \
  protocol_specific_ports find_renamed_container recover_deleted_container restore_failure readiness_rejects_crash \
  backup_integrity_failure update_requires_backup failed_recovery_retains_evidence stop_replacement_before_recovery \
  shared_operation_rollback shared_preflight_failure_is_non_disruptive shared_refuses_unmanaged_ports shared_delete_preserves_website \
  failed_creation_prints_no_node; do
  run_test "$test"
done
for kind in reality hysteria2 anytls door; do run_test creation_prints_current_node "$kind"; done
for phase in pull validate replace; do run_test update_failure "$phase"; done
run_test restore_failure validate
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  run_test structured_image_switch
else
  printf 'SKIP structured_image_switch (Docker Compose CLI unavailable)\n'
fi
printf '%s regression tests passed\n' "$passed"
