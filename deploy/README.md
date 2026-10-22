# Agent Substrate deployment

This directory contains the Agent Substrate deployment assets for the sandbox. It replaces
the API gateway, runner registry, Docker-in-Docker, Firecracker runner, and
tenant database with [Agent Substrate](https://github.com/agent-substrate/substrate).

Each n8n sandbox is a Substrate Actor. Substrate places it into a gVisor worker,
restores the memory and filesystem state that a controller snapshots, and routes
a request to it through `atenet-router`.

## Prerequisites

Install Agent Substrate and `kubectl ate` using its upstream quickstart. The
cluster must have a snapshot store configured. This package assumes the
installed Substrate release provides a gVisor `SandboxConfig` default.

Before applying these resources, replace Substrate's bootstrap control-plane
identity with your trusted JWT or mTLS configuration and grant each tenant only
its own Atespace. Do not run this multi-tenant package with a shared bootstrap
owner. Also operate a trusted controller that synchronously suspends Actors on
idleness and before worker or node eviction; Substrate does not do either
automatically.

The snapshot store must encrypt data at rest, restrict access to the Substrate
control plane and node supervisors, and apply tenant-aware retention and
deletion controls. Actors must not receive snapshot-store credentials.

Set both values to immutable, digest-pinned images. `SUBSTRATE_WORKER_IMAGE` is
the `ateworker-gvisor` image from the same Substrate release as the control
plane. `SUBSTRATE_SANDBOX_IMAGE` is built from `Dockerfile.substrate-sandbox`.

```bash
export SUBSTRATE_WORKER_IMAGE=registry.example/ateworker-gvisor@sha256:...
export SUBSTRATE_SANDBOX_IMAGE=registry.example/n8n-sandbox@sha256:...
```

Build and publish the actor image before setting its digest:

```bash
docker buildx build --platform linux/amd64 \
  --push -f Dockerfile.substrate-sandbox \
  -t registry.example/n8n-sandbox:2026-10-19 .
```

## Deploy

`ActorTemplate` is managed through the Substrate API; it is not a Kubernetes
CRD. The worker pool is a Kubernetes resource.

```bash
envsubst < deploy/worker-pool.yaml.tmpl | kubectl apply -f -
kubectl ate create atespace n8n-sandboxes
envsubst < deploy/actor-template.yaml.tmpl | kubectl ate create actor-template -f -
```

Wait for the template's golden snapshot before accepting traffic:

```bash
kubectl ate get actor-template n8n-sandbox -a n8n-sandboxes
```

## Lifecycle

An actor name is the sandbox identifier. It must be a DNS-1123 label, not the
UUID format used by the retired service API.

```bash
kubectl ate create actor workflow-42 -a n8n-sandboxes --template n8n-sandbox
kubectl ate resume actor workflow-42 -a n8n-sandboxes
kubectl ate suspend actor workflow-42 -a n8n-sandboxes --mode=sync
kubectl ate delete actor workflow-42 -a n8n-sandboxes
```

Substrate does not suspend actors based on idleness. Operate a trusted idle
controller that calls `suspend actor --mode=sync`, and arrange worker-drain
handling before a node is terminated. Synchronous suspension does not return
until the snapshot is durable.

Deleting an Actor deletes its actor-owned snapshots. To retain state beyond an
Actor's deletion, create a tag from a synchronously suspended Actor first:

```bash
kubectl ate create tag workflow-42-checkpoint -a n8n-sandboxes \
  --actor workflow-42
kubectl ate delete actor workflow-42 -a n8n-sandboxes
```

## Requests

Send requests to `atenet-router`, selecting the actor with the trusted
`ate-target-actor` header. The sandbox daemon retains its direct endpoints, so
the path no longer contains a sandbox id:

```bash
kubectl -n ate-system port-forward svc/atenet-router 8000:80

curl -X POST http://localhost:8000/executions \
  -H 'ate-target-actor: n8n-sandboxes/workflow-42' \
  -H 'Content-Type: application/json' \
  --data '{"command":"echo hello"}'
```

The same header applies to `/files`, `/files/content`, `/stat`, and `/mkdir`.
See [the native API guide](../substrate.md) for endpoint and security details.

Do not expose `atenet-router` directly to untrusted clients. Before serving
traffic, deploy an authenticated policy-enforcement point that derives and
overwrites `ate-target-actor` from trusted tenant identity. This package does
not ship one because its authentication provider and tenant-to-Atespace mapping
are deployment-specific. Forwarding a client-supplied value permits
cross-actor access.

Actors start with no egress policy. Substrate therefore denies DNS and outbound
HTTP(S) until an operator creates an Actor egress policy. Keep this default;
add only hostname-specific rules required by a tenant's workload.
