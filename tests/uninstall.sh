#!/bin/bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d -t mana-uninstall-tests)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export REPO_DIR="$SANDBOX/repo"
export CALLS="$SANDBOX/calls" ACTIVE_SYSTEM="$SANDBOX/active"
mkdir -p "$HOME/.ssh" "$REPO_DIR/libexec/mana" "$REPO_DIR/hermes"
mkdir -p "$HOME/.config/git"
cp "$SOURCE_DIR/libexec/mana/uninstall" "$SOURCE_DIR/libexec/mana/installation-state" "$REPO_DIR/libexec/mana/"
cp "$SOURCE_DIR/darwin.nix" "$REPO_DIR/"
printf 'original SSH configuration\n' > "$HOME/.ssh/config"
printf 'original Git identity\n' > "$HOME/.gitconfig"
printf 'original managed Git configuration\n' > "$SANDBOX/original-git"
printf 'later managed Git configuration\n' > "$SANDBOX/later-git"
ln -s "$SANDBOX/original-git" "$HOME/.config/git/config"
printf '{\n  username = "test";\n  hostname = "test";\n}\n' > "$REPO_DIR/local.nix"
printf 'pre-existing workspace\n' > "$REPO_DIR/hermes/workspace"
: > "$CALLS"

# All host service/package commands are intercepted. No credentials or
# application contents from the real home directory are accessed.
readlink() {
    case "$1" in
        /nix/var/nix/profiles/system) return 1 ;;
        /run/current-system)
            if [ -f "$ACTIVE_SYSTEM" ]; then printf '/nix/store/test-mana-system\n'; else return 1; fi ;;
        *) /usr/bin/readlink "$@" ;;
    esac
}
brew() {
    case "$*" in
        'list --cask -1') printf 'iina\niterm2\n' ;;
        'list --formula -1') printf 'unrelated-formula\n' ;;
        'info --json=v2 --cask iina') printf '{"casks":[{"artifacts":[{"app":["IINA.app"]}]}]}\n' ;;
        'info --json=v2 --cask iterm2') printf '{"casks":[{"artifacts":[{"app":["iTerm.app"]}]}]}\n' ;;
        'uninstall --cask iina'|'uninstall --cask iterm2') printf 'brew %s\n' "$*" >> "$CALLS" ;;
        *) printf 'Unexpected brew operation: %s\n' "$*" >&2; return 99 ;;
    esac
}
container() {
    case "$*" in
        'list --all --format json') printf '%s\n' "${CONTAINERS:-[]}" ;;
        'image inspect hermes-toolbox:latest') return 1 ;;
        'volume list --quiet') printf 'hermes-data\n' ;;
        'volume delete hermes-data') printf 'container %s\n' "$*" >> "$CALLS"; return "${DELETE_STATUS:-0}" ;;
        'stop hermes-agent'|'delete hermes-agent') printf 'container %s\n' "$*" >> "$CALLS" ;;
        *) printf 'Unexpected container operation: %s\n' "$*" >&2; return 99 ;;
    esac
}
sudo() {
    printf 'sudo %s\n' "$*" >> "$CALLS"
    if [ "${FAIL_ACTIVATION:-0}" -eq 1 ]; then return 42; fi
    if [[ "$*" == *'darwin-rebuild activate'* ]]; then
        /bin/rm -f "$SANDBOX/bin/jq"
    fi
    if [ "$1" = darwin-uninstaller ]; then
        /bin/rm -f "$ACTIVE_SYSTEM" "$HOME/Library/LaunchAgents/org.nix-community.home.mana-hermes.plist"
    fi
}
nix() {
    printf 'nix %s\n' "$*" >> "$CALLS"
    [ "$1" = build ] || return 99
    printf '%s\n' "$SANDBOX/cleanup"
}
darwin-uninstaller() { printf 'Unexpected direct uninstaller execution\n' >&2; return 99; }
export SANDBOX
export -f readlink brew container sudo nix darwin-uninstaller

. "$REPO_DIR/libexec/mana/installation-state"
mana_capture_baseline
state="$(mana_state_dir)"
[[ "$(cat "$state/baseline")" == recorded ]]
[[ "$(cat "$state/nix.before")" == present ]]
[[ "$(cat "$state/brew.before")" == present ]]
[[ "$(cat "$state/container.before")" == present ]]
[[ "$(cat "$state/home/.ssh/config")" == 'original SSH configuration' ]]
printf 'edited SSH configuration\n' > "$HOME/.ssh/config"
ln -sf "$SANDBOX/later-git" "$HOME/.config/git/config"
mana_capture_baseline
[[ "$(cat "$state/home/.ssh/config")" == 'original SSH configuration' ]]
[[ "$(stat -f '%Lp' "$state" 2>/dev/null || stat -c '%a' "$state")" == 700 ]]
printf 'PASS baseline is private and reruns preserve original configuration\n'

help="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" help)"
for args in '' '--help' '-h'; do
    output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" $args </dev/null)"
    [[ "$output" == "$help" ]]
