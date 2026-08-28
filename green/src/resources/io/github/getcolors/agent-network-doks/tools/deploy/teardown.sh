#!/usr/bin/env bash
# Ordered in-cluster teardown before the infrastructure destroy. The CSI
# volumes and the CCM-created load balancer are Kubernetes-managed and
# invisible to the infrastructure state; destroying the cluster first would
# orphan them in the account. Order: workloads → PVCs (waiting for the
# volumes to leave) → the LB Service (waiting for the LB to leave) →
# namespaces. Best-effort throughout: a cluster that stopped answering must
# not block the destroy that removes it.
set -uo pipefail

GW=agent-network-gateway
AG=agent-network-agent
BLD=agent-network-build

log() { echo "agent-network-doks-teardown: $*" >&2; }

if ! kubectl version --request-timeout=15s >/dev/null 2>&1; then
  log "cluster does not answer; leaving teardown to the infrastructure destroy"
  exit 0
fi

# Captured BEFORE anything is deleted: the CSI volume handles and the LB
# address are what the DigitalOcean API is asked to confirm absent afterwards —
# Kubernetes objects disappearing proves nothing about the paid resources
# behind them.
volume_ids=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null | grep . || true)
lb_ip=$(kubectl -n "$GW" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

log "deleting application and build namespaces"
kubectl delete namespace "$AG" "$BLD" --ignore-not-found --timeout=300s || true

log "deleting gateway workloads"
kubectl -n "$GW" delete statefulset --all --ignore-not-found --timeout=300s || true
kubectl -n "$GW" delete deployment --all --ignore-not-found --timeout=300s || true

log "deleting PVCs and waiting for the CSI volumes to leave"
kubectl -n "$GW" delete pvc --all --ignore-not-found --timeout=300s || true
for _ in $(seq 1 60); do
  pvs=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
  [[ ${pvs:-0} -eq 0 ]] && break
  sleep 10
done
pvs=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
[[ ${pvs:-0} -eq 0 ]] || log "WARNING: $pvs PersistentVolumes remain; check for orphaned block volumes after the destroy"

log "deleting the load balancer Service and waiting for the LB to leave"
kubectl -n "$GW" delete service traefik --ignore-not-found --timeout=120s || true
for _ in $(seq 1 30); do
  kubectl -n "$GW" get service traefik >/dev/null 2>&1 || break
  sleep 10
done

log "deleting the gateway namespace"
kubectl delete namespace "$GW" --ignore-not-found --timeout=300s || true

# The provider is the authority on what still bills. Best-effort (the tofu
# destroy that follows removes the cluster either way), but leftovers are
# surfaced loudly rather than assumed gone.
# An API failure is NOT absence: only a successful listing that lacks the
# resource counts as gone; anything else is surfaced as unverified.
do_api() { curl -fsS -H "Authorization: Bearer ${COLORS_PAR_DO_TOKEN:-}" "https://api.digitalocean.com/v2$1"; }
if [[ -n ${COLORS_PAR_DO_TOKEN:-} ]]; then
  if [[ -n ${volume_ids:-} ]]; then
    verdict="unverified"
    for _ in $(seq 1 30); do
      if live=$(do_api "/volumes?per_page=200" 2>/dev/null | jq -r '.volumes[].id' 2>/dev/null); then
        leftover=$(comm -12 <(sort <<<"$volume_ids") <(sort <<<"$live") | grep . || true)
        if [[ -z $leftover ]]; then verdict="absent"; break; else verdict="present"; fi
      fi
      sleep 10
    done
    case $verdict in
      absent) log "block volumes confirmed absent at the provider" ;;
      present) log "WARNING: block volumes still in the account: $leftover — delete them manually" ;;
      *) log "WARNING: could not verify volume deletion against the DigitalOcean API — check manually" ;;
    esac
  fi
  if [[ -n ${lb_ip:-} ]]; then
    verdict="unverified"
    for _ in $(seq 1 30); do
      if lbs=$(do_api "/load_balancers?per_page=200" 2>/dev/null); then
        if jq -e --arg ip "$lb_ip" '.load_balancers[] | select(.ip==$ip)' <<<"$lbs" >/dev/null 2>&1
        then verdict="present"
        else verdict="absent"; break
        fi
      fi
      sleep 10
    done
    case $verdict in
      absent) log "load balancer confirmed absent at the provider" ;;
      present) log "WARNING: the load balancer at $lb_ip is still in the account — delete it manually" ;;
      *) log "WARNING: could not verify load-balancer deletion against the DigitalOcean API — check manually" ;;
    esac
  fi

  # The profile repository is the one piece of the registry this deployment
  # owns in ADOPT mode, where the infrastructure destroy will not touch the
  # registry at all; delete exactly it, idempotently (404 = already gone).
  # In create mode the whole registry falls to the tofu destroy.
  if [[ -n ${STATE_DIR:-} && -f $STATE_DIR/registry.env ]]; then
    # shellcheck disable=SC1091
    source "$STATE_DIR/registry.env" 2>/dev/null || true
    if [[ ${REGISTRY_ADOPTED:-false} == true && -n ${REGISTRY_NAME:-} && -n ${REGISTRY_REPO:-} ]]; then
      log "deleting the $REGISTRY_REPO repository from adopted registry $REGISTRY_NAME"
      code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer ${COLORS_PAR_DO_TOKEN}" \
        "https://api.digitalocean.com/v2/registry/$REGISTRY_NAME/repositories/$REGISTRY_REPO" || true)
      case ${code:-000} in
        204|404) log "repository gone (HTTP $code)" ;;
        *) log "WARNING: repository deletion answered HTTP ${code:-000} — check manually" ;;
      esac
    fi
  fi
fi

log "teardown complete"
