#!/bin/bash
# Hermes Agent — Apple Container lifecycle management
# Usage: run.sh {up|down|restart|rebuild|status|health}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_IMAGE="docker.io/nousresearch/hermes-agent:latest"
HERMES_IMAGE="hermes-toolbox:latest"

# ── Resource allocation ──────────────────────────────────
HERMES_CPUS=4
HERMES_MEMORY="8G"

# ── Helpers ──────────────────────────────────────────────
ensure_system() {
    if ! container system status 2>/dev/null | grep -q 'running'; then
        echo "Container system not running — starting..."
        container system start
        # Wait for system to be ready
        local tries=0
        while ! container system status 2>/dev/null | grep -q 'running'; do
            sleep 1
            tries=$((tries + 1))
            if [ "$tries" -ge 15 ]; then
                echo "Error: container system failed to start after 15s" >&2
                exit 1
            fi
        done
        echo "Container system started."
    fi
}

container_state() {
    container list --all --format json | jq -r --arg id "$1" '
        [.[] | select(.configuration.id == $id)][0]
        | if . == null then "missing"
          elif (.status | type) == "object" then .status.state
          else .status end'
}

is_running() {
    local state
    state="$(container_state "$1")" || return 1
    [ "$state" = "running" ]
}

exists() {
    local state
    state="$(container_state "$1")" || return 1
    [ "$state" != "missing" ]
}

ensure_volume() {
    if ! container volume list --quiet 2>/dev/null | grep -q "^${1}$"; then
        echo "Creating volume: $1"
        container volume create "$1"
    fi
}

ensure_config() {
    if [ ! -f "${SCRIPT_DIR}/config.yaml" ]; then
        if [ ! -f "${SCRIPT_DIR}/config.yaml.example" ]; then
            echo "Error: missing ${SCRIPT_DIR}/config.yaml.example" >&2
            exit 1
        fi
        echo "Creating Hermes config from config.yaml.example..."
        cp "${SCRIPT_DIR}/config.yaml.example" "${SCRIPT_DIR}/config.yaml"
    fi
}

ensure_image() {
    # Use `image inspect` rather than grepping `image list` JSON: Apple's
    # container CLI stores images under `.configuration.name` as a
    # fully-qualified reference (e.g. docker.io/library/hermes-toolbox:latest),
    # with no top-level `.reference` field — so a literal match on
    # "$HERMES_IMAGE" never hits and rebuilds every run. `image inspect`
    # resolves the short name the same way `build -t`/`run` do.
    if ! container image inspect "$HERMES_IMAGE" >/dev/null 2>&1; then
        echo "Building hermes-toolbox image (first time)..."
        container image pull "$BASE_IMAGE"
        container build -t "$HERMES_IMAGE" "${SCRIPT_DIR}"
    fi
}

# Reconcile OMLX_API_KEY in hermes/.env with the live key oMLX is enforcing
# in ~/.omlx/settings.json. oMLX is the auth server, so its key wins.
#
# This closes the drift gap left by bootstrap.sh being a one-shot: brew
# upgrades, admin-UI "regenerate key", or a recreated settings.json on
# reboot can all change settings.json without touching .env, leaving the
# container authenticating with a stale key.
sync_omlx_key() {
    local settings="$HOME/.omlx/settings.json"
    local envfile="${SCRIPT_DIR}/.env"
    [ -f "$settings" ] || return 0
    if [ ! -f "$envfile" ]; then
        echo "Error: missing $envfile; run mana bootstrap first." >&2
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to synchronize the oMLX API key." >&2
        return 1
    fi

    local srv_key env_key
    if ! srv_key="$(jq -r '.auth.api_key // empty' "$settings")"; then
        echo "Error: cannot read the oMLX API key from $settings." >&2
        return 1
    fi
    [ -n "$srv_key" ] || return 0

    env_key="$(awk -F= '/^OMLX_API_KEY=/ { sub(/^OMLX_API_KEY=/, ""); print; exit }' "$envfile")"
    if [ "$srv_key" != "$env_key" ]; then
        echo "Syncing OMLX_API_KEY from ~/.omlx/settings.json -> hermes/.env"
        if grep -q '^OMLX_API_KEY=' "$envfile"; then
            sed -i.bak "s|^OMLX_API_KEY=.*|OMLX_API_KEY=${srv_key}|" "$envfile"
        else
            cp "$envfile" "${envfile}.bak"
            printf 'OMLX_API_KEY=%s\n' "$srv_key" >> "$envfile"
        fi
        rm -f "${envfile}.bak"
        grep -qFx "OMLX_API_KEY=${srv_key}" "$envfile" || {
            echo "Error: failed to synchronize OMLX_API_KEY in $envfile." >&2
            return 1
        }
    fi
}

