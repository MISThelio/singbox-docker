#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/singbox-docker.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
passed=0
fixture(){
  WORK_DIR=$(mktemp -d "$TEST_ROOT/menu-XXXXXX")
  CONFIG_DIR="$WORK_DIR/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
  COMPOSE_FILE="$WORK_DIR/docker-compose.yml"; INFO_FILE="$WORK_DIR/nodes.txt"
  TRACE="$WORK_DIR/trace"; ATTEMPTS="$WORK_DIR/attempts"
  mkdir -p "$CONFIG_DIR"
  echo '{"inbounds":[]}' > "$CONFIG_FILE"
  echo '{"services":{"sing-box":{"image":"fixture"}}}' > "$COMPOSE_FILE"
  clear(){ :; }
  pause(){ echo pause >> "$TRACE"; }
  run_locked(){ "$@"; }
}
run_test(){ "$@"; passed=$((passed+1)); echo "PASS $1"; }

back_navigation_has_no_pause() (
  fixture
  local selection
  for selection in 1 3 8 9; do
    menu <<INPUT > "$WORK_DIR/output"
$selection
0
INPUT
  done
  menu <<'INPUT' > "$WORK_DIR/output"
1
5
0
0
INPUT
  [ ! -f "$TRACE" ]
)
actions_pause_once() (
  fixture
  show_version(){ echo version; }
  menu <<'INPUT' > "$WORK_DIR/output"
8
2
0
INPUT
  [ "$(cat "$TRACE")" = pause ]
)
unhandled_failure_stops_action_not_menu() (
  fixture
  failing(){ false; touch "$WORK_DIR/unsafe-continuation"; }
  run_menu_action failing > "$WORK_DIR/output"
  [ "$MENU_ACTION_STATUS" -eq 1 ]
  [ ! -f "$WORK_DIR/unsafe-continuation" ]
  [[ "$-" == *e* ]]
  menu <<'INPUT' > /dev/null
8
0
INPUT
)
explicit_exit_is_contained() (
  fixture
  failing(){ exit 27; }
  run_menu_action failing > "$WORK_DIR/output"
  [ "$MENU_ACTION_STATUS" -eq 27 ]
  grep -q '27' "$WORK_DIR/output"
)
retry_addition() (
  fixture
  add_reality(){
    echo attempt >> "$ATTEMPTS"
    if [ "$(wc -l < "$ATTEMPTS")" -eq 1 ]; then return 1; fi
    echo created
  }
  add_config_menu <<'INPUT' > "$WORK_DIR/output"
1
y
0
INPUT
  [ "$(wc -l < "$ATTEMPTS")" -eq 2 ]
  [ "$(cat "$TRACE")" = pause ]
  grep -q created "$WORK_DIR/output"
)
failure_returns_to_add_menu() (
  fixture
  add_reality(){ return 1; }
  add_hysteria2(){ touch "$WORK_DIR/second-protocol"; }
  add_config_menu <<'INPUT' > "$WORK_DIR/output"
1

2
0
INPUT
  [ -f "$WORK_DIR/second-protocol" ]
  [ "$(cat "$TRACE")" = pause ]
)
real_domain_failure_allows_retry() (
  fixture
  prepare_runtime(){ :; }
  shared_transaction(){ echo "$*" >> "$ATTEMPTS"; return 37; }
  add_config_menu <<'INPUT' > "$WORK_DIR/output"
2
wakisome.fun
y
other.test.example

0
INPUT
  [ "$(wc -l < "$ATTEMPTS")" -eq 2 ]
  grep -q wakisome.fun "$ATTEMPTS"; grep -q other.test.example "$ATTEMPTS"
  [ ! -f "$TRACE" ]
)
invalid_port_is_failure() (
  fixture
  prepare_runtime(){ :; }; ensure_singbox_image(){ :; }
  run_menu_action add_hysteria2 <<'INPUT' > "$WORK_DIR/output"

not-a-port
INPUT
  [ "$MENU_ACTION_STATUS" -ne 0 ]
)
occupied_port_is_failure() (
  fixture
  prepare_runtime(){ :; }; ensure_singbox_image(){ :; }; port_used(){ return 0; }
  run_menu_action add_reality <<'INPUT' > "$WORK_DIR/output"

443
INPUT
  [ "$MENU_ACTION_STATUS" -ne 0 ]
)
other_menu_errors_are_contained() (
  fixture
  show_version(){ false; touch "$WORK_DIR/unsafe-version"; }
  update_menu <<'INPUT' > "$WORK_DIR/output"
2
0
INPUT
  [ ! -f "$WORK_DIR/unsafe-version" ]
  [ "$(cat "$TRACE")" = pause ]
)
initialization_failure_does_not_start_service() (
  fixture
  install_base(){ return 4; }
  start_service(){ touch "$WORK_DIR/unsafe-start"; }
  run_menu_action initialize_and_start > "$WORK_DIR/output"
  [ "$MENU_ACTION_STATUS" -eq 4 ]
  [ ! -f "$WORK_DIR/unsafe-start" ]
)
port_conflict_is_read_only_and_explained() (
  fixture
  echo '{"inbounds":[{"type":"vless","tag":"legacy-443","listen_port":443,"uuid":"private-value"}]}' > "$CONFIG_FILE"
  compose(){ cat "$COMPOSE_FILE"; }; gateway_running(){ return 1; }
  port_used(){ [ "$1" = 443 ]; }
  ss(){ echo 'LISTEN nginx'; }
  docker(){ touch "$WORK_DIR/unsafe-docker-call"; return 1; }
  run_menu_action gateway_preflight > "$WORK_DIR/output"
  [ "$MENU_ACTION_STATUS" -eq 1 ]
  grep -q nginx "$WORK_DIR/output"
  grep -q legacy-443 "$WORK_DIR/output"
  grep -q '证书迁移只修改续期方式' "$WORK_DIR/output"
  ! grep -q private-value "$WORK_DIR/output"
  [ ! -f "$WORK_DIR/unsafe-docker-call" ]
)
empty_migration_does_not_enable_gateway() (
  fixture
  certificate_inventory(){ echo '[]'; }
  gateway_initialize(){ touch "$WORK_DIR/unsafe-gateway"; }
  shared_migrate_certificates > "$WORK_DIR/output"
  [ ! -f "$WORK_DIR/unsafe-gateway" ]
)
certificate_menu_and_private_summary() (
  fixture
  prepare_runtime(){ :; }
  certificate_inventory(){ echo '[{"name":"old.test.example","params":{"authenticator":"webroot","account":"secret-account","webroot_path":"/var/www/acme,"},"webroot_map":{}}]'; }
  shared_gateway_menu <<'INPUT' > "$WORK_DIR/output"
6
0
INPUT
  grep -q old.test.example "$WORK_DIR/output"
  grep -q webroot "$WORK_DIR/output"
  ! grep -q secret-account "$WORK_DIR/output"
  [ "$(cat "$TRACE")" = pause ]
)
eof_returns_from_submenus() (
  fixture
  add_config_menu </dev/null > /dev/null
  config_menu </dev/null > /dev/null
  update_menu </dev/null > /dev/null
  system_menu </dev/null > /dev/null
  shared_gateway_menu </dev/null > /dev/null
)
cli_navigation_and_eof() (
  fixture
  timeout 5 bash -c 'source "$1"; check_root(){ :; }; main' bash "$ROOT/singbox-docker.sh" <<'INPUT' > "$WORK_DIR/output"
8
0
1
5
0
0
0
INPUT
  ! grep -q '按回车继续' "$WORK_DIR/output"
  timeout 5 bash -c 'source "$1"; check_root(){ :; }; main' bash "$ROOT/singbox-docker.sh" </dev/null > /dev/null
)

