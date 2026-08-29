// The port of green's tools-test, validate-test and workflow-test: the three
// colours assert the same behaviour over the same fixture.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { scaffold } from "red/scaffold";
import type { Opts } from "red/workflow";
import * as tools from "../src/tools.ts";
import * as validate from "../src/validate.ts";
import { sideEffectingSteps, startStep, wireFn } from "../src/workflow.ts";

const fixturePath = join(import.meta.dir, "..", "..", "test", "fixtures", "colors.yml");

function fixture(): Opts {
  return {
    ...(Bun.YAML.parse(readFileSync(fixturePath, "utf8")) as Opts),
    "red/state-file": fixturePath,
  };
}

// ------------------------------------------------------------------- tools

describe("dns records", () => {
  test("base and wildcard, both unproxied, both at the LB", () => {
    const doc = JSON.parse(tools.dnsJson({ ...fixture(), "lb-ip": "203.0.113.9" }));
    const records = doc.resource.cloudflare_dns_record;
    const base = records.agent_network_doks;
    const wild = records.agent_network_doks_wildcard;
    expect(base.name).toBe("agent-network-doks.example.com");
    expect(wild.name).toBe("*.agent-network-doks.example.com");
    expect(base.content).toBe("203.0.113.9");
    expect(wild.content).toBe("203.0.113.9");
    expect(base.proxied).toBe(false);
    expect(wild.proxied).toBe(false);
  });
});

describe("desired document", () => {
  const doc = JSON.parse(tools.desiredJson(fixture()));
  test("the catalog provider id, not the bare name (422 otherwise)", () => {
    expect(doc.provider.provider_id).toBe("anthropic_api");
  });
  test("two claimed models, one allowed — both denial classes derivable", () => {
    expect(doc.provider.models.length).toBe(2);
    expect(doc.allowed_models).toEqual(["claude-haiku-4-5-20251001"]);
  });
  test("caps and retention travel", () => {
    expect(doc.policy.budget_usd_per_day).toBe(2);
    expect(doc.global.tokens_per_day).toBe(5000000);
    expect(doc.log_retention_days).toBe(7);
  });
  test("no secret has any business here", () => {
    expect(tools.desiredJson(fixture())).not.toContain("api_key");
  });
});