# ── Commands ─────────────────────────────────────────────
cmd_up() {
    echo "Starting Hermes workspace..."

    # Ensure container system is running (needed after reboot)
    ensure_system
    container list --all --format json >/dev/null

    # Reconcile OMLX_API_KEY with the live oMLX server before launch
    sync_omlx_key

    # Seed the gitignored live config without overwriting user/dashboard edits
    ensure_config

    # Build custom image if needed
    ensure_image

    # Ensure persistent volume exists
    ensure_volume "hermes-data"

    # Ensure workspace and data directories exist on host
    mkdir -p "${SCRIPT_DIR}/data/memories"
    mkdir -p "${SCRIPT_DIR}/workspace"

    # ── Hermes Agent (includes SearXNG) ──────────────────
    if ! is_running "hermes-agent"; then
        if exists "hermes-agent"; then
            echo "Starting existing Hermes container..."
            container start hermes-agent
        else
            echo "Creating Hermes container..."
            container run -d \
                --name hermes-agent \
                --cpus "$HERMES_CPUS" --memory "$HERMES_MEMORY" \
                -v "hermes-data:/opt/data" \
                -v "${SCRIPT_DIR}/config.yaml:/opt/data/config.yaml" \
                -v "${SCRIPT_DIR}/.env:/opt/data/.env" \
                -v "${SCRIPT_DIR}/Dockerfile:/opt/data/Dockerfile" \
                -v "${SCRIPT_DIR}/entrypoint.sh:/opt/data/entrypoint.sh" \
                -v "${SCRIPT_DIR}/searxng/settings.yml:/etc/searxng/settings.yml" \
                -v "${SCRIPT_DIR}/workspace:/opt/data/workspace" \
                -v "${SCRIPT_DIR}/data/memories:/opt/data/memories" \
                -e "HERMES_UID=$(id -u)" \
                -e "HERMES_GID=$(id -g)" \
                -e "HERMES_DASHBOARD=1" \
                -e "HERMES_DASHBOARD_HOST=0.0.0.0" \
                -e "HERMES_DASHBOARD_TUI=1" \
                -e "HERMES_TUI_DIR=/opt/hermes/ui-tui" \
                -e "SEARXNG_URL=http://localhost:8080" \
                -p "127.0.0.1:9119:9119" \
                "$HERMES_IMAGE" \
                bash /opt/data/entrypoint.sh
        fi
    else
        echo "Hermes already running."
    fi

    local deadline=$((SECONDS + 90))
    until cmd_health >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ] || ! is_running hermes-agent; then
            cmd_status || true
            echo "Error: Hermes is not healthy. Run 'mana hermes logs'." >&2
            return 1
        fi
        sleep 1
    done

    echo ""
    cmd_status
    echo ""
    echo "Dashboard: http://localhost:9119"
    echo "Attach:    container exec -it hermes-agent bash"
}

cmd_down() {
    echo "Stopping Hermes workspace..."
    container list --all --format json >/dev/null
    if is_running "hermes-agent"; then
        container stop hermes-agent
    fi
    echo "Stopped."
}

cmd_restart() {
    ensure_system
    cmd_down
    cmd_up
}

cmd_rebuild() {
    echo "Rebuilding Hermes toolbox image (preserving persistent state)..."
    ensure_system

    # Pull latest base image
    echo "Pulling base hermes-agent image..."
    container image pull "$BASE_IMAGE"

    # Rebuild custom image
    echo "Building hermes-toolbox image..."
    container build -t "$HERMES_IMAGE" "${SCRIPT_DIR}"

    cmd_down
    if exists "hermes-agent"; then
        container delete hermes-agent
    fi
    cmd_up
}

cmd_status() {
    local state
    state="$(container_state hermes-agent)" || return 1
    printf 'hermes-agent: %s\n' "$state"
    [ "$state" = "running" ] || return 1
    cmd_health
}

cmd_health() {
    container exec hermes-agent bash -c '
        failed=0
        for service in dashboard searxng camofox; do
            case "$service" in
                dashboard) url=http://127.0.0.1:9119/ ;;
                searxng) url=http://127.0.0.1:8080/ ;;
                camofox) url=http://127.0.0.1:9377/health ;;
            esac
            code=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" "$url") || code=000
            case "$service:$code" in
                dashboard:200|dashboard:302|dashboard:401|searxng:200|camofox:200)
                    printf "  ok   %s (HTTP %s)\n" "$service" "$code" ;;
                *) printf "  fail %s (HTTP %s)\n" "$service" "$code"; failed=1 ;;
            esac
        done
        exit "$failed"
    '
}

# ── Main ─────────────────────────────────────────────────
case "${1:-help}" in
    up)      cmd_up ;;
    down)    cmd_down ;;
    restart) cmd_restart ;;
    rebuild) cmd_rebuild ;;
    status)  cmd_status ;;
    health)  cmd_health ;;
    *)
        echo "Usage: $(basename "$0") {up|down|restart|rebuild|status|health}"
        echo ""
        echo "  up       Start Hermes agent (with SearXNG built in)"
        echo "  down     Stop the container"
        echo "  restart  Restart without updating or rebuilding the image"
        echo "  rebuild  Rebuild image and restart"
        echo "  status   Show container state and endpoint health"
        echo "  health   Probe dashboard, search, and browser endpoints"
        exit 1
        ;;
esac
