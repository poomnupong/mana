FROM docker.io/nousresearch/hermes-agent:latest

USER root

# ── System tools for Hermes to self-install packages at runtime ──
RUN apt-get update && \
    apt-get install -y --no-install-recommends nodejs npm libgtk-3-0 && \
    rm -rf /var/lib/apt/lists/*

# ── Camofox anti-detection browser ──────────────────────
# The bundled Node's default npm prefix is not on the runtime PATH.
RUN npm install -g --prefix /usr/local camofox-browser && \
    camofox-browser --version

# ── Install SearXNG into the Hermes venv ─────────────────
# SearXNG's setup.py imports its settings before pip resolves runtime deps.
# Preinstall those imports; --no-build-isolation uses this same environment.
RUN curl -sS https://bootstrap.pypa.io/get-pip.py | /opt/hermes/.venv/bin/python && \
    /opt/hermes/.venv/bin/pip install --no-cache-dir setuptools msgspec pyyaml typing-extensions && \
    /opt/hermes/.venv/bin/pip install --no-cache-dir --no-build-isolation \
      git+https://github.com/searxng/searxng.git@master

# ── Web dashboard deps (browser GUI on :9119) ────────────
# `hermes dashboard` needs the `web` extra (FastAPI/Uvicorn) and the `pty`
# extra (ptyprocess) to embed the TUI chat tab over a pseudo-terminal. The
# base image ships only the CLI/gateway, so install them explicitly. pip
# reconciles versions against the already-installed hermes constraints.
RUN /opt/hermes/.venv/bin/pip install --no-cache-dir \
      fastapi "uvicorn[standard]" ptyprocess

# ── SearXNG settings (can be overridden via volume mount) ─
COPY searxng/settings.yml /etc/searxng/settings.yml

# ── /model picker shows only configured providers ─────────
# We used to patch tui_gateway/server.py to flip include_unconfigured to
# False so the picker wouldn't list ~30 unconfigured cloud providers. As of
# the current hermes-agent image that's the upstream default — the handler
# now reads include_unconfigured from request params (defaulting to False),
# so no patch is needed. Left as a note so the intent isn't lost.

# ── Entrypoint ────────────────────────────────────────────
COPY entrypoint.sh /opt/hermes/entrypoint.sh
RUN chmod +x /opt/hermes/entrypoint.sh