describe("deploy rendering", () => {
  const opts = { ...fixture(), workdir: join(tmpdir(), `an-doks-test-${Date.now()}-${Math.random()}`) };
  const specs = tools.deploySpecs(opts);
  const rendered = scaffold({ ...opts, "red/event": "create" }, specs);
  const written = rendered["red.scaffold/written"] as string[];
  const slurpTarget = (suffix: string) =>
    readFileSync(written.find((p) => p.endsWith(suffix))!, "utf8");

  test("every deploy file renders", () => {
    expect(written.length).toBe(tools.deployFiles.length + 2);
  });
  test("the host reaches the scripts and manifests", () => {
    expect(slurpTarget("bootstrap.sh")).toContain("agent-network-doks.example.com");
    expect(slurpTarget("manifests/proxy.yaml")).toContain("NB_PROXY_DOMAIN");
    expect(slurpTarget("traefik-dynamic.yaml")).toContain("HostSNIRegexp");
  });
  test("the passthrough matches subdomains only, never the bare base name", () => {
    const dyn = slurpTarget("traefik-dynamic.yaml");
    expect(dyn).toContain("HostSNIRegexp(`^[a-z0-9-]+\\.agent-network-doks\\.example\\.com$`)");
    // No router may carry the catch-all rule (the comment may name it).
    expect(/rule:.*HostSNI\(`\*`\)/.test(dyn)).toBe(false);
  });
  test("every model knob is pinned in both agent variants", () => {
    for (const variant of ["manifests/agent-primary.yaml", "manifests/agent-fallback.yaml"]) {
      const content = slurpTarget(variant);
      for (const knob of ["ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
                          "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                          "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"]) {
        expect(content).toContain(knob);
      }
      expect(content).toContain("claude-haiku-4-5-20251001");
    }
  });
  test("the agent pod mounts no ServiceAccount token and no DNS path", () => {
    expect(slurpTarget("manifests/agent-primary.yaml"))
      .toContain("automountServiceAccountToken: false");
  });
  test("the LB is pinned to the regional TCP type with enforced sources", () => {
    const svc = slurpTarget("manifests/traefik.yaml");
    expect(svc).toContain('do-loadbalancer-protocol: "tcp"');
    expect(svc).toContain('do-loadbalancer-type: "REGIONAL"');
    expect(svc).toContain('do-loadbalancer-name: "agent-network-doks-fixture"');
    expect(svc).toContain("loadBalancerSourceRanges: [0.0.0.0/0]");
  });
  test("CIDR-derived values stay placeholders for the read-back subnet", () => {
    expect(slurpTarget("netbird-config.yaml")).toContain("__POD_CIDR__");
    expect(slurpTarget("manifests/proxy.yaml")).toContain("__POD_CIDR__");
  });
  test("the client entry is state-aware: reconnect without a key", () => {
    const entry = slurpTarget("socks-entry.sh");
    expect(entry).toContain("reconnecting without a key");
    expect(entry).toContain("--setup-key-file");
  });
  test("the one-off key never becomes a Kubernetes Secret", () => {
    const bootstrap = slurpTarget("bootstrap.sh");
    expect(bootstrap).toContain("/dev/shm");
    expect(/create secret.*setup/.test(bootstrap)).toBe(false);
  });
});

describe("per-profile paths", () => {
  const opts = fixture();
  test("kubeconfig and state live under the profile directory", () => {
    expect(tools.kubeconfigPath(opts).endsWith("agent-network-doks-fixture/kubeconfig")).toBe(true);
    expect(tools.stateDir(opts).endsWith("agent-network-doks-fixture/state")).toBe(true);
  });
});

describe("cidr splitting", () => {
  test("lists pass through, strings split", () => {
    expect(tools.cidrs({ "digitalocean-http-sources": ["1.2.3.0/24", "5.6.7.0/24"] }, "digitalocean-http-sources"))
      .toEqual(["1.2.3.0/24", "5.6.7.0/24"]);
    expect(tools.cidrs({ "digitalocean-http-sources": "1.2.3.0/24" }, "digitalocean-http-sources"))
      .toEqual(["1.2.3.0/24"]);
  });
});

describe("infrastructure templates", () => {
  const res = (name: string) =>
    readFileSync(join(import.meta.dir, "..", "resources", "tools", "infrastructure", name), "utf8");
  test("the kubeconfig contract is DO-shaped, HA explicit, subnets never inputs", () => {
    const tf = res("main.tf");
    expect(tf).toContain("kube_config[0].raw_config");
    expect(tf).toContain("ha = false");
    expect(tf).not.toContain("cluster_subnet =");
    expect(tf).not.toContain("service_subnet =");
    expect(tf).toContain('output "cluster-subnet"');
  });
  test("both registry modes: credentials hang off the registry reference and rotate", () => {
    for (const f of ["registry-create.tf", "registry-adopt.tf"]) {
      const tf = res(f);
      expect(tf).toContain("local.registry_name");
      expect(tf).toContain("expiry_seconds");
      expect(tf).toContain("replace_triggered_by");
    }
    expect(res("registry-adopt.tf")).toContain('data "digitalocean_container_registry"');
    expect(res("registry-create.tf")).toContain('resource "digitalocean_container_registry"');
    expect(res("registry-adopt.tf")).not.toContain('resource "digitalocean_container_registry" ');
  });
});

// ---------------------------------------------------------------- validate

describe("validate", () => {
  test("fixture is valid", () => {
    expect(validate.stateErrors(fixture())).toEqual([]);
  });
  test("required keys are enforced", () => {
    for (const k of validate.required) {
      const opts = fixture();
      delete opts[k];
      const errors = validate.stateErrors(opts);
      expect(errors.some((e) => e.includes(`:${k}`))).toBe(true);
    }
  });
  test("env guard", () => {
    expect(validate.envErrors({})).toEqual([]);
    expect(validate.envErrors({ COLORS_PAR_PROFILE: "other" }).length).toBeGreaterThan(0);
  });
  test("a floating tag is refused", () => {
    for (const bad of ["netbirdio/netbird:latest", "netbirdio/netbird:main",
                       "netbirdio/netbird:latest@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451"]) {
      expect(validate.stateErrors({ ...fixture(), "agent-network-client-image": bad }).length)
        .toBeGreaterThan(0);
    }
  });
  test("a bare repository means :latest by implication and is refused", () => {
    expect(validate.stateErrors({ ...fixture(), "agent-network-client-image": "netbirdio/netbird" }).length)
      .toBeGreaterThan(0);
  });
  test("the allowlist must be claimed", () => {
    expect(validate.modelErrors({ ...fixture(), "agent-network-allowed-models": ["not-claimed"] }).length)
      .toBeGreaterThan(0);
  });
  test("at least one claimed model must sit outside the allowlist", () => {
    expect(validate.modelErrors({
      ...fixture(),
      "agent-network-allowed-models": ["claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929"],
    }).length).toBeGreaterThan(0);
  });
  test("the denial probe's negative case is derivable", () => {
    expect(validate.deniedClaimedModel(fixture())).toBe("claude-sonnet-4-5-20250929");
    expect(validate.allowedModel(fixture())).toBe("claude-haiku-4-5-20251001");
  });
  test("budget ceilings", () => {
    expect(validate.stateErrors({ ...fixture(), "agent-network-policy-budget-usd-per-day": 50 }).length)
      .toBeGreaterThan(0);
    expect(validate.stateErrors({ ...fixture(), "agent-network-policy-tokens-per-day": 99999999 }).length)
      .toBeGreaterThan(0);
  });
  test("doks version shape", () => {
    expect(validate.stateErrors({ ...fixture(), "doks-version": "1.34.1-do.0" })).toEqual([]);
    for (const bad of ["v1.35.2+1", "1.36.3", "1.36.3.do-2", "latest"]) {
      expect(validate.stateErrors({ ...fixture(), "doks-version": bad }).length)
        .toBeGreaterThan(0);
    }
  });
  test("create mode requires the tier", () => {
    const noTier = fixture();
    delete noTier["digitalocean-registry-tier"];
    expect(validate.stateErrors(noTier).length).toBeGreaterThan(0);
    expect(validate.stateErrors({ ...fixture(), "digitalocean-registry-tier": "gold" }).length)
      .toBeGreaterThan(0);
  });
  test("adopt mode rejects the tier and validates the name", () => {
    const adopt: Opts = { ...fixture(), "digitalocean-registry-name": "existing-registry" };
    delete adopt["digitalocean-registry-tier"];
    expect(validate.stateErrors(adopt)).toEqual([]);
    expect(validate.adoptRegistry(adopt)).toBe(true);
    expect(validate.registryName(adopt)).toBe("existing-registry");
    expect(validate.stateErrors({ ...adopt, "digitalocean-registry-tier": "basic" }).length)
      .toBeGreaterThan(0);
    expect(validate.stateErrors({ ...adopt, "digitalocean-registry-name": "Bad_Name" }).length)
      .toBeGreaterThan(0);
  });
  test("the owned repository is always the profile", () => {
    expect(validate.registryRepository(fixture())).toBe("agent-network-doks-fixture");
  });
  test("the compute name defaults to the profile (Compute Name Standard)", () => {
    expect(validate.computeName(fixture())).toBe("agent-network-doks-fixture");
    expect(validate.computeName({ ...fixture(), "digitalocean-name": "custom" })).toBe("custom");
    expect(validate.computeName({ ...fixture(), "digitalocean-name": "REPLACE_ME" }))
      .toBe("agent-network-doks-fixture");
  });
  test("the registry name is the compute name reduced to what DOCR accepts", () => {
    expect(validate.registryName(fixture())).toBe("agent-network-doks-fixture");
    expect(validate.registryName({ profile: "Mixed_Case!" })).toBe("mixedcase");
  });
  test("zone derivation", () => {
    expect(validate.zone(fixture())).toBe("example.com");
  });
  test("create needs the providers, the backend and the Anthropic key", () => {
    const errors = validate.secretErrors({ ...fixture(), "provider-backend": "r2" }, "create");
    for (const v of ["COLORS_PAR_DO_TOKEN", "COLORS_PAR_CLOUDFLARE_API_TOKEN",
                     "COLORS_PAR_ANTHROPIC_API_KEY", "COLORS_PAR_R2_ACCESS_KEY_ID"]) {
      expect(errors.some((e) => e.includes(v))).toBe(true);
    }
  });
  test("delete never demands the Anthropic key", () => {
    const errors = validate.secretErrors(fixture(), "delete");
    expect(errors.some((e) => e.includes("ANTHROPIC"))).toBe(false);
  });
  test("gost pin shape", () => {
    expect(validate.stateErrors({ ...fixture(), "agent-network-gost-sha256": "abc" }).length)
      .toBeGreaterThan(0);
    expect(validate.stateErrors({ ...fixture(), "agent-network-gost-version": "3.2" }).length)
      .toBeGreaterThan(0);
  });
  test("http sources are real CIDRs", () => {
    expect(validate.stateErrors({ ...fixture(), "digitalocean-http-sources": ["10.0.0.0/8", "0.0.0.0/0"] }))
      .toEqual([]);
    for (const bad of [["999.999.999.999/99"], ["1.2.3.4/33"], ["1.2.3.256/8"], ["::/0"], ["1.2.3.4"]]) {
      expect(validate.stateErrors({ ...fixture(), "digitalocean-http-sources": bad }).length)
        .toBeGreaterThan(0);
    }
  });
});

// ---------------------------------------------------------------- workflow

function chain(event: string): string[] {
  const steps: string[] = [];
  let step = "agent-network-doks/start";
  for (;;) {
    const decl = wireFn(step, { "red/event": event });
    const next = decl?.[1];
    if (!next) return steps;
    steps.push(next);
    step = next;
  }
}

describe("workflow", () => {
  test("create ordering: cluster → workloads → dns → certificate → bootstrap → agent → gates", () => {
    expect(chain("create")).toEqual([
      "agent-network-doks/infrastructure", "agent-network-doks/deploy",
      "agent-network-doks/dns", "agent-network-doks/certificate",
      "agent-network-doks/bootstrap", "agent-network-doks/agent",
      "agent-network-doks/acceptance",
    ]);
  });
  test("delete ordering: in-cluster teardown precedes the infrastructure destroy", () => {
    expect(chain("delete")).toEqual([
      "agent-network-doks/teardown", "agent-network-doks/dns",
      "agent-network-doks/infrastructure", "agent-network-doks/cleanup",
    ]);
  });
  test("every side-effecting step is dry-runnable", () => {
    const wired = new Set([...chain("create"), ...chain("delete")]);
    for (const step of wired) {
      expect(sideEffectingSteps).toContain(step);
    }
  });
  test("a valid fixture passes", async () => {
    const out = await startStep({ ...fixture(), "red/event": "build" }, {});
    expect(out["red/exit"]).toBe(0);
  });
  test("missing desired state aggregates every error at exit 2", async () => {
    const opts: Opts = { ...fixture(), "red/event": "build" };
    delete opts["agent-network-host"];
    delete opts["doks-version"];
    const out = await startStep(opts, {});
    expect(out["red/exit"]).toBe(2);
    expect(String(out["red/err"])).toContain(":agent-network-host");
    expect(String(out["red/err"])).toContain(":doks-version");
  });
  test("the profile guard refuses the overlay", async () => {
    const out = await startStep({ ...fixture(), "red/event": "build" },
                                { COLORS_PAR_PROFILE: "other" });
    expect(out["red/exit"]).toBe(2);
  });
  test("a real delete is refused while the guard stands", async () => {
    const out = await startStep({
      ...fixture(),
      "red/event": "delete",
      "do-token": "x",
      "cloudflare-api-token": "x",
    }, {});
    expect(out["red/exit"]).toBe(2);
    expect(String(out["red/err"])).toContain("COLORS_PAR_COMPUTE_PREVENT_DESTROY");
  });
});
