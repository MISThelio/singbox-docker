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

for test in back_navigation_has_no_pause actions_pause_once unhandled_failure_stops_action_not_menu \
  explicit_exit_is_contained retry_addition failure_returns_to_add_menu real_domain_failure_allows_retry \
  invalid_port_is_failure occupied_port_is_failure other_menu_errors_are_contained \
  initialization_failure_does_not_start_service port_conflict_is_read_only_and_explained \
  empty_migration_does_not_enable_gateway certificate_menu_and_private_summary eof_returns_from_submenus \
  cli_navigation_and_eof; do
  run_test "$test"
done
echo "$passed menu interaction tests passed"