delete_fixture(){
  fixture
  echo '{"inbounds":[{"tag":"reality-443","type":"vless","listen_port":443,"users":[{"uuid":"SECRET_UUID"}]},{"tag":"hy2-443","type":"hysteria2","listen_port":443}]}' > "$CONFIG_FILE"
  prepare_runtime(){ :; }
  ensure_singbox_image(){ echo image >> "$TRACE"; }
  backup_config(){ echo backup >> "$TRACE"; }
  apply_config(){ mv "$1" "$CONFIG_FILE"; }
  remove_info_by_tag(){ printf 'info:%s\n' "$1" >> "$TRACE"; }
}
numbered_delete_selects_only_one_node() (
  delete_fixture
  delete_inbound <<'INPUT' > "$WORK_DIR/output"
1
y
INPUT
  jq -e '.inbounds | length == 1 and .[0].tag == "hy2-443"' "$CONFIG_FILE" >/dev/null
  grep -q '1. reality-443 | vless | TCP 443' "$WORK_DIR/output"
  grep -q '2. hy2-443 | hysteria2 | UDP 443' "$WORK_DIR/output"
  ! grep -q SECRET_UUID "$WORK_DIR/output"
  grep -q '^info:reality-443$' "$TRACE"
)
numbered_delete_cancel_is_read_only() (
  delete_fixture
  local input
  for input in 0 $'1\nn' $'1\n'; do
    delete_inbound <<< "$input" > "$WORK_DIR/output"
    jq -e '.inbounds | length == 2' "$CONFIG_FILE" >/dev/null
    [ ! -f "$TRACE" ]
  done
)
numbered_delete_reprompts_invalid_numbers() (
  delete_fixture
  delete_inbound <<'INPUT' > "$WORK_DIR/output"
reality-443
-1
3
99999999999999999999999
02
y
INPUT
  jq -e '.inbounds | length == 1 and .[0].tag == "reality-443"' "$CONFIG_FILE" >/dev/null
  [ "$(grep -c '请输入 1-2' "$WORK_DIR/output")" -eq 4 ]
  grep -q '^info:hy2-443$' "$TRACE"
)
numbered_delete_empty_and_eof() (
  delete_fixture
  delete_inbound </dev/null > "$WORK_DIR/output"
  [ ! -f "$TRACE" ]
  echo '{"inbounds":[]}' > "$CONFIG_FILE"
  delete_inbound </dev/null > "$WORK_DIR/output"
  grep -q '当前没有入站节点' "$WORK_DIR/output"
  [ ! -f "$TRACE" ]
)
numbered_delete_shared_route_mapping() (
  delete_fixture
  echo '{"domains":{"node.test.example":{"kind":"vless","tag":"reality-443","backend_port":443}}}' > "$CONFIG_DIR/.shared-443"
  shared_transaction(){ "$@"; }
  shared_delete_node(){ printf 'shared:%s\n' "$1" >> "$TRACE"; }
  delete_inbound <<'INPUT' > "$WORK_DIR/output"
1
y
INPUT
  grep -q node.test.example "$WORK_DIR/output"
  grep -q '^shared:reality-443$' "$TRACE"
  ! grep -q '^info:' "$TRACE"
)
numbered_delete_rejects_duplicate_tags() (
  delete_fixture
  jq '.inbounds[1].tag = "reality-443"' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  run_menu_action delete_inbound <<'INPUT' > "$WORK_DIR/output"
1
y
INPUT
  [ "$MENU_ACTION_STATUS" -ne 0 ]; [ ! -f "$TRACE" ]
  jq -e '.inbounds | length == 2' "$CONFIG_FILE" >/dev/null
)
numbered_delete_detects_stale_selection() (
  delete_fixture
  ensure_singbox_image(){
    jq '.inbounds += [{tag:"external-node",type:"vless",listen_port:5446}]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  }
  run_menu_action delete_inbound <<'INPUT' > "$WORK_DIR/output"
1
y
INPUT
  [ "$MENU_ACTION_STATUS" -ne 0 ]; [ ! -f "$TRACE" ]
  jq -e '.inbounds | length == 3 and .[0].tag == "reality-443"' "$CONFIG_FILE" >/dev/null
)
numbered_delete_handles_numeric_tag() (
  delete_fixture
  jq '.inbounds[0].tag = "2"' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  delete_inbound <<'INPUT' > "$WORK_DIR/output"
1
y
INPUT
  jq -e '.inbounds | length == 1 and .[0].tag == "hy2-443"' "$CONFIG_FILE" >/dev/null
  grep -q '^info:2$' "$TRACE"
)
numbered_delete_backup_failure_is_safe() (
  delete_fixture
  backup_config(){ return 1; }
  apply_config(){ touch "$WORK_DIR/unsafe-apply"; }
  run_menu_action delete_inbound <<'INPUT' > "$WORK_DIR/output"
1
y
INPUT
  [ "$MENU_ACTION_STATUS" -ne 0 ]; [ ! -f "$WORK_DIR/unsafe-apply" ]
  jq -e '.inbounds | length == 2' "$CONFIG_FILE" >/dev/null
  ! grep -q '^info:' "$TRACE"
)
numbered_delete_apply_failure_preserves_info() (
  delete_fixture
  apply_config(){ return 1; }
  run_menu_action delete_inbound <<'INPUT' > "$WORK_DIR/output"
1
y
INPUT
  [ "$MENU_ACTION_STATUS" -ne 0 ]
  jq -e '.inbounds | length == 2' "$CONFIG_FILE" >/dev/null
  ! grep -q '^info:' "$TRACE"
)

for test in back_navigation_has_no_pause actions_pause_once unhandled_failure_stops_action_not_menu \
  explicit_exit_is_contained retry_addition failure_returns_to_add_menu real_domain_failure_allows_retry \
  invalid_port_is_failure occupied_port_is_failure other_menu_errors_are_contained \
  initialization_failure_does_not_start_service port_conflict_is_read_only_and_explained \
  empty_migration_does_not_enable_gateway certificate_menu_and_private_summary eof_returns_from_submenus \
  cli_navigation_and_eof numbered_delete_selects_only_one_node numbered_delete_cancel_is_read_only \
  numbered_delete_reprompts_invalid_numbers numbered_delete_empty_and_eof numbered_delete_shared_route_mapping \
  numbered_delete_rejects_duplicate_tags numbered_delete_detects_stale_selection numbered_delete_handles_numeric_tag \
  numbered_delete_backup_failure_is_safe numbered_delete_apply_failure_preserves_info; do
  run_test "$test"
done
echo "$passed menu interaction tests passed"
