#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d -t mana-tests)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.omlx/bin"
ln -s /usr/bin/true "$HOME/.omlx/bin/omlx"

pgrep() { return 1; }
lsof() { return 1; }
open() { printf 'mock app launch\n'; }
export -f pgrep lsof open

for action in start restart; do
    output="$(/bin/bash "$REPO_DIR/libexec/mana/omlx" "$action")"
    [[ "$output" == *'mock app launch'* ]]
    printf 'PASS omlx %s with no app or listener\n' "$action"
done
output="$(/bin/bash "$REPO_DIR/libexec/mana/omlx" stop)"
[[ "$output" == 'oMLX stopped' ]]
printf 'PASS omlx stop is idempotent\n'

mkdir -p "$SANDBOX/hermes"
cp "$REPO_DIR/hermes/run.sh" "$SANDBOX/hermes/run.sh"
touch "$SANDBOX/hermes/config.yaml"

container() {
    case "$1 $2" in
        'system status') printf 'status running\n' ;;
        'list --all') printf '[{"configuration":{"id":"hermes-agent"},"status":{"state":"stopped"}}]\n' ;;
        'image inspect') return 0 ;;
        'volume list') printf 'hermes-data\n' ;;
        'start hermes-agent') printf 'mock start failure\n' >&2; return 42 ;;
        *) printf 'Unexpected container operation: %s\n' "$*" >&2; return 99 ;;
    esac
}
export -f container
if output="$(/bin/bash "$SANDBOX/hermes/run.sh" up 2>&1)"; then
    printf 'FAIL Hermes swallowed start failure\n' >&2
    exit 1
fi
[[ "$output" == *'mock start failure'* ]]
[[ "$output" != *'Dashboard:'* ]]
printf 'PASS Hermes propagates start failures\n'

export CALLS="$SANDBOX/calls"
container() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$1 $2" in
        'list --all') printf '[{"configuration":{"id":"worker"},"status":{"state":"running"}},{"configuration":{"id":"idle"},"status":"stopped"}]\n' ;;
        'system stop'|'system start'|'start worker') return 0 ;;
        *) printf 'Unexpected container operation: %s\n' "$*" >&2; return 99 ;;
    esac
}
export -f container
if /bin/bash "$REPO_DIR/libexec/mana/services" stop container </dev/null >"$SANDBOX/output" 2>&1; then
    printf 'FAIL runtime stop accepted missing confirmation\n' >&2; exit 1
fi
[ ! -e "$CALLS" ]
printf 'PASS runtime stop requires confirmation\n'
/bin/bash "$REPO_DIR/libexec/mana/services" restart container --yes
expected=$'list --all --format json\nsystem stop\nsystem start\nstart worker'
[[ "$(<"$CALLS")" == "$expected" ]]
printf 'PASS runtime restart restores only running containers\n'
if /bin/bash "$REPO_DIR/libexec/mana/services" start unknown >"$SANDBOX/output" 2>&1; then
    printf 'FAIL unknown service accepted\n' >&2; exit 1
fi
printf 'PASS unknown services are rejected\n'

if /bin/bash "$REPO_DIR/libexec/mana/services" start omlx --yes >"$SANDBOX/output" 2>&1; then
    printf 'FAIL invalid confirmation flag accepted\n' >&2; exit 1
fi
grep -q -- '--yes is only valid' "$SANDBOX/output"
printf 'PASS invalid service flags are rejected\n'
before="$(<"$CALLS")"
if /bin/bash "$REPO_DIR/libexec/mana/doctor" --fix </dev/null >"$SANDBOX/output" 2>&1; then
    printf 'FAIL doctor repair accepted missing confirmation\n' >&2; exit 1
fi
[[ "$(<"$CALLS")" == "$before" ]]
grep -q 'Warning: repairs' "$SANDBOX/output"
printf 'PASS doctor warns and requires repair consent\n'

curl() { printf '%s' "${HTTP_CODE:-000}"; }
export -f curl
if /bin/bash "$REPO_DIR/libexec/mana/omlx" status >"$SANDBOX/output" 2>&1; then
    printf 'FAIL oMLX status accepted an unavailable API\n' >&2; exit 1
fi
export HTTP_CODE=200
/bin/bash "$REPO_DIR/libexec/mana/omlx" status >"$SANDBOX/output" 2>&1
printf 'PASS oMLX status reflects API health\n'

container() {
    case "$1 $2" in
        'list --all') printf '%s\n' "$CONTAINER_JSON" ;;
        'exec hermes-agent') shift 2; "$@" ;;
        *) printf 'Unexpected container operation: %s\n' "$*" >&2; return 99 ;;
    esac
}
curl() {
    case "$*" in
        *9119*) printf '401' ;;
        *8080*) printf '200' ;;
        *9377*) printf '%s' "${BROWSER_CODE:-200}" ;;
        *) return 99 ;;
    esac
}
export -f container curl
for state in '"running"' '{"state":"running"}'; do
    export CONTAINER_JSON="[{\"configuration\":{\"id\":\"hermes-agent\"},\"status\":$state}]"
    /bin/bash "$SANDBOX/hermes/run.sh" status >"$SANDBOX/output" 2>&1
    grep -q 'dashboard (HTTP 401)' "$SANDBOX/output"
done
printf 'PASS both container state schemas and authenticated dashboard\n'
export BROWSER_CODE=500
if /bin/bash "$SANDBOX/hermes/run.sh" health >"$SANDBOX/output" 2>&1; then
    printf 'FAIL health accepted a broken browser service\n' >&2; exit 1
fi
grep -q 'fail camofox' "$SANDBOX/output"
printf 'PASS degraded endpoint fails health checks\n'