# Security Model

Mana runs Hermes, an autonomous web-connected agent capable of arbitrary code
execution, inside an Apple `container` microVM. oMLX runs on the Mac for Metal
acceleration. The VM limits the agent's access; it does not make untrusted code
or prompts harmless.

## What Is Isolated

- The agent's shell executes in Linux inside the VM, not in your macOS account.
- Your home directory, SSH/cloud credentials, synced documents, and authenticated
  desktop browser are not mounted into the container.
- Browser automation uses Camofox inside the VM, not your desktop browser.
- Disposable root-filesystem changes disappear when the container is replaced.

The agent can still reach network services on the Mac. A host API exposed to
Hermes is an additional capability, even when no host filesystem is mounted.

## What Is Shared

The container reads/writes its named volume and explicit host mounts:

| Surface | Consequence |
|---------|-------------|
| `hermes/.env` | The agent can read its API keys and dashboard credentials |
| `hermes/config.yaml` | The agent can change its persistent configuration |
| `hermes/data/memories/`, `hermes/workspace/` | Files can be changed, deleted, or exfiltrated |
| Dockerfile, entrypoint, SearXNG settings | Persistent recipe/startup changes can affect later builds or runs |
| `hermes-data` named volume | Sessions, plugins, cron state, and caches survive container replacement |

Review the actual mounts in [hermes/run.sh](../hermes/run.sh) when changing the
boundary. Do not mount your entire home directory or add host SSH execution as
an incidental convenience. Those are explicit changes to the trust model.

## Network And Credentials

Network egress is open. Prompt-injected code can send out anything it can read.
Avoid putting high-value cloud billing keys in the agent's environment; scope
credentials and limits to the work you are willing to expose.

The dashboard is published only on host loopback, port 9119, with authentication.
oMLX binds `0.0.0.0:8000` for VM access and uses an API key. That bind address also
allows connections through other reachable interfaces: it is not limited to
the VM by this repository's firewall configuration. Treat the local key as a
credential and never assume "local model" means "no network exposure."

The Apple virtualization/runtime stack is part of the trusted computing base.
A VM escape is unlikely but possible. The container runs with substantial power
inside the guest; it is not a second application-permission sandbox within Linux.

## Rebuild Is Not Sanitization

`mana hermes restart` keeps the container and all state. `mana hermes rebuild`
replaces its disposable root filesystem but **keeps the named volume and host
mounts**, including persistent plugins, cron tasks, memories, and editable recipes.
It cannot promise to remove a compromised agent's persistence.

For incident recovery, preserve evidence/backups, inspect or replace persistent
state and writable recipes from a trusted source, and rotate exposed credentials.
`mana uninstall hermes --purge` deletes the named volume but still keeps host
files. See [operations](operations.md) for backup and purge behavior.

## Host-Native Assistants

A desktop frontend does not by itself change the backend's privileges. A frontend
connected to the container still uses a containerized agent; an application that
installs and launches its own host-native agent does not. Mana does not install
Hermes Desktop. Consult its current upstream connection documentation before
attaching another frontend, and verify which backend actually executes tools.

Use a host-native agent only when you deliberately need real-project, desktop,
or authenticated-app access and accept the larger credential and filesystem
exposure. Prefer scoped accounts and approvals for that separate use case.