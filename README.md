# agent-network-doks

A [Colors Package Skill](https://www.getcolors.ai/) for a
[NetBird Agent Network](https://docs.netbird.io/agent-network) demo on
**DigitalOcean Kubernetes (DOKS)**: a keyless, policy-gated LLM endpoint and
a **two-pod application** — the NetBird client in netstack/SOCKS5 mode
(userspace WireGuard: no TUN device, no capabilities, `restricted` Pod
Security) and a network-isolated agent pod running headless Claude Code
whose only egress, enforced by a default-deny NetworkPolicy and probed from
both sides on every converge, is that SOCKS5 listener.

One `colors.yml` describes the whole deployment. OpenTofu provisions the
DOKS cluster (single non-HA control plane, subnets read back from the API —
outputs, never inputs), the DigitalOcean Container Registry — created and
profile-named, or adopted by name (registries are account-scoped and
tier-limited) — with asymmetric, rotated docker credentials, and two
unproxied Cloudflare records (the base hostname and its wildcard — the
agent-network endpoint is a label minted beneath it at bootstrap). kubectl
converges the gateway: Traefik behind a TCP-mode DigitalOcean regional Load
Balancer (the only public surface, TCP 80/443, sources enforced as LB
firewall rules), the combined `netbird-server` on a CSI volume, the
dashboard in agent-network-only mode, and the NetBird reverse proxy in
private mode serving endpoint TLS from a wildcard certificate issued
launcher-side via DNS-01. A headless bootstrap reconciles the control plane
by stable name: admin account, endpoint, an Anthropic provider claiming two
models, a guardrail allowing one, per-group budget and token caps on the
agents peer group, and an account-wide ceiling. The agent image is built
in-cluster by kaniko — under a push credential that exists only for the
build — and consumed by digest.

The demo's product is a provable claim: the agent holds no API key, no
ServiceAccount token, no DNS, and no route anywhere but the tunnel — and
every request it makes arrives at the provider with its peer identity
attached, allowlisted, capped, and attributed in the access log. Acceptance
proves the negative space too: a Cilium canary before any secret enters the
cluster, raw probes around the SOCKS5 pod, CONNECT probes through it, denial
probes for the blocked and the unroutable model, an outside-the-overlay
probe that must draw the bare pre-identity 403, the LB firewall verified
through the DigitalOcean API, and a bounded disruption suite (pod deletes,
component restarts, a node drain) after which the whole claim is re-probed.

## Use

```sh
npx skills add getcolors/agent-network-doks@package-agent-network-doks-green
./green build              # render .colors/<profile>/ — no credentials needed
./green create --dry-run   # walk the workflow, skip every side effect
./green create             # converge for real
./green status             # cluster, certificate, endpoint, tunnel, usage
./green kubectl -- get pods -A
./green delete             # guarded; needs a one-run override
```

This package is **green only** (Clojure/Babashka,
`package-agent-network-doks-green`), like `walter`; `bb golden` renders the
fixture across both state backends and diffs byte for byte in place of a
cross-colour parity harness.

Credentials live in a gitignored `.envrc.private` as `COLORS_PAR_*`
variables; see
[`skills/package-agent-network-doks-green/references/configuration.md`](skills/package-agent-network-doks-green/references/configuration.md).
A deliberately fake `COLORS_PAR_ANTHROPIC_API_KEY` is a supported mode: the
acceptance gates then expect Anthropic's own 401 relayed through the proxy,
proving everything NetBird owns with nothing billable.

## Develop

```sh
cd green && bb test           # validation, tools, workflow
cd green && bb golden         # two backends (local, r2), byte for byte
cd green && bb golden:accept  # after an intended change — read the diff first
./scripts/golden.sh           # same, from the repository root
./scripts/launcher.sh         # launcher self-checks
cd green && bb pin            # stamp the payload after a push
```

The first consumer is
[`agent-network-doks-digitalocean`](https://github.com/getcolors/agent-network-doks-digitalocean).
The architectural siblings are
[`agent-network-k8s`](https://github.com/getcolors/agent-network-k8s) (the
same design proven on Vultr Kubernetes Engine, three colours) and
[`agent-network`](https://github.com/getcolors/agent-network) (the
single-node Docker parent that owns the control-plane contract).

## License

MIT
