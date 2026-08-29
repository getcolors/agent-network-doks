"""DOKS Agent Network lifecycle DAG and package-specific remote-state advice,
the port of io.github.getcolors.agent-network-doks.workflow."""

from __future__ import annotations

from blue import dry_run, progress, tofu
from blue.cli import par_name, read_pars
from blue.lifecycle import preflight
from blue.workflow import advice_add, workflow

from . import tools, validate

LIFECYCLE_EVENTS = ("create", "delete")

DEFAULTS = {"provider-compute": "digitalocean",
            "provider-dns": "cloudflare",
            "provider-backend": "local",
            "compute-prevent-destroy": True,
            "workdir": ".colors"}


async def start_step(opts: dict, env: dict | None = None) -> dict:
    return await preflight(
        opts, defaults=DEFAULTS, overlay=read_pars, env=env,
        validators=[
            lambda _o, e, _c: validate.env_errors(e),
            lambda o, _e, _c: validate.state_errors(o),
            lambda o, _e, c: (validate.secret_errors(o, str(c["event"]))
                              if c["real"] and c["event"] in LIFECYCLE_EVENTS else []),
            lambda o, _e, c: ([f"compute destruction is protected; set "
                               f"{par_name('compute-prevent-destroy')}=false to delete"]
                              if c["real"] and c["event"] == "delete"
                              and o.get("compute-prevent-destroy") else []),
        ])


def wire_fn(step: str, run_opts: dict):
    if run_opts.get("blue/event") == "delete":
        # In-cluster teardown first: the CSI volumes and the CCM-created load
        # balancer are Kubernetes-managed and invisible to the infrastructure
        # state, so destroying the cluster before removing them would orphan
        # them in the account. Local access material goes last — the
        # kubeconfig is needed by the teardown and dead only after the
        # destroy.
        return {
            "agent-network-doks/start": (start_step, "agent-network-doks/teardown"),
            "agent-network-doks/teardown": (tools.teardown_step, "agent-network-doks/dns"),
            "agent-network-doks/dns": (tools.dns_step, "agent-network-doks/infrastructure"),
            "agent-network-doks/infrastructure": (tools.infrastructure_step, "agent-network-doks/cleanup"),
            "agent-network-doks/cleanup": (tools.cleanup_step,),
        }.get(step)
    # Create: the cluster first; then the workloads (the edge and the proxy
    # are applied but deliberately not awaited — they mount a TLS Secret
    # that does not exist yet); DNS once the load balancer has an address;
    # the certificate once DNS can answer DNS-01; then the control plane,
    # the two-pod application, and the gates.
    return {
        "agent-network-doks/start": (start_step, "agent-network-doks/infrastructure"),
        "agent-network-doks/infrastructure": (tools.infrastructure_step, "agent-network-doks/deploy"),
        "agent-network-doks/deploy": (tools.deploy_step, "agent-network-doks/dns"),
        "agent-network-doks/dns": (tools.dns_step, "agent-network-doks/certificate"),
        "agent-network-doks/certificate": (tools.certificate_step, "agent-network-doks/bootstrap"),
        "agent-network-doks/bootstrap": (tools.bootstrap_step, "agent-network-doks/agent"),
        "agent-network-doks/agent": (tools.agent_step, "agent-network-doks/acceptance"),
        "agent-network-doks/acceptance": (tools.acceptance_step,),
    }.get(step)


def backend_advice(tool: str):
    return tofu.conventional_backend_advice(
        dir=lambda o, tool=tool: tools.tool_dir(o, tool),
        key=lambda o, tool=tool: f"{'' if o.get('profile') is None else o.get('profile')}/{tool}.tfstate")


side_effecting_steps = [
    "agent-network-doks/infrastructure", "agent-network-doks/deploy",
    "agent-network-doks/dns", "agent-network-doks/certificate",
    "agent-network-doks/bootstrap", "agent-network-doks/agent",
    "agent-network-doks/acceptance", "agent-network-doks/teardown",
    "agent-network-doks/cleanup",
]


def create_workflow():
    wf = workflow(start="agent-network-doks/start", wire_fn=wire_fn)
    wf = advice_add(wf, "agent-network-doks/infrastructure", "before",
                    "io.github.getcolors.agent-network-doks.workflow/backend",
                    backend_advice(tools.infrastructure_tool))
    wf = advice_add(wf, "agent-network-doks/dns", "before",
                    "io.github.getcolors.agent-network-doks.workflow/backend",
                    backend_advice(tools.dns_tool))
    wf = progress.advise(wf)
    wf = dry_run.advise(wf, side_effecting_steps)
    return wf


agent_network_doks_workflow = create_workflow()
