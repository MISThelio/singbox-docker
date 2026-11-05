#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/singbox-docker.sh"
WORK_DIR=$(mktemp -d)
CONFIG_DIR="$WORK_DIR/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"; INFO_FILE="$WORK_DIR/nodes.txt"
BACKUP_DIR="$WORK_DIR/backup"
export COMPOSE_PROJECT_NAME="sb-review-$BASHPID-$RANDOM"
trap 'compose down --remove-orphans >/dev/null 2>&1; rm -rf "$WORK_DIR"' EXIT
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$CONFIG_FILE"
printf '%s\n' '{"services":{"sing-box":{"image":"alpine:3.22","command":["sleep","300"]}}}' > "$COMPOSE_FILE"
# This test exercises real container replacement; protocol validation has separate tests.
check_config(){ return 0; }
prepare_runtime(){ return 0; }
# compose is imported above and intentionally wrapped later in this test.
# shellcheck disable=SC2218
compose up -d sing-box
original=$(service_container)
old_image=$(runtime_image)
restart_service
[ "$(service_container)" = "$original" ]
printf 'PASS real restart preserves container ID\n'
docker rename "$original" "$COMPOSE_PROJECT_NAME-renamed" >/dev/null
[ "$(service_container)" = "$original" ]
# shellcheck disable=SC2218
compose logs --tail 1 sing-box >/dev/null
printf 'PASS renamed container discovery and logs\n'

# Skip registry access, while using real Compose for every lifecycle operation.
eval "$(declare -f compose | sed '1s/compose/real_compose/')"
compose(){
  if [ "$1" = pull ]; then return 0; fi
  real_compose "$@"
}
eval "$(declare -f sync_compose_image | sed '1s/sync_compose_image/real_sync_compose_image/')"
sync_compose_image(){
  real_sync_compose_image "$@" || return 1
  if [ "${1:-$SING_BOX_IMAGE}" = alpine:3.22 ]; then
    jq '.services["sing-box"].command = ["sh", "-c", "exit 42"]' "$COMPOSE_FILE" > "$WORK_DIR/next-compose"
    mv "$WORK_DIR/next-compose" "$COMPOSE_FILE"
  fi
}
SING_BOX_IMAGE=alpine:3.22
if update_singbox_image; then
  printf 'FAIL broken replacement was accepted\n' >&2
  exit 1
fi
recovered=$(service_container)
[ -n "$recovered" ]
[ "$(docker inspect --format '{{.State.Running}}' "$recovered")" = true ]
[ "$(runtime_image)" = "$old_image" ]
[ "$(compose_image)" = "$old_image" ]
jq -e '.services["sing-box"].command == ["sleep","300"]' "$COMPOSE_FILE" >/dev/null
printf 'PASS failed replacement restores command and original image ID\n'
