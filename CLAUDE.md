# CLAUDE.md

## Repository

`agent-network-doks` is a Package Skill in three colours — green
(Clojure/Babashka, canonical), red (TypeScript/Bun), blue (Python/uv) —
for the [NetBird Agent Network](https://docs.netbird.io/agent-network) demo
— keyless, identity-gated LLM access — on **DigitalOcean Kubernetes
(DOKS)**. OpenTofu manages the DOKS cluster (single non-HA control plane;
cluster and service subnets are READ BACK from the resource, never
supplied), the container registry — created and profile-named, or adopted
via `digitalocean-registry-name` — with asymmetric rotated docker
credentials, and two unproxied Cloudflare `A` records: the base name and
its **wildcard**. kubectl (no Ansible, no SSH — the nodes are managed and
every operation goes through the generated kubeconfig) converges the
gateway — Traefik behind a TCP-mode DigitalOcean regional Load Balancer,
the combined `netbird-server` with its datastore on a CSI volume, the
dashboard in agent-network-only mode, the NetBird reverse proxy in private
mode — then a launcher-side bootstrap reconciles the control plane and
starts the **two-pod application**: the NetBird client in netstack/SOCKS5
mode (userspace WireGuard — no TUN, no capabilities, `restricted` Pod
Security) and the isolated agent running headless Claude Code. The first
consumer is `../agent-network-doks-digitalocean`.

The sibling `../agent-network-k8s` package proved this exact architecture
on Vultr Kubernetes Engine (three colours); `../agent-network` is the
single-node architectural parent that owns the control-plane contract, the
release train, and the fake-key doctrine. Read both CLAUDE.mds for the
findings this package inherits; everything below is where this package
deliberately differs from the VKE sibling.

## DigitalOcean translations worth knowing

- **Registries are account-scoped and tier-limited**, and the subscription
  is account-global. Two modes, keyed on `digitalocean-registry-name`
  alone: absent → create a profile-named registry behind a tier-aware
  capacity preflight (zero registries: create; registries exist: another
  only when current AND requested tier are `professional`; every
  Starter/Basic multi-registry case fails toward adopt mode); present →
  adopt (a data source — never created, never destroyed), where the
  preflight checks the profile repository FIRST so reuse after a partial
  converge never counts as new allocation. `digitalocean-registry-tier` is
  create-mode-only and a validation error in adopt mode. Only the
  profile-named repository is deployment-owned; adopt-mode teardown deletes
  exactly it through the API.
- **Registry credentials are registry-wide** (no repository scoping exists)
  and asymmetric: the write credential is short-lived (26h expiry, 24h
  rotation) and its cluster Secret exists only while kaniko builds, removed
  by an EXIT trap on every path; the read-only pull credential is
  long-lived (90d expiry, 30d rotation) and re-applied each converge so a
  node replacement between converges never strands the agent in
  ImagePullBackOff.
- **Subnets are outputs.** Neither `cluster_subnet` nor `service_subnet` is
  supplied (legacy non-VPC-native networking, deliberately); both are read
  back and persisted as launcher-side state, and converge substitutes
  `__POD_CIDR__` into the server's trusted-proxy range and the proxy's
  PROXY-protocol trust. There is no pod-CIDR key in colors.yml at all.
- **The kubeconfig contract is DO-shaped**: `kube_config[0].raw_config`,
  base64-encoded in the output so the launcher's decode path matches the
  VKE sibling's byte for byte.
- **The LB is pinned explicitly**: `do-loadbalancer-type: "REGIONAL"` and
  `do-loadbalancer-protocol: "tcp"`, named after the compute name.
  `digitalocean-http-sources` renders into `loadBalancerSourceRanges`, and
  acceptance verifies the resulting LB **firewall through the DigitalOcean
  API** — comparing the client-source allow set for 80/443 and tolerating
  CCM-managed rules, because an open deployment cannot prove denial by
  probing.
- **A Cilium canary gates every first converge**: before any secret or
  provider credential enters the cluster, a throwaway namespace with
  default-deny plus one scoped allow proves NetworkPolicy enforcement on
  THIS cluster (allowed path admitted, internet and cross-namespace
  denied). DOKS ships Cilium; the canary turns the documentation claim into
  an observation.
- **`doks-version` is a slug** (`1.36.3-do.2` — the changelog sometimes
  prints another shape; the API accepts only the slug), checked against
  `GET /v2/kubernetes/options` before create.
- **Disruption preflights**: the suite refuses to start with a NotReady or
  cordoned node, and the drain waits for VolumeAttachments to leave the
  node before blaming the application's rollout.

Everything else — the two-boundary isolation claim probed from both sides,
the netstack client contract (NB_* env, $USER, poisoned-config discipline),
the embedded proxy peer whose overlay address churns and is re-read from
the client's network map, Traefik's subdomain-only passthrough, the
one-order-two-SANs wildcard, create-once secrets, the streamed one-off
setup key — is inherited unchanged from the VKE sibling. Do not relitigate
it here; read `../agent-network-k8s/CLAUDE.md`.

## Commands

```sh
cd green && bb test           # validation, tools, workflow
cd green && bb golden         # two backends (local, r2), byte for byte
cd green && bb golden:accept  # after an intended change — read the diff first
cd red && bun test && bun run typecheck
cd blue && uv sync && uv run pytest
./scripts/golden.sh           # same as bb golden, from the repository root
./scripts/parity.sh           # three colours, both state backends, byte for byte
./scripts/launcher.sh         # launcher self-checks, all three payloads
cd green && bb pin            # stamp the three payloads after a push
cd green && ./green build     # render; contacts nothing
cd green && ./green create --dry-run
```

A change to shared behaviour lands in green, red, and blue in the same
commit and passes `./scripts/parity.sh` or it is not done: red/resources and
blue's embedded resources are byte-for-byte copies of green's template tree,
and the copies are the mechanism.

Never run a real create/delete without explicit authorization. Never edit or
read `.colors/`, and never read `.envrc.private`.

## Coupling

The package pins only the SDKs — green transitively via `green/deps.edn`,
red and blue inside their payloads (`red/package.json` mirrors the red pin
for the checkout) — like `k8s`, its DigitalOcean templates and provider
table are its own; there is no ONCE pin. Working-tree overrides:
`AGENT_NETWORK_DOKS_LIB_ROOT` (this repository's root), `GREEN_LIB_ROOT`.
`green/green`, `red/red`, and `blue/blue` are symlinks to the skill
payloads; in a deployment each is a **copy** that must be refreshed after
`npx skills update -p`. After committing and pushing package code, run
`bb pin` (in `green/`) — it stamps all three payloads — commit the launcher
stamps, and push again. Do not invent or hand-edit any pin.

## Documentation

`index.html` is this repository's landing page and carries two analytics
tags: GA4 measurement ID `G-4VKP1WY4QJ`, whose explicit `page_title` must
exactly equal the decoded HTML `<title>` and stay distinct and stable, and
the self-hosted Rybbit snippet with site ID `9fb9c41a6d49`. Never add one
tag without the other.

## Git

Work on the current branch. Do not commit or push unless explicitly asked.
