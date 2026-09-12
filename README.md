# Mana

**MAc-Nix-Agent: an Apple-silicon AI workstation managed as code.**

Nix manages the system and shell, Homebrew supplies declared GUI apps, the
official oMLX app serves local models, and Hermes runs inside an Apple
`container` microVM with search, browser tools, and a web dashboard.

Requires Apple silicon and macOS 26+. Models are downloaded separately.

**Security boundary:** Hermes can execute arbitrary code inside its VM and
read/write its explicit host mounts. It does not get your home directory,
SSH keys, or authenticated desktop browser. Network access is unrestricted,
and rebuilds preserve persistent state. Read [the security model](docs/security-model.md).

## Quick Start

```bash
mkdir -p ~/repo
git clone https://github.com/poomnupong/mana.git ~/repo/mana
cd ~/repo/mana
./bin/mana bootstrap
```

Bootstrap installs missing prerequisites, reconciles Nix/Homebrew, checks the
latest Apple container and stable oMLX releases, seeds local settings, and
starts Hermes. Existing configuration and persistent data are preserved.
It can prompt for your macOS password; type it directly into the terminal.

Keep the checkout at `~/repo/mana`: [home.nix](home.nix) uses that path for
both shell access and login startup. Open a new terminal after bootstrap;
until then, invoke `./bin/mana`.

1. Open <http://127.0.0.1:8000/admin> and download a model suitable for your Mac.
2. Set `model.default` in the local Hermes configuration to the ID shown by
   `mana omlx models`. Match its context length to the oMLX model settings.
3. Run `mana hermes restart`, then `mana hermes` or `mana hermes dashboard`.

The dashboard is at <http://127.0.0.1:9119>. `mana hermes dashboard` prints its
locally generated login. Keep that output private.

## Commands

| Command | Contract |
|---------|----------|
| `mana help [command]` | Discover commands and detailed usage |
| `mana services` | Review managed services, dependencies, and other Apple containers |
| `mana services <action> <name>` | `status`, `start`, `stop`, `restart`, or `logs` |
| `mana doctor [--fix [--yes]]` | Diagnose; repair with warning/consent and a final health recheck |
| `mana rebuild` | Apply local Nix changes and enforce the declared Homebrew inventory; no version-upgrade step |
| `mana update [--no-flake] [--no-brew]` | Update Nix inputs, Homebrew versions, and stable oMLX, then restart oMLX |
| `mana bootstrap` | Reconcile the workstation, including installing/updating Apple container |
| `mana omlx <command>` | App installation/update, lifecycle, status, logs, model IDs, and API key |
| `mana hermes [command]` | Bare command opens chat; also `up`, `down`, `restart`, `rebuild`, `status`, `dashboard`, `logs` |
| `mana uninstall <component>` | Remove `omlx`, `hermes`, or `container`; keep data unless explicitly purged |

Service examples:

```bash
mana services
mana services start hermes           # starts the runtime when necessary
mana services restart omlx
mana services logs hermes
mana services status container       # runtime plus all container states
mana services restart container      # warns: affects ALL containers
mana services status container:buildkit
```

`omlx`, `hermes`, and `container` are the initial managed service names.
`container:<id>` addresses an existing container without inventing an installation
recipe. `container:hermes-agent` uses Hermes' managed lifecycle. Stopping or
restarting the runtime asks for confirmation; `--yes` is the automation override.
Runtime restart restores only previously running containers.

Listing/status is read-only and returns nonzero when a checked service is
unhealthy. HTTP health probes establish endpoint availability, not successful
LLM inference or browser/search functionality. A dashboard HTTP 401 means its
authentication gate is responding.

## Ownership And Updates

| Layer | Source of truth | Owner |
|-------|-----------------|-------|
| System, CLI tools, shell, login startup | [darwin.nix](darwin.nix), [home.nix](home.nix), [flake.lock](flake.lock) | Nix / nix-darwin / Home Manager |
| GUI apps and any Brew formulae | `homebrew.casks` / `homebrew.brews` in [darwin.nix](darwin.nix) | Declarative Homebrew activation |
| oMLX app | [libexec/mana/omlx](libexec/mana/omlx) | Official signed DMG; app owns its server |
| Apple container runtime | [libexec/mana/bootstrap](libexec/mana/bootstrap) | Official package; user-scoped runtime |
| Hermes | [hermes/Dockerfile](hermes/Dockerfile), [hermes/run.sh](hermes/run.sh) | Mana recipe and Apple container |
| Model conversion tools | [modelops/pyproject.toml](modelops/pyproject.toml), [modelops/uv.lock](modelops/uv.lock) | Isolated `uv` environment |

**No out-of-band Brew installs.** Add/remove packages in Nix and run `mana rebuild`.
Activation deliberately uses forced `zap` cleanup: undeclared Brew software and
associated cask data can be removed. Rebuilds may install newly declared packages,
but do not upgrade existing versions. `mana update` owns those upgrades.

`mana update` does not update Apple container, Hermes images, or modelops
dependencies. Use bootstrap for the runtime, `mana hermes rebuild` for a new
Hermes image, and the [modelops workflow](modelops/README.md) for Python packages.
`mana hermes restart` reloads configuration without rebuilding or updating images.

This is an installation recipe with **partial version pinning**, not a bit-for-bit
reproducible machine image. Nix and modelops have lockfiles; Brew releases, oMLX,
Apple container, and upstream Hermes image/build dependencies follow moving
channels. Review updates before relying on them for unattended workloads.

## State And Recovery

| State | Location | Retained by rebuilds? |
|-------|----------|-----------------------|
| Machine identity | gitignored `local.nix` | Yes |
| Hermes settings and credentials | gitignored `hermes/config.yaml` and `hermes/.env` | Yes |
| Memories and exchanged files | gitignored `hermes/data/` and `hermes/workspace/` | Yes |
| Sessions, plugins, cron, caches | `hermes-data` named volume | Yes |
| oMLX settings, key, and models | `~/.omlx/` | Yes |
| Disposable Hermes root filesystem | Apple container storage | No, on Hermes rebuild |

Rebuild is **not a clean-state or incident-recovery reset**. Persistent plugins,
configuration, and writable bind mounts survive. See [operations](docs/operations.md)
for backup, troubleshooting, and explicit purge behavior.

Hermes starts at login through Home Manager. Service stop/start commands affect
the current session; change the Nix launch agent to change login policy. Optional
Ollama and LM Studio apps are installed, but Mana does not control their servers.
There are no ComfyUI or Open-WebUI service definitions in this repository.

## Development

The public dispatcher is [bin/mana](bin/mana); implementations live under
`libexec/mana`. Service orchestration delegates to the same component commands
used directly by people and doctor. Keep new services' installation/configuration
in code; runtime discovery alone does not make a service managed.

```bash
/bin/bash tests/lifecycle.sh
```

These tests use temporary homes and mocked process/container commands. They do
not stop host services, read real credentials, or download dependencies. Follow
with `mana services` and `mana doctor` for live checks. Nix activation is a separate,
privileged step; it is not part of the test suite.

Workflow operations such as model downloading, conversion, and quantization stay
explicit rather than becoming Mana wrappers. See the [modelops guide](modelops/README.md).