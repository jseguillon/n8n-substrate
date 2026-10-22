# n8n Substrate Actor

This repository builds the unprivileged Actor image used by n8n's Agent
Substrate sandbox provider. It contains only the in-Actor HTTP daemon, its
Node.js/Python workspace image, and the Substrate deployment manifests.

The daemon executes commands and manages files in `/home/user`. Agent
Substrate supplies Actor lifecycle, gVisor isolation, routing, and snapshots.

## Build

```sh
make test
docker buildx build --platform linux/amd64 --push \
  -f Dockerfile.substrate-sandbox \
  -t registry.example/n8n-sandbox:2026-10-22 .
```

Pin the resulting digest in `SUBSTRATE_SANDBOX_IMAGE`; do not deploy mutable
tags.

## Deploy

The manifests are in [`deploy/`](deploy/README.md). Configure a trusted
Substrate control-plane identity, private router, snapshot retention, and an
external idle Actor controller before serving tenant traffic.

See [the daemon API](substrate.md) and
[private registry trust instructions](substrate-registry-trust.md).
