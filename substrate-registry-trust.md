# Private Harbor registry trust

Substrate's atelet pulls Actor images directly using Go's TLS trust store.
Trusting a registry in Talos/containerd only covers Kubernetes pod image pulls;
it does not add trust to atelet.

The deployed cluster's `ate-system/harbor-ca` ConfigMap contains a server
certificate (`CA:FALSE`). Use the issuer CA (`CA:TRUE`) from
`harbor/harbor-ingress` instead. Copy only the public `ca.crt`, never `tls.key`:

```bash
kubectl -n ate-system create configmap harbor-registry-ca \
  --from-literal="ca.crt=$(kubectl -n harbor get secret harbor-ingress \
    -o jsonpath='{.data.ca\.crt}' | base64 --decode)" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n ate-system patch daemonset atelet --type=strategic \
  --patch-file deploy/atelet-registry-trust.patch.yaml
kubectl -n ate-system rollout status daemonset/atelet --timeout=180s
```

The patch adds the issuer to Go's root search directories without removing
public roots or disabling certificate/hostname verification. It changes the
DaemonSet template, so it survives pod recreation. Reapply it after a Helm
upgrade, or include it in the installation's Helm post-renderer/GitOps overlay;
the deployed Substrate 0.4.0-alpha1 chart has no extra-volume hook.

When Harbor's CA rotates, refresh the ConfigMap and restart atelet so Go reloads
the roots. Registry authentication is separate from certificate trust: private
projects also require a configured image credential provider.

## Installed v0.4 API

The cluster runs Substrate `v0.4.0-alpha1`. Use its matching CLI and
`deploy/actor-template.v0.4.yaml.tmpl`; the upstream-main template uses newer
API fields. The compatibility template selects the existing `sasa` pool and
`ax-system` Atespace, stores snapshots in `s3://ate-snapshots/n8n/`, and runs
the daemon on port 80 for the router's default HTTP target:

```bash
export SUBSTRATE_SANDBOX_IMAGE=harbor.192.168.1.81.nip.io:32129/ax/n8n-sandbox@sha256:470ee474f2fd19312e7c3a571d0a1743ba8aff0852d2f4f0800100e5edac2e1f
envsubst < deploy/actor-template.v0.4.yaml.tmpl | kubectl ate create actor-template -f -
kubectl ate create actor n8n-sandbox-check -a ax-system --template n8n-sandbox-v04
kubectl ate resume actor n8n-sandbox-check -a ax-system
```

This release's CLI supports `suspend actor` without `--mode=sync`.

The v0.4 image cache starts the container as root and does not preserve all
filesystem ownership/modes needed by an unprivileged process. The compatibility
template normalizes root/device modes and the sandbox home ownership before
the daemon clears supplementary groups and drops to UID/GID 1000. Only
`CHOWN`, `SETUID`, and `SETGID` are granted for that startup transition; the
daemon and commands do not stay root.

## n8n command check

`deploy/n8n-command-check.json` is an importable manual workflow for the
local host-networked n8n container. It calls `/executions`, parses the NDJSON
events, and fails unless the remote command exits with code 0, runs as UID
1000, and returns the expected output. The router port-forward must be running
on `127.0.0.1:18000`.

```bash
docker cp deploy/n8n-command-check.json n8n-substrate:/tmp/substrate-command-check.json
docker exec n8n-substrate n8n import:workflow --input=/tmp/substrate-command-check.json
docker exec --env N8N_RUNNERS_BROKER_PORT=5689 n8n-substrate \
  n8n execute --id=substrateCommandCheck --rawOutput
```

The broker-port override avoids colliding with the running editor's task
broker. The workflow writes `/home/user/n8n-substrate-check.txt`; a subsequent
read after Actor suspension verified that its contents survive wake-on-request.
