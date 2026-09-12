# Operations

## Diagnose Before Repair

```bash
mana services
mana doctor
mana doctor --fix
```

`doctor --fix` warns and asks for confirmation before it may install oMLX, remove
legacy Nix/Brew services, terminate a conflicting listener on port 8000, or restart
oMLX/Hermes. Use `--fix --yes` only when that disruption is acceptable. It reruns
report-only checks afterward and exits nonzero if issues remain. It never purges
models, named volumes, or host files.

Runtime-wide actions are separate:

```bash
mana services status container
mana services logs container
mana services restart container
```

Runtime restart affects all Apple containers, not just Hermes. It snapshots the
running IDs before stopping and restores those IDs after startup. Previously
stopped containers stay stopped. Services installed outside Mana are visible but
remain the responsibility of their own installation recipes.

For a VM startup error before Hermes executes:

```bash
container logs --boot hermes-agent
container system logs --last 5m
```

A `configureDns` error can have causes other than DNS server selection. For example,
an accompanying ext4 inode error and I/O failure writing `resolv.conf` indicate a
damaged disposable root filesystem. Preserve it before replacing the container;
do not delete `hermes-data` or change DNS settings merely to hide that symptom.

## oMLX

The official app owns its server. Do not add a second Brew or launchd supervisor.
`mana omlx install` / `upgrade` resolve the latest stable official DMG, verify its
signature and Gatekeeper assessment, and preserve `~/.omlx/`. App installation in
`/Applications` may require a password typed directly into your terminal.

```bash
mana omlx status
mana omlx models
mana omlx logs
mana omlx restart
```

Settings live in `~/.omlx/settings.json`. Bootstrap configures host `0.0.0.0` so
the VM can reach port 8000, and seeds a shared API key. This is not a LAN firewall:
other reachable interfaces can also accept connections. Keep authentication on.
`mana omlx key` prints a secret; avoid including its output in reports.

Choose/download models at <http://127.0.0.1:8000/admin>. Set model context length
in the admin UI and match the Hermes setting. Bootstrap seeds a 65536-token global
fallback; per-model settings can override it. Leave memory for macOS, KV cache,
the 8 GiB Hermes VM, and other apps rather than sizing from weights alone.

Hermes startup synchronizes `OMLX_API_KEY` from the live oMLX settings. After key
rotation, run `mana hermes restart` to reload process environments.

## Hermes

```bash
mana hermes up          # create/start if needed, then wait for endpoint health
mana hermes restart     # same image and container; reload settings
mana hermes rebuild     # build first, then replace container; preserve data
mana hermes status      # container state plus dashboard/search/browser probes
mana hermes logs        # combined required-service logs
```

The base image supervises the dashboard; Mana does not launch a second copy.
Mana's entrypoint terminates the container if search or browser exits. The runtime
does not automatically restart the container; inspect logs and use `restart` or doctor.
Startup retries endpoint probes for about 90 seconds, with a one-second pause
between attempts; individual requests can add to that deadline. Health checks do
not generate text, open browser tabs, or search the internet.

The live settings are seeded from [the tracked example](../hermes/config.yaml.example).
Edit the local configuration or use the dashboard; restart afterward when a
setting is loaded only at process startup. Changing a mount, published port, or
resource allocation requires recreating the container, not just restarting it.

The template selects local oMLX plus an Ollama Cloud `fallback_model`. The fallback
requires `OLLAMA_API_KEY` and can send prompts/context off-machine when used.
Remove the entire `fallback_model` entry in the live configuration and restart
Hermes for local-only LLM inference; this does not disable web tools or network egress.

### Bootstrap Behavior

Bootstrap is a reconcile operation, not a promise to leave existing settings untouched:

| Setting or state | Behavior on rerun |
|------------------|-------------------|
| Machine identity | Rewrites local identity when it differs from the current user/hostname |
| oMLX bind address | Enforces `0.0.0.0` for VM access |
| oMLX global context | Enforces `sampling.max_context_window = 65536`; model overrides remain separate |
| Shared oMLX key | Prefers the server key, then the existing Hermes key, then generates one; synchronizes Hermes |
| Dashboard credentials | Seeds missing/empty fields; keeps existing nonempty values |
| Live Hermes configuration | Seeds from the example only when missing; does not replace it |
| Models, memories, workspace, named volume | Retains existing data |
| Services and dependencies | Reconciles Nix/Brew inventory, checks runtime/app releases, restarts oMLX and Hermes |

