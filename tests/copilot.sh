#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d -t mana-copilot-tests)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export CALLS="$SANDBOX/calls"
STATE="$HOME/Library/Application Support/mana/copilot-azure"
COMMAND="$REPO_DIR/libexec/mana/copilot"
TENANT=473f9dda-3802-4f8b-a945-da5db1e460b4
CLIENT=11111111-2222-4333-8444-555555555555
export TENANT CLIENT
mkdir -p "$HOME/.azure"
printf 'untouched\n' >"$HOME/.azure/sentinel"
export AZURE_CONFIG_DIR="$HOME/.azure"

az() {
    [[ "$AZURE_CONFIG_DIR" = "$HOME/Library/Application Support/mana/copilot-azure/azure" ]] ||
        { printf 'FAIL attempted to use the normal Azure profile\n' >&2; return 98; }
    printf '%s|%s\n' "${AZURE_CONFIG_DIR:-UNSET}" "$*" >>"$CALLS"
    case "$1 $2" in
        'login --service-principal') return "${LOGIN_EXIT:-0}" ;;
        'account show')
            printf '{"tenantId":"%s","subscriptionId":"%s","clientId":"%s","type":"%s"}\n' \
                "$TENANT" "$TENANT" "$CLIENT" "${ACCOUNT_TYPE:-servicePrincipal}"
            ;;
        *) printf 'Unexpected Azure command\n' >&2; return 99 ;;
    esac
}
open() {
    printf 'open|%s\n' "$*" >>"$CALLS"
    [ -z "${OPEN_WARNING:-}" ] || printf '%s\n' "$OPEN_WARNING" >&2
    return "${OPEN_EXIT:-0}"
}
osascript() {
    case "${APP_RUNNING:-1}" in
        0) printf 'true\n' ;;
        1) printf 'false\n' ;;
        *) return 2 ;;
    esac
}
export -f az open osascript

/bin/bash "$COMMAND" init >"$SANDBOX/init-output"
before="$(shasum -a 256 "$STATE/identity.pem")"
/bin/bash "$COMMAND" init >/dev/null
[[ "$(shasum -a 256 "$STATE/identity.pem")" = "$before" ]]
[[ "$(<"$STATE/device-id")" = mac-* ]]
[[ "$(stat -f '%Lp' "$STATE/identity.pem")" = 600 ]]
! grep -q 'PRIVATE KEY' "$STATE/certificate.pem"
[[ ! -e "$CALLS" ]]
printf 'PASS init creates private per-device credentials without Azure calls or key replacement\n'

export LOGIN_EXIT=42
if /bin/bash "$COMMAND" login "$TENANT" "$CLIENT" >/dev/null 2>&1; then
    printf 'FAIL login failure was swallowed\n' >&2; exit 1
fi
[[ ! -e "$STATE/identity.json" ]]
unset LOGIN_EXIT
export ACCOUNT_TYPE=user
if /bin/bash "$COMMAND" login "$TENANT" "$CLIENT" >"$SANDBOX/output" 2>&1; then
    printf 'FAIL accepted a user/admin identity\n' >&2; exit 1
fi
grep -q 'expected service principal' "$SANDBOX/output"
[[ ! -e "$STATE/identity.json" ]]
unset ACCOUNT_TYPE
/bin/bash "$COMMAND" login "$TENANT" "$CLIENT"
/bin/bash "$COMMAND" status >"$SANDBOX/status"
grep -q "$CLIENT" "$SANDBOX/status"
! grep -q '^UNSET|' "$CALLS"
[[ "$(<"$HOME/.azure/sentinel")" = untouched ]]
[[ "$AZURE_CONFIG_DIR" = "$HOME/.azure" ]]
printf 'PASS login/status isolate Azure configuration and reject user identities\n'

before="$(wc -l <"$CALLS")"
if /bin/bash "$COMMAND" login invalid "$CLIENT" >"$SANDBOX/output" 2>&1; then
    printf 'FAIL accepted malformed identity arguments\n' >&2; exit 1
fi
[[ "$(wc -l <"$CALLS")" = "$before" ]]
mv "$STATE/azure" "$STATE/azure-saved"
ln -s "$HOME/.azure" "$STATE/azure"
if /bin/bash "$COMMAND" status >"$SANDBOX/output" 2>&1; then
    printf 'FAIL followed a profile symlink into the admin cache\n' >&2; exit 1
fi
grep -q 'symlinked Azure profile' "$SANDBOX/output"
rm "$STATE/azure"
mv "$STATE/azure-saved" "$STATE/azure"
[[ "$(wc -l <"$CALLS")" = "$before" ]]
printf 'PASS invalid inputs and symlinked profiles fail before Azure commands\n'

chmod 644 "$STATE/identity.pem"
if /bin/bash "$COMMAND" status >"$SANDBOX/output" 2>&1; then
    printf 'FAIL accepted a readable private key\n' >&2; exit 1
fi
grep -q 'mode 600' "$SANDBOX/output"
chmod 600 "$STATE/identity.pem"

export APP_RUNNING=0
if /bin/bash "$COMMAND" launch >"$SANDBOX/output" 2>&1; then
    printf 'FAIL launch accepted an already-running app\n' >&2; exit 1
fi
grep -q 'Quit GitHub Copilot first' "$SANDBOX/output"
! grep -q '^open|' "$CALLS"
unset APP_RUNNING
export APP_RUNNING=2
if /bin/bash "$COMMAND" launch >"$SANDBOX/output" 2>&1; then
    printf 'FAIL ignored process inspection failure\n' >&2; exit 1
fi
grep -q 'Could not determine' "$SANDBOX/output"
unset APP_RUNNING
/bin/bash "$COMMAND" launch
grep -Fq "open|--env AZURE_CONFIG_DIR=$STATE/azure -a /Applications/GitHub Copilot.app" "$CALLS"
printf 'PASS launch refuses a running app and passes only the isolated profile\n'

export OPEN_EXIT=42
if /bin/bash "$COMMAND" launch >/dev/null 2>&1; then
    printf 'FAIL app launch failure was swallowed\n' >&2; exit 1
fi
unset OPEN_EXIT
printf 'PASS app launch failures propagate\n'

export OPEN_WARNING='Application was already running; additional environment variables could not be set.'
if /bin/bash "$COMMAND" launch >"$SANDBOX/output" 2>&1; then
    printf 'FAIL accepted a successful open exit with an ignored environment\n' >&2; exit 1
fi
grep -q 'isolated startup was not confirmed' "$SANDBOX/output"
unset OPEN_WARNING
printf 'PASS app-launch races and environment warnings fail closed\n'

export CLIENT=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
if /bin/bash "$COMMAND" status >"$SANDBOX/output" 2>&1; then
    printf 'FAIL accepted a different service principal\n' >&2; exit 1
fi
grep -q 'does not match' "$SANDBOX/output"
printf 'PASS stale or changed identity fails closed\n'
