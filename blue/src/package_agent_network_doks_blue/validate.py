"""Credential-free desired-state validation for the DOKS Agent Network demo,
the port of io.github.getcolors.agent-network-doks.validate. Depends only on
the SDK: like `k8s`, this package carries its own provider registry rather
than pinning ONCE for one lookup table.

Green renders its keys as Clojure keywords, so every message here carries the
same leading colon — the three colours must report identical errors for one
colors.yml.
"""

from __future__ import annotations

import re

from blue.cli import par_name

from . import utils

profile_par = par_name("profile")

providers = {
    "provider-compute": {
        "digitalocean": {"secrets": ["do-token"],
                         "tofu_env": {"do-token": "DIGITALOCEAN_TOKEN"}},
    },
    "provider-dns": {
        "cloudflare": {"secrets": ["cloudflare-api-token"], "tofu_env": {}},
    },
    "provider-backend": {
        "local": {"secrets": [], "tofu_env": {}},
        "s3": {"secrets": ["s3-access-key-id", "s3-secret-access-key"],
               "tofu_env": {"s3-access-key-id": "AWS_ACCESS_KEY_ID",
                            "s3-secret-access-key": "AWS_SECRET_ACCESS_KEY"}},
        "r2": {"secrets": ["r2-access-key-id", "r2-secret-access-key"],
               "tofu_env": {"r2-access-key-id": "AWS_ACCESS_KEY_ID",
                            "r2-secret-access-key": "AWS_SECRET_ACCESS_KEY"}},
    },
}

# Every key desired state must carry unconditionally. There is no
# `digitalocean-name`: the Compute Name Standard's optional override applies,
# and a colors.yml that omits it is complete and names the cluster, node
# pool, load balancer and a created registry after the profile. There is no
# pod- or service-CIDR key: DOKS subnets are outputs read back from the
# cluster, never inputs. `digitalocean-registry-tier` is conditionally
# required — create mode only — and validated separately.
required = [
    "profile", "workdir", "provider-compute", "provider-dns", "provider-backend",
    "compute-prevent-destroy",
    "agent-network-host", "agent-network-letsencrypt-email",
    "agent-network-admin-email", "agent-network-admin-name",
    "agent-network-provider-models", "agent-network-allowed-models",
    "agent-network-policy-budget-usd-per-day", "agent-network-policy-tokens-per-day",
    "agent-network-global-budget-usd-per-day", "agent-network-global-tokens-per-day",
    "agent-network-log-retention-days", "agent-network-log-level",
    "agent-network-server-image", "agent-network-dashboard-image",
    "agent-network-proxy-image", "agent-network-traefik-image",
    "agent-network-client-image", "agent-network-kaniko-image",
    "agent-network-agent-base-image",
    "agent-network-claude-code-version", "agent-network-privoxy-version",
    "agent-network-gost-version", "agent-network-gost-sha256",
    "agent-network-lego-version",
    "digitalocean-region", "doks-version", "digitalocean-node-size",
    "digitalocean-node-count", "digitalocean-http-sources",
]

image_keys = [
    "agent-network-server-image", "agent-network-dashboard-image",
    "agent-network-proxy-image", "agent-network-traefik-image",
    "agent-network-client-image", "agent-network-kaniko-image",
    "agent-network-agent-base-image",
]

_host_re = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")
_email_re = re.compile(r"^[^@\s]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")
# `tag@sha256:...` — the shape every image key here actually carries — pins
# both the human-readable version and the exact bytes.
_image_pinned_re = re.compile(r"^[^\s@]+(?::[^\s:@]+@sha256:[0-9a-f]{64}|:[^\s:@]+|@sha256:[0-9a-f]{64})$")
_cidr_re = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}$")
_version_re = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
# A Debian package version: upstream plus revision, e.g. 3.0.34-1.
_deb_version_re = re.compile(r"^[0-9][0-9A-Za-z.+~:-]*$")
_sha256_re = re.compile(r"^[0-9a-f]{64}$")
# DOKS version slugs are Kubernetes semver plus DO's build suffix:
# 1.36.3-do.2. The changelog sometimes prints x.y.z.do-v; the slug — the
# only form the API accepts — is always x.y.z-do.v.
_doks_version_re = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+-do\.[0-9]+$")
_model_id_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
# DigitalOcean resource names accept letters, digits, dashes and periods.
_do_name_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$")
# DOCR registry names: lowercase alphanumerics and hyphens.
_do_registry_re = re.compile(r"^[a-z0-9][a-z0-9-]{1,62}$")
registry_tiers = ("starter", "basic", "professional")


