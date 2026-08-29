// DOKS Agent Network lifecycle DAG and package-specific remote-state advice,
// the port of io.github.getcolors.agent-network-doks.workflow.

import { readPars, parName } from "red/cli";
import * as dryRun from "red/dry-run";
import { preflight } from "red/lifecycle";
import * as progress from "red/progress";
import * as tofu from "red/tofu";
import { adviceAdd, workflow, type Opts, type WireDecl } from "red/workflow";
import * as tools from "./tools.ts";
import * as validate from "./validate.ts";

export const defaults: Opts = {
  "provider-compute": "digitalocean",
  "provider-dns": "cloudflare",
  "provider-backend": "local",
  "compute-prevent-destroy": true,
  workdir: ".colors",
};

const lifecycleEvents = ["create", "delete"];

export async function startStep(
  opts: Opts,
  env: Record<string, string | undefined> = process.env,
): Promise<Opts> {
  return preflight(opts, {
    defaults,
    overlay: readPars,
    validators: [
      (_opts, environment) => validate.envErrors(environment),
      (current) => validate.stateErrors(current),
      (current, _environment, { event, real }) =>
        real && lifecycleEvents.includes(String(event))
          ? validate.secretErrors(current, String(event))
          : [],
      (current, _environment, { event, real }) =>
        real && event === "delete" && current["compute-prevent-destroy"]
          ? ["compute destruction is protected; set " +
             `${parName("compute-prevent-destroy")}=false to delete`]
          : [],
    ],
  }, env);
}

export function wireFn(step: string, runOpts: Opts): WireDecl | undefined {
  if (runOpts["red/event"] === "delete") {
    // In-cluster teardown first: the CSI volumes and the CCM-created load
    // balancer are Kubernetes-managed and invisible to the infrastructure
    // state, so destroying the cluster before removing them would orphan
    // them in the account. Local access material goes last — the kubeconfig
    // is needed by the teardown and dead only after the destroy.
    const graph: Record<string, WireDecl> = {
      "agent-network-doks/start": [startStep, "agent-network-doks/teardown"],
      "agent-network-doks/teardown": [tools.teardownStep, "agent-network-doks/dns"],
      "agent-network-doks/dns": [tools.dnsStep, "agent-network-doks/infrastructure"],
      "agent-network-doks/infrastructure": [tools.infrastructureStep, "agent-network-doks/cleanup"],
      "agent-network-doks/cleanup": [tools.cleanupStep],
    };
    return graph[step];
  }
  // Create: the cluster first; then the workloads (the edge and the proxy
  // are applied but deliberately not awaited — they mount a TLS Secret
  // that does not exist yet); DNS once the load balancer has an address;
  // the certificate once DNS can answer DNS-01; then the control plane,
  // the two-pod application, and the gates.
  const graph: Record<string, WireDecl> = {
    "agent-network-doks/start": [startStep, "agent-network-doks/infrastructure"],
    "agent-network-doks/infrastructure": [tools.infrastructureStep, "agent-network-doks/deploy"],
    "agent-network-doks/deploy": [tools.deployStep, "agent-network-doks/dns"],
    "agent-network-doks/dns": [tools.dnsStep, "agent-network-doks/certificate"],
    "agent-network-doks/certificate": [tools.certificateStep, "agent-network-doks/bootstrap"],
    "agent-network-doks/bootstrap": [tools.bootstrapStep, "agent-network-doks/agent"],
    "agent-network-doks/agent": [tools.agentStep, "agent-network-doks/acceptance"],
    "agent-network-doks/acceptance": [tools.acceptanceStep],
  };
  return graph[step];
}

export function backendAdvice(tool: string) {
  return tofu.conventionalBackendAdvice({
    dir: (opts) => tools.toolDir(opts, tool),
    key: (opts) => `${opts.profile ?? ""}/${tool}.tfstate`,
  });
}

export const sideEffectingSteps = [
  "agent-network-doks/infrastructure", "agent-network-doks/deploy",
  "agent-network-doks/dns", "agent-network-doks/certificate",
  "agent-network-doks/bootstrap", "agent-network-doks/agent",
  "agent-network-doks/acceptance", "agent-network-doks/teardown",
  "agent-network-doks/cleanup",
];

function create() {
  let wf = workflow({ start: "agent-network-doks/start", wireFn });
  wf = adviceAdd(wf, "agent-network-doks/infrastructure", "before",
    "io.github.getcolors.agent-network-doks.workflow/backend",
    backendAdvice(tools.infrastructureTool));
  wf = adviceAdd(wf, "agent-network-doks/dns", "before",
    "io.github.getcolors.agent-network-doks.workflow/backend",
    backendAdvice(tools.dnsTool));
  wf = progress.advise(wf);
  wf = dryRun.advise(wf, sideEffectingSteps);
  return wf;
}

export const agentNetworkDoksWorkflow = create();
