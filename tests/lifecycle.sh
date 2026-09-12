#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d -t mana-tests)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.omlx/bin"
ln -s /usr/bin/true "$HOME/.omlx/bin/omlx"

. "$REPO_DIR/libexec/mana/bootstrap"
[[ "$(container_version 'container CLI version 1.3.1 (build: release, commit: a9a62e2)')" == 1.3.1 ]]
[[ "$(container_version 'container version 0.4.0')" == 0.4.0 ]]
[[ "$(container_version 'container CLI version v1.4.0-rc.1+build.2')" == 1.4.0-rc.1+build.2 ]]
for invalid in 'container CLI version unknown (commit: a9a62e2)' 'container CLI version 1.3.1garbage' ''; do
    if container_version "$invalid" >/dev/null; then
        printf 'FAIL bootstrap accepted an invalid container version\n' >&2; exit 1
    fi
done
printf 'PASS bootstrap parses release versions and rejects unknown formats\n'

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

export VERSION_CALLS="$SANDBOX/version-calls"
container() {
    printf '%s\n' "$*" >> "$VERSION_CALLS"
    case "$1" in
        --version) printf 'container CLI version 1.2.3\n' ;;
        list) printf '%s\n' "$CONTAINER_JSON" ;;
        *) printf 'Unexpected version side effect: %s\n' "$*" >&2; return 99 ;;
    esac
}
brew() {
    case "$*" in
        --version) printf 'Homebrew 5.0.0\n' ;;
        'list --versions') printf 'example-app 2.0\n' ;;
        *) return 99 ;;
    esac
}
nix-store() {
    case "$3" in
        /etc/profiles/per-user/*) printf '/nix/store/abc-home-manager-path\n' ;;
        *-home-manager-path) printf '/nix/store/abc-jq-1.8.1-bin\n/nix/store/xyz-jq-1.8.1-man\n/nix/store/def-uv-0.9.0\n' ;;
        /run/current-system/sw) return 0 ;;
        *) return 99 ;;
    esac
}
export -f container brew nix-store
export CONTAINER_JSON='[{"configuration":{"id":"hermes-agent"},"status":{"state":"stopped"}}]'
output="$(/bin/bash "$REPO_DIR/libexec/mana/version")"
[[ "$output" == *'container CLI version 1.2.3'* ]]
[[ "$output" == *'example-app 2.0'* ]]
[[ "$output" == *'jq-1.8.1'* ]]
[[ "$(printf '%s\n' "$output" | grep -c 'jq-1.8.1')" == 1 ]]
[[ "$output" == *'stopped; tool versions unavailable'* ]]
[[ "$(<"$VERSION_CALLS")" == $'--version\nlist --all --format json' ]]
printf 'PASS version inventories installed packages without starting containers\n'
export CONTAINER_JSON='not-json'
output="$(/bin/bash "$REPO_DIR/libexec/mana/version")"
[[ "$output" == *'invalid container inventory'* ]]
printf 'PASS version tolerates unavailable metadata\n'

container() {
    printf '%s\n' "$*" >> "$VERSION_CALLS"
    case "$*" in
        --version) printf 'container CLI version 1.2.3\n' ;;
        'list --all --format json') printf '[{"configuration":{"id":"hermes-agent"},"status":"running"}]\n' ;;
        'exec hermes-agent /opt/hermes/.venv/bin/python --version') printf 'Python 3.13.5\n' ;;
        'exec hermes-agent node --version') printf 'v26.5.1\n' ;;
        'exec hermes-agent npm --version') printf '11.17.0\n' ;;
        'exec hermes-agent /opt/hermes/.venv/bin/pip list --format json --disable-pip-version-check')
            printf '[{"name":"hermes-agent","version":"0.20.6"},{"name":"searxng","version":"2026.8.29"},{"name":"hf-xet","version":"1.5.1"}]\n' ;;
        'exec hermes-agent npm list --global --depth=0 --json')
            printf '{"dependencies":{"camofox-browser":{"version":"2.4.7"}}}\n' ;;
        *) printf 'Unexpected version side effect: %s\n' "$*" >&2; return 99 ;;
    esac
}
export -f container
output="$(/bin/bash "$REPO_DIR/bin/mana" version)"
[[ "$output" == *'hermes-agent  0.20.6'* ]]
[[ "$output" == *'camofox-browser  2.4.7'* ]]
[[ "$output" == *'searxng  2026.8.29'* ]]
[[ "$output" == *'hf-xet  1.5.1'* ]]
if grep -Eq '(^| )(start|stop|restart|run|install|update)( |$)' "$VERSION_CALLS"; then
    printf 'FAIL version changed service state\n' >&2; exit 1
fi
printf 'PASS version reads running container tool metadata\n'
if /bin/bash "$REPO_DIR/bin/mana" version unexpected >"$SANDBOX/output" 2>&1; then
    printf 'FAIL version accepted an invalid argument\n' >&2; exit 1
fi
printf 'PASS version rejects invalid arguments\n'

commands="$(/bin/bash "$REPO_DIR/bin/mana" help | awk '
    /^Commands:$/ { in_commands=1; next }
    in_commands && /^$/ { exit }
    in_commands { print $1 }
')"
for command in $commands; do
    help="$(/bin/bash "$REPO_DIR/bin/mana" help "$command")"
    [[ "$help" == *'Usage:'* ]]
    [[ "$help" == "$(/bin/bash "$REPO_DIR/bin/mana" "$command" --help)" ]]
done
help="$(/bin/bash "$REPO_DIR/bin/mana" help hermes)"
[[ "$help" == *'logs       tail -f container logs'* ]]
printf 'PASS every public command has consistent complete help\n'

perl - "$REPO_DIR/README.md" "$REPO_DIR"/docs/*.md "$REPO_DIR/modelops/README.md" <<'PERL'
use strict;
use warnings;
use File::Basename qw(dirname);
my $failed = 0;
for my $file (@ARGV) {
    open my $handle, '<', $file or die "$file: $!\n";
    local $/;
    my $text = <$handle>;
    while ($text =~ /\[[^\]]+\]\(([^)]+)\)/g) {
        my $path = $1;
        next if $path =~ m{^(?:[a-z]+:|#)}i;
        $path =~ s/#.*//;
        $path =~ s/%([0-9a-f]{2})/chr(hex($1))/egi;
        unless (-e dirname($file) . '/' . $path) {
            warn "$file: missing linked file $path\n";
            $failed = 1;
        }
    }
}
exit $failed;
PERL
printf 'PASS local documentation file links resolve\n'