def missing(x) -> bool:
    return x is None or (isinstance(x, str) and not x.strip())


def placeholder(v) -> bool:
    """Absent, blank or REPLACE_ME all mean 'use the profile' (Compute Name
    Standard §2: presence is the only switch)."""
    return missing(v) or str(v).strip() == "REPLACE_ME"


def compute_name(opts: dict) -> str:
    """What this deployment calls its cluster. Every label — the node pool's,
    the load balancer's, a created registry's (lowercased, reduced to what
    DOCR accepts) — derives from this and never from the raw override key or
    a second copy of the profile (§3)."""
    override = opts.get("digitalocean-name")
    if placeholder(override):
        return str(opts.get("profile"))
    return str(override).strip()


def adopt_registry(opts: dict) -> bool:
    """Registry mode is keyed on `digitalocean-registry-name` alone: present
    means adopt the named existing registry; absent means create a
    profile-named one behind the tier-aware capacity preflight."""
    return not placeholder(opts.get("digitalocean-registry-name"))


def registry_name(opts: dict) -> str:
    """The registry this deployment pushes to and pulls from: the adopted
    name, or the compute name reduced to what DOCR accepts."""
    if adopt_registry(opts):
        return str(opts.get("digitalocean-registry-name")).strip()
    return utils.registry_name(compute_name(opts))


def registry_repository(opts: dict) -> str:
    """The one repository this deployment owns inside whichever registry was
    adopted or created — always the profile, so teardown can delete exactly
    it."""
    return str(opts.get("profile"))


def zone(opts: dict) -> str:
    """The Cloudflare zone the host and its wildcard belong to."""
    return utils.registrable_domain(opts.get("agent-network-host"))


def ipv4_cidr(s) -> bool:
    """A real IPv4 CIDR: shape, octets 0-255, prefix 0-32. The shape regex
    alone admits 999.999.999.999/99, which would fail late — after
    infrastructure exists — instead of at validation."""
    if not _cidr_re.fullmatch(str(s)):
        return False
    addr, prefix = str(s).split("/")
    octets = [int(o) for o in addr.split(".")]
    return all(0 <= o <= 255 for o in octets) and 0 <= int(prefix) <= 32


def provider_models(opts: dict) -> list[dict]:
    """The models the Anthropic provider claims, however YAML handed them
    over."""
    models = opts.get("agent-network-provider-models")
    return list(models) if isinstance(models, (list, tuple)) else []


def allowed_models(opts: dict) -> list[str]:
    models = opts.get("agent-network-allowed-models")
    return [str(m) for m in models] if isinstance(models, (list, tuple)) else []


def allowed_model(opts: dict) -> str | None:
    """The model every Claude Code knob is pinned to."""
    models = allowed_models(opts)
    return models[0] if models else None


def denied_claimed_model(opts: dict) -> str | None:
    """A model the provider claims but the guardrail does not allow — the
    guardrail-denial probe's negative case. Its existence is validated, so
    acceptance can rely on it."""
    allowed = set(allowed_models(opts))
    for m in provider_models(opts):
        if str(m.get("id")) not in allowed:
            return str(m.get("id"))
    return None