done
[[ "$help" == *'Warnings:'* ]]
[[ "$help" == *'hermes'* && "$help" == *'omlx'* && "$help" == *'container'* && "$help" == *'all'* ]]
[[ "$(/bin/bash "$SOURCE_DIR/bin/mana" uninstall help)" == "$help" ]]
[ ! -s "$CALLS" ]
[[ "$(cat "$HOME/.ssh/config")" == 'edited SSH configuration' ]]
printf 'PASS bare uninstall and help aliases only explain choices and warnings\n'

for args in '--keep-models' 'all --keep-models' 'hermes --purge --keep-config' 'unknown' '--nonsense' '--dry-run' '--yes' 'help --purge'; do
    if /bin/bash "$REPO_DIR/libexec/mana/uninstall" $args > "$SANDBOX/output" 2>&1; then
        printf 'FAIL accepted invalid uninstall arguments: %s\n' "$args" >&2; exit 1
    fi
done
if /bin/bash "$REPO_DIR/libexec/mana/uninstall" all </dev/null > "$SANDBOX/output" 2>&1; then
    printf 'FAIL full uninstall accepted missing confirmation\n' >&2; exit 1
fi
[ ! -s "$CALLS" ]
printf 'PASS invalid arguments and missing confirmation make no changes\n'

output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" all --dry-run 2>&1)"
[[ "$output" == *'Planning full Mana uninstall:'* ]]
[[ "$output" == *'Full uninstall stops Mana services'* ]]
[[ "$output" == *'planned (dry-run)'* ]]
[[ "$(cat "$HOME/.ssh/config")" == 'edited SSH configuration' ]]
[ ! -s "$CALLS" ]
[ ! -f "$state/uninstalled" ]
printf 'PASS explicit full dry-run warns without restoring files or changing services\n'

output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" hermes --dry-run 2>&1)"
[[ "$output" == *'Removing Hermes interrupts chat'* ]]
[[ "$output" == *'login startup remains enabled'* ]]
output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" omlx --dry-run 2>&1)"
[[ "$output" == *'Stopping oMLX interrupts local inference'* ]]
[ ! -s "$CALLS" ]
printf 'PASS component previews explain service disruption and remaining startup\n'

# Simulate installation receipts without touching real applications.
: > "$state/casks.before"
printf '/Applications/iTerm.app\n' > "$state/apps.before"
mana_record_casks
[[ "$(cat "$state/casks.installed")" == iina ]]
printf 'absent\n' > "$state/brew.before"
mana_record_install brew
printf 'present\n' > "$state/nix.before"
mana_record_install nix
mana_record_edit .gitconfig
mana_record_edit local.nix
[ ! -f "$state/nix.installed" ]
mkdir -p "$HOME/Library/LaunchAgents" "$SANDBOX/cleanup/sw/bin"
printf '/test/mana/hermes/run.sh\n' > "$HOME/Library/LaunchAgents/org.nix-community.home.mana-hermes.plist"
printf '#!/bin/bash\nexit 99\n' > "$SANDBOX/cleanup/sw/bin/darwin-rebuild"
chmod +x "$SANDBOX/cleanup/sw/bin/darwin-rebuild"
touch "$ACTIVE_SYSTEM"
cat > "$REPO_DIR/libexec/mana/flake-source" <<'EOF'
#!/bin/bash
mktemp -d -t mana-test-flake
EOF
chmod +x "$REPO_DIR/libexec/mana/flake-source"

# env cannot invoke exported Bash functions, so provide a mock executable too.
mkdir "$SANDBOX/bin"
cat > "$SANDBOX/bin/brew" <<'EOF'
#!/bin/bash
printf 'brew %s\n' "$*" >> "$CALLS"
EOF
chmod +x "$SANDBOX/bin/brew"
export PATH="$SANDBOX/bin:$PATH"
ln -s "$(mana_resolve_path "$(command -v jq)")" "$SANDBOX/bin/jq"

export FAIL_ACTIVATION=1
if /bin/bash "$REPO_DIR/libexec/mana/uninstall" all --yes > "$SANDBOX/output" 2>&1; then
    printf 'FAIL activation failure was swallowed\n' >&2; exit 1
fi
! grep -q 'brew uninstall\|container volume delete' "$CALLS"
[ ! -f "$state/uninstalled" ]
[[ "$(cat "$HOME/.ssh/config")" == 'edited SSH configuration' ]]
unset FAIL_ACTIVATION
grep -q 'sudo .*darwin-rebuild activate' "$CALLS"
: > "$CALLS"
printf 'PASS configuration activation failure aborts before component removal\n'

