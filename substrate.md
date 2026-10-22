# Native Substrate API

The service uses [Agent Substrate](https://github.com/agent-substrate/substrate)
for sandbox lifecycle, VM-grade isolation, state snapshots, and request
routing. There is no n8n sandbox REST gateway, runner, or TypeScript SDK in
this deployment.

Before creating tenant Actors, replace Substrate's bootstrap control-plane
identity with trusted JWT or mTLS authentication and grant each tenant only its
own Atespace. A shared bootstrap owner is not a multi-tenant authorization
model.

## n8n provider integration

The custom n8n 2.43.8 source at `/home/jse/n8n-substrate-source` adds
**Agent Substrate** to **Agents → Add a code sandbox**. It manages Actors through
the native gRPC API and uses this repository's daemon for commands and files.
Connection details come from server-side `SUBSTRATE_*` environment variables.
See `packages/@n8n/agents/docs/substrate-sandbox.md` in that source tree.

Mount the control token and CA bundle read-only. Configure the private control
endpoint, router URL, Atespace, ActorTemplate, and TLS server name with the
server-side `SUBSTRATE_*` environment variables.

The snapshot store must encrypt data at rest, be accessible only to Substrate's
control plane and node supervisors, and enforce tenant-aware retention and
deletion controls. Never give snapshot-store credentials to an Actor.

## Lifecycle

Use `kubectl ate` or the Substrate gRPC control API to create, resume, suspend,
inspect, and delete Actors. An Actor is a sandbox. An Atespace is its tenant
boundary. Actor names must be DNS-1123 labels.

```bash
kubectl ate create actor workflow-42 -a n8n-sandboxes --template n8n-sandbox
kubectl ate resume actor workflow-42 -a n8n-sandboxes
kubectl ate get actor workflow-42 -a n8n-sandboxes
kubectl ate suspend actor workflow-42 -a n8n-sandboxes --mode=sync
kubectl ate delete actor workflow-42 -a n8n-sandboxes
```

Substrate does not suspend Actors automatically when they are idle. Operate a
trusted controller that selects idle Actors and calls `SuspendActor` with
synchronous durability. This writes a snapshot before it returns; use it before
draining a worker when filesystem and memory state must be retained.

Deleting an Actor removes its actor-owned snapshots. To retain a checkpoint
after deletion, synchronously suspend it, create a tag, then delete the Actor:

```bash
kubectl ate create tag workflow-42-checkpoint -a n8n-sandboxes --actor workflow-42
kubectl ate delete actor workflow-42 -a n8n-sandboxes
```

## Sandbox requests

Route every daemon request through `atenet-router` and set:

```text
ate-target-actor: <atespace>/<actor>
```

The actor daemon exposes these paths:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/healthz` | Readiness check |
| `POST` | `/executions` | Run a shell command; response is NDJSON |
| `GET`, `DELETE` | `/executions/{exec_id}` | Resume or cancel an execution |
| `GET`, `PUT`, `POST`, `DELETE` | `/files` | List, write, append, or delete files |
| `GET` | `/files/content` | Read a file |
| `POST` | `/files/copy`, `/files/move`, `/mkdir` | File operations |
| `GET` | `/stat` | File metadata |

`POST /executions` takes the same body the daemon used previously:

```json
{"command":"echo hello","env":{"KEY":"value"},"workdir":"/home/user","timeout_ms":10000}
```

`DELETE /executions/{exec_id}` cancels a running command. Files use `path` as a
query parameter. `PUT /files` and `POST /files` use raw request bodies to write
or append data. Set `overwrite=false` for create-only writes. `DELETE /files`
accepts `recursive` and `force` query parameters. Copy and move requests use JSON
with `src`, `dest`, and optional `recursive` or `overwrite` fields.

The daemon does not authenticate requests. Keep `atenet-router` private behind
an authenticated policy-enforcement point. That component must determine the
target Actor from the authenticated caller and overwrite the routing header;
it must not relay a caller-provided `ate-target-actor` value. This repository
does not ship that component because its authentication provider and
tenant-to-Atespace mapping are deployment-specific.

Actors have no egress policy at creation, so Substrate denies their DNS and
outbound HTTP(S). Preserve that default-deny posture; add an Actor egress policy
only for the hostname-specific destinations a workload requires.

## Isolation and state

The `n8n-sandbox` WorkerPool targets Substrate's gVisor class. The ActorTemplate
sets each sandbox to one vCPU and 2 GiB memory; worker limits bound the shared
physical capacity. A normal suspend and resume at memory fidelity preserves
running process memory and the writable filesystem.

Configure a separate Atespace and authentication policy for each tenant. Do not
treat actor names or the routing header as authorization.