def pos_num(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x > 0


def model_errors(opts: dict) -> list[str]:
    models = provider_models(opts)
    allowed = allowed_models(opts)
    claimed = {str(m.get("id")) for m in models}
    errors: list[str] = []
    if not (isinstance(opts.get("agent-network-provider-models"), (list, tuple)) and models):
        errors.append(":agent-network-provider-models must be a non-empty list")
    for m in models:
        if missing(m.get("id")) or not _model_id_re.fullmatch(str(m.get("id"))):
            errors.append(":agent-network-provider-models entries must carry a model id")
    for m in models:
        if not (pos_num(m.get("input-per-1k")) and pos_num(m.get("output-per-1k"))):
            errors.append(f"model {m.get('id')} must carry positive input-per-1k and output-per-1k prices")
    if not (isinstance(opts.get("agent-network-allowed-models"), (list, tuple)) and allowed):
        errors.append(":agent-network-allowed-models must be a non-empty list")
    for m in allowed:
        if m not in claimed:
            errors.append(f":agent-network-allowed-models entry {m} is not claimed by the provider")
    # The demo's guardrail-denial probe needs a model that routing accepts
    # and the allowlist rejects. Without one, gate 3b has no negative case
    # and the guardrail is configured but never demonstrated.
    if models and allowed and all(str(m.get("id")) in set(allowed) for m in models):
        errors.append(":agent-network-provider-models must claim at least one model outside :agent-network-allowed-models")
    return errors


def registry_errors(opts: dict) -> list[str]:
    """The adopt-or-create contract. Create mode (no registry name) requires
    the tier; adopt mode rejects it — the subscription tier is account-global
    and an adopted registry's tier is not this deployment's to declare."""
    errors: list[str] = []
    if adopt_registry(opts):
        if not _do_registry_re.fullmatch(str(opts.get("digitalocean-registry-name")).strip()):
            errors.append(":digitalocean-registry-name must be lowercase alphanumerics and hyphens")
        if not missing(opts.get("digitalocean-registry-tier")):
            errors.append(":digitalocean-registry-tier is create-mode-only; remove it when adopting a registry via :digitalocean-registry-name")
    else:
        if missing(opts.get("digitalocean-registry-tier")):
            errors.append(":digitalocean-registry-tier is required when no :digitalocean-registry-name adopts an existing registry")
        if (not missing(opts.get("digitalocean-registry-tier"))
                and str(opts.get("digitalocean-registry-tier")) not in registry_tiers):
            errors.append(":digitalocean-registry-tier must be starter, basic, or professional")
        if not _do_registry_re.fullmatch(registry_name(opts)):
            errors.append(f"the profile-derived registry name {registry_name(opts)} is not a valid DOCR name")
    return errors


def env_errors(env: dict) -> list[str]:
    if str(env.get(profile_par) or ""):
        return [f"{profile_par} is set; profile must come from colors.yml only"]
    return []


def _entry(opts: dict, slot: str) -> dict | None:
    return providers.get(slot, {}).get(str(opts.get(slot)))


def state_errors(opts: dict) -> list[str]:
    errors: list[str] = []
    for k in required:
        if missing(opts.get(k)):
            errors.append(f":{k} is required")
    if opts.get("provider-compute") != "digitalocean":
        errors.append(":provider-compute must be digitalocean")
    if opts.get("provider-dns") != "cloudflare":
        errors.append(":provider-dns must be cloudflare")
    if opts.get("provider-backend") not in ("local", "s3", "r2"):
        errors.append(":provider-backend must be local, s3, or r2")
    if not isinstance(opts.get("compute-prevent-destroy"), bool):
        errors.append(":compute-prevent-destroy must be true or false")
    if (not missing(opts.get("agent-network-host"))
            and not _host_re.fullmatch(str(opts.get("agent-network-host")))):
        errors.append(":agent-network-host must be a fully qualified hostname")
    for k in ("agent-network-letsencrypt-email", "agent-network-admin-email"):
        v = opts.get(k)
        if not missing(v) and not _email_re.fullmatch(str(v)):
            errors.append(f":{k} must be an email address")
    for k in image_keys:
        v = opts.get(k)
        if not missing(v) and not _image_pinned_re.fullmatch(str(v)):
            errors.append(f":{k} must carry an explicit image tag or digest")
    # This package owns its manifests rather than following the upstream
    # installer, so nothing tells it when a floating tag moved underneath it.
    for k in image_keys:
        v = str(opts.get(k))
        if (v.endswith(":latest") or v.endswith(":main")
                or ":latest@" in v or ":main@" in v):
            errors.append(f":{k} must not track a floating tag; pin the version")
    for k in ("agent-network-claude-code-version", "agent-network-lego-version"):
        v = opts.get(k)
        if not missing(v) and not _version_re.fullmatch(str(v)):
            errors.append(f":{k} must be an exact x.y.z version")
    if not (missing(opts.get("agent-network-privoxy-version"))
            or _deb_version_re.fullmatch(str(opts.get("agent-network-privoxy-version")))):
        errors.append(":agent-network-privoxy-version must be an exact Debian package version")
    if not (missing(opts.get("agent-network-gost-version"))
            or _version_re.fullmatch(str(opts.get("agent-network-gost-version")))):
        errors.append(":agent-network-gost-version must be an exact x.y.z version")
    if not (missing(opts.get("agent-network-gost-sha256"))
            or _sha256_re.fullmatch(str(opts.get("agent-network-gost-sha256")))):
        errors.append(":agent-network-gost-sha256 must be the 64-hex sha256 of the release tarball")
    if not (missing(opts.get("doks-version"))
            or _doks_version_re.fullmatch(str(opts.get("doks-version")))):
        errors.append(":doks-version must be a DOKS slug like 1.36.3-do.2")
    node_count = opts.get("digitalocean-node-count")
    if not (missing(node_count)
            or (isinstance(node_count, int) and not isinstance(node_count, bool)
                and 1 <= node_count <= 16)):
        errors.append(":digitalocean-node-count must be an integer between 1 and 16")
    if not (missing(opts.get("agent-network-log-level"))
            or str(opts.get("agent-network-log-level")) in ("error", "warn", "info", "debug")):
        errors.append(":agent-network-log-level must be error, warn, info, or debug")
    # 7-90 mirrors the dashboard's own retention range; usage metering is
    # unconditional and unaffected.
    retention = opts.get("agent-network-log-retention-days")
    if not (missing(retention)
            or (isinstance(retention, int) and not isinstance(retention, bool)
                and 7 <= retention <= 90)):
        errors.append(":agent-network-log-retention-days must be an integer between 7 and 90")
    for k in ("agent-network-policy-budget-usd-per-day",
              "agent-network-policy-tokens-per-day",
              "agent-network-global-budget-usd-per-day",
              "agent-network-global-tokens-per-day"):
        v = opts.get(k)
        if not missing(v) and not pos_num(v):
            errors.append(f":{k} must be a positive number")
    # The global rule is the backstop: a policy cap above it would never bind
    # and the desired state would be lying about which limit is the ceiling.
    if (pos_num(opts.get("agent-network-policy-budget-usd-per-day"))
            and pos_num(opts.get("agent-network-global-budget-usd-per-day"))
            and opts.get("agent-network-policy-budget-usd-per-day")
            > opts.get("agent-network-global-budget-usd-per-day")):
        errors.append(":agent-network-policy-budget-usd-per-day must not exceed the global budget")
    if (pos_num(opts.get("agent-network-policy-tokens-per-day"))
            and pos_num(opts.get("agent-network-global-tokens-per-day"))
            and opts.get("agent-network-policy-tokens-per-day")
            > opts.get("agent-network-global-tokens-per-day")):
        errors.append(":agent-network-policy-tokens-per-day must not exceed the global token cap")
    if any(not missing(v) for v in (opts.get("agent-network-provider-models"),
                                    opts.get("agent-network-allowed-models"))):
        errors.extend(model_errors(opts))
    errors.extend(registry_errors(opts))
    srcs = opts.get("digitalocean-http-sources")
    if (not missing(srcs)
            and (not isinstance(srcs, (list, tuple)) or not srcs
                 or any(not ipv4_cidr(s) for s in srcs))):
        errors.append(":digitalocean-http-sources must be a non-empty list of IPv4 CIDRs")
    # The override is validated against the provider's rules rather than
    # passed through unread (Compute Name Standard §2).
    if not (placeholder(opts.get("digitalocean-name"))
            or _do_name_re.fullmatch(str(opts.get("digitalocean-name")).strip())):
        errors.append(":digitalocean-name must be letters, digits, dot or dash")
    return errors


def backend_secrets(opts: dict) -> list[str]:
    entry = _entry(opts, "provider-backend")
    return entry["secrets"] if entry else []


# What talking to the providers needs, on any real event.
provider_secrets = ["do-token", "cloudflare-api-token"]

# What converging the cluster needs, and therefore only a create.
#
# One entry, deliberately. Everything else this deployment holds is generated
# in-cluster and supplied by nobody: the relay auth secret, the datastore
# encryption key, the session cookie key, the proxy access token, the local
# admin password, the durable automation token, and the agent's one-off setup
# key. The Anthropic key is the exception because it authenticates against an
# account this cluster does not own; it is handed to NetBird's encrypted store
# at converge time and the agent pod never sees it.
application_secrets = ["anthropic-api-key"]


def secret_errors(opts: dict, event: str) -> list[str]:
    """Credentials a real event needs. A delete tears down infrastructure with
    the provider credentials alone: this deployment is disposable by design,
    holds nothing worth a final archive, and demanding the Anthropic key to
    destroy a cluster would just be a lock on the exit."""
    keys = (provider_secrets
            + (application_secrets if event == "create" else [])
            + backend_secrets(opts))
    seen: list[str] = []
    for k in keys:
        if k not in seen:
            seen.append(k)
    return [f"required credential is not set: {par_name(k)}"
            for k in seen if missing(opts.get(k))]


def tofu_env(opts: dict, slot: str) -> dict[str, str]:
    if slot == "provider-compute":
        return {"do-token": "DIGITALOCEAN_TOKEN"}
    if slot == "provider-dns":
        return {"cloudflare-api-token": "CLOUDFLARE_API_TOKEN"}
    if slot == "provider-backend":
        entry = _entry(opts, "provider-backend")
        return entry["tofu_env"] if entry else {}
    return {}