`mana rebuild` is the narrower choice for local Nix edits. `mana hermes restart`
reloads Hermes configuration without updating its image; a missing image is built
on demand. Bootstrap does not rebuild an existing Hermes image.

## Apply And Update

Declare CLI packages in [home.nix](../home.nix), GUI apps and Brew formulae in
[darwin.nix](../darwin.nix), then use `mana rebuild`. Forced Homebrew cleanup is
intentional: undeclared packages and cask-associated data may be removed.

`mana update` upgrades Brew explicitly, updates the Nix lockfile, activates Nix,
and upgrades/restarts oMLX. `--no-brew` skips version upgrades but still reconciles
inventory during activation. `--no-flake` keeps the current Nix lockfile.

Activation uses a temporary source containing tracked working-tree files plus
the local machine identity. Ignored credentials and runtime data stay out of the
Nix store. New source files must be tracked to participate in that source snapshot.

Keep [flake.lock](../flake.lock) committed. After an intentional `mana update`,
review the lockfile diff, verify activation and `mana doctor`, and commit the
tested pins, preferably separately from feature changes. Do not routinely delete
or ignore the lockfile. Modelops dependencies have their own [lockfile](../modelops/uv.lock).

## Backups

Protect backups as secrets. At minimum preserve the local Hermes configuration,
credentials, memories, workspace, and `~/.omlx/` settings. Model weights can be
backed up or downloaded again. Git alone does not back up runtime state.

The examples below are a recovery procedure, not an automated, end-to-end tested
backup system. Use new archive names for each backup, check command exit codes,
list both archives with `tar tzf`, and rehearse restoration into disposable state
before relying on them. Do not overwrite your only known-good backup.

For a consistent Hermes backup, stop it first:

```bash
mana hermes down
umask 077
tar czf ~/hermes-host-backup.tgz \
    hermes/.env hermes/config.yaml hermes/data hermes/workspace
container run --rm --user root --entrypoint /bin/tar \
    -v hermes-data:/opt/data hermes-toolbox:latest \
    czf - -C /opt/data . > ~/hermes-volume-backup.tgz
mana hermes up
```

Run this from the checkout. The temporary helper uses the existing local image
and mounts only the named volume, so it does not include the separate host bind
mounts. Verify both archives before relying on them. On a fresh machine, restore
the host archive in the checkout before bootstrap. To restore the volume, stop
Hermes and use the local image as an extraction helper:

```bash
mana hermes down
container run --rm -i --user root --entrypoint /bin/tar \
    -v hermes-data:/opt/data hermes-toolbox:latest \
    xzf - -C /opt/data < ~/hermes-volume-backup.tgz
mana hermes up
```

Restoring overwrites matching files; it does not remove newer files absent from
the archive. For exact recovery, use a verified clean target volume. Do not purge
your only copy of sessions or plugin state.

## Uninstall And Reset

| Component | Default behavior | `--purge` adds |
|-----------|------------------|----------------|
| `omlx` | Remove app; keep `~/.omlx/` | Remove oMLX data; `--keep-models` / `--keep-config` spare selected data |
| `hermes` | Remove container and image; keep volume and host files | Delete the named volume, including sessions, plugins, and cron state |
| `container` | Remove runtime while keeping data | Ask the upstream uninstaller to delete runtime data |

Inspect with `mana uninstall <component> --dry-run`. Even Hermes purge retains
host files. A security reset requires separately reviewing/replacing persistent
code and configuration and rotating exposed credentials. Uninstalling Hermes does
not change its declared login startup; disable that launch agent in Nix if you
want it to stay uninstalled.

## Git Identity And Migration

Home Manager owns a read-only Git configuration. Write personal identity to the
separate user file:

```bash
GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.name "Your Name"
GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.email "you@example.com"
```

For an old `mac-nix-agent` checkout, move it to `~/repo/mana`, update its Git remote,
run `./bin/mana rebuild`, and recreate Hermes so its absolute mounts use the new
location. The former `mna` commands are no longer provided. The move preserves
ignored files; `~/.omlx/` remains outside the checkout.