output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" all --yes 2>&1)"
grep -q -- '-uninstall.system' "$CALLS"
grep -q 'sudo .*darwin-rebuild activate' "$CALLS"
grep -q 'sudo darwin-uninstaller' "$CALLS"
grep -qxF 'brew uninstall --cask iina' "$CALLS"
! grep -q 'iterm2\|nix-installer\|uninstall-container.sh' "$CALLS"
[[ "$(cat "$HOME/.ssh/config")" == 'original SSH configuration' ]]
[[ "$(cat "$HOME/.gitconfig")" == 'original Git identity' ]]
[[ "$(/usr/bin/readlink "$HOME/.config/git/config")" == "$SANDBOX/original-git" ]]
[[ "$(cat "$SANDBOX/later-git")" == 'later managed Git configuration' ]]
[[ "$output" == *'Keeping Homebrew: other installed packages remain.'* ]]
[ -f "$state/uninstalled" ]
[ ! -L "$SANDBOX/bin/jq" ]
before="$(cat "$CALLS")"
/bin/bash "$REPO_DIR/libexec/mana/uninstall" all --yes > "$SANDBOX/output"
[[ "$(cat "$CALLS")" == "$before" ]]
printf 'PASS full uninstall restores baseline, removes owned casks, preserves shared tools, and is idempotent\n'

mana_capture_baseline
[ ! -f "$state/uninstalled" ]
[ ! -f "$state/brew.installed" ]
[[ "$(cat "$state/home/.ssh/config")" == 'original SSH configuration' ]]
printf 'PASS reinstall archives completed receipts and starts a fresh baseline\n'

export DELETE_STATUS=42
if /bin/bash "$REPO_DIR/libexec/mana/uninstall" hermes --purge --yes > "$SANDBOX/output" 2>&1; then
    printf 'FAIL failed volume deletion reported success\n' >&2; exit 1
fi
! grep -q 'Hermes uninstall complete' "$SANDBOX/output"
unset DELETE_STATUS
printf 'PASS component deletion failures are propagated\n'

export CONTAINERS='[{"configuration":{"id":"hermes-agent"},"status":{"state":"running"}}]'
: > "$CALLS"
/bin/bash "$REPO_DIR/libexec/mana/uninstall" hermes --yes > "$SANDBOX/output"
[[ "$(cat "$CALLS")" == $'container stop hermes-agent\ncontainer delete hermes-agent' ]]
unset CONTAINERS
printf 'PASS Hermes teardown stops and deletes only its named container\n'

output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" all --purge --dry-run 2>&1)"
[[ "$output" == *'Keeping pre-existing hermes/workspace.'* ]]
[[ "$output" == *'Keeping pre-existing or unrecorded Hermes volume'* ]]
[[ "$output" != *'container volume delete hermes-data'* ]]
[[ "$(cat "$REPO_DIR/hermes/workspace")" == 'pre-existing workspace' ]]
printf 'PASS full purge preserves recorded pre-existing host data\n'

printf 'absent\n' > "$state/container.before"
mana_record_install container
export CONTAINERS='[{"configuration":{"id":"unrelated-worker"},"status":"running"}]'
output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" all --purge --dry-run 2>&1)"
[[ "$output" == *'Keeping Apple container: other workloads are present.'* ]]
unset CONTAINERS
printf 'PASS other container workloads prevent shared runtime removal\n'

touch "$state/configuration.installed"
touch "$ACTIVE_SYSTEM"
before="$(cat "$CALLS")"
if /bin/bash "$REPO_DIR/libexec/mana/uninstall" all --yes > "$SANDBOX/output" 2>&1; then
    printf 'FAIL full uninstall altered an unrelated active Nix configuration\n' >&2; exit 1
fi
[[ "$(cat "$CALLS")" == "$before" ]]
/bin/rm "$ACTIVE_SYSTEM"
printf 'PASS unrelated active Nix configuration is protected before teardown\n'

# No receipt is required to inspect an old installation, and preview stays read-only.
export HOME="$SANDBOX/no-record-home"
mkdir "$HOME"
output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" all --dry-run 2>&1)"
[[ "$output" == *'No original-state baseline.'* ]]
[[ "$output" == *'Keeping pre-existing or unrecorded oMLX.'* ]]
[[ "$output" != *'Planning oMLX uninstall:'* ]]
[ ! -d "$(mana_state_dir)" ]
printf 'PASS installations without any receipt can preview without changing state\n'

# A legacy installation must never become a fictitious original-state baseline.
export HOME="$SANDBOX/legacy-home"
mkdir -p "$HOME/Library/LaunchAgents"
printf '/test/mana/hermes/run.sh\n' > "$HOME/Library/LaunchAgents/org.nix-community.home.mana-hermes.plist"
mana_capture_baseline
state="$(mana_state_dir)"
[[ "$(cat "$state/baseline")" == legacy ]]
for tool in nix brew container omlx; do
    [[ "$(cat "$state/$tool.before")" == unknown ]]
done
mana_record_install nix
[ ! -f "$state/nix.installed" ]
output="$(/bin/bash "$REPO_DIR/libexec/mana/uninstall" all --dry-run 2>&1)"
[[ "$output" == *'No original-state baseline.'* ]]
[ ! -f "$state/uninstalled" ]
printf 'PASS legacy installations explicitly retain unknown shared tools\n'
