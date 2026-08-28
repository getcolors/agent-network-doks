#!/usr/bin/env bash
# Phase one of convergence, kubectl against the DOKS cluster: namespaces and
# Pod Security levels, the Cilium NetworkPolicy canary, create-once cluster
# secrets, the rendered server configuration, the registry credentials, the
# in-cluster kaniko build of the agent image (consumed by digest only), the
# gateway workloads, the proxy token (create-once), and the load balancer.
#
# Deliberately NOT here: waiting for Traefik or the reverse proxy — both
# mount the wildcard TLS Secret the certificate stage creates later, so
# awaiting them now would deadlock (they are applied, and awaited after the
# certificate exists). Every manifest passes a server-side dry run before the
# real apply, so an admission rejection names the manifest instead of
# surfacing as a half-applied stack.
set -euo pipefail

DIR=${DEPLOY_DIR:?}
MAN="$DIR/manifests"
STATE=${STATE_DIR:?}
GW=agent-network-gateway
AG=agent-network-agent
BLD=agent-network-build
CANARY=agent-network-canary
umask 077
mkdir -p "$STATE"

log() { echo "agent-network-doks-converge: $*" >&2; }

# Sanitized diagnostics gathered before a bounded wait gives up, so CCM
# rejections, LB health-check failures, Cilium denials and CSI attach stalls
# are diagnosable from the converge log instead of a bare timeout line.
evidence() {
  log "diagnostics ($1):"
  kubectl get nodes -o wide >&2 2>/dev/null || true
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -30 >&2 || true
  kubectl -n "$GW" get svc,pods -o wide >&2 2>/dev/null || true
  kubectl get pvc,pv -A >&2 2>/dev/null || true
}

# Registry facts and credentials arrive as private state files written by the
# infrastructure stage — never argv, never a rendered template. The docker
# configs are the provider-minted credential documents themselves.
# shellcheck disable=SC1091
source "$STATE/registry.env"
: "${REGISTRY_HOST:?no registry host; did the infrastructure stage run?}"
: "${REGISTRY_NAME:?no registry name; did the infrastructure stage run?}"
: "${REGISTRY_REPO:?no registry repository; did the infrastructure stage run?}"
[[ -s "$STATE/push-dockerconfig.json" ]] || { log "FATAL: no push credential; did the infrastructure stage run?"; exit 1; }
[[ -s "$STATE/pull-dockerconfig.json" ]] || { log "FATAL: no pull credential; did the infrastructure stage run?"; exit 1; }

# The cluster subnet is READ BACK from the DOKS resource by the
# infrastructure stage — never desired-state input — and substituted into
# everything CIDR-derived below.
POD_CIDR=$(cat "$STATE/cluster-subnet" 2>/dev/null || true)
[[ -n $POD_CIDR ]] || { log "FATAL: no read-back cluster subnet; did the infrastructure stage run?"; exit 1; }

# A freshly created DOKS cluster answers its API minutes after the resource
# exists, and nodes join later still; both are awaited, bounded, so a first
# converge does not fail on provider latency.
log "waiting for the cluster API server"
ok=0
for _ in $(seq 1 90); do
  kubectl version --request-timeout=10s >/dev/null 2>&1 && { ok=1; break; }
  sleep 10
done
[[ $ok == 1 ]] || { log "FATAL: the API server never answered"; exit 1; }
log "waiting for a Ready node"
ok=0
for _ in $(seq 1 90); do
  if kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | grep -q .; then ok=1; break; fi
  sleep 10
done
[[ $ok == 1 ]] || { evidence "no Ready node"; log "FATAL: no node became Ready"; exit 1; }

apply() { # apply FILE — server-side dry run first, then the real thing
  kubectl apply --dry-run=server -f "$1" >/dev/null \
    || { log "admission rejected $1"; exit 1; }
  kubectl apply -f "$1"
}

# --- the Cilium canary -------------------------------------------------------
#
# Before any secret or provider credential enters the cluster, this cluster's
# CNI must prove the NetworkPolicy semantics the agent's isolation stands on:
# default-deny holds, a single scoped allow admits exactly its path, and
# cross-namespace traffic outside an allow is dropped. DOKS ships Cilium and
# the docs say it enforces NetworkPolicy — this gate turns that claim into an
# observation on THIS cluster, once per converge, in a throwaway namespace.
# Recorded in the profile state after the first pass so re-converges skip the
# ~1 minute it costs.

if [[ ! -f $STATE/canary-passed ]]; then
  log "canary: proving NetworkPolicy enforcement (default-deny + single allow)"
  # The namespace is applied for real FIRST: a server-side dry run cannot
  # validate namespaced objects whose namespace only exists later in the
  # same document.
  kubectl apply -f - <<CANARYNS >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: $CANARY
  labels:
    pod-security.kubernetes.io/enforce: baseline
CANARYNS
  cat > "${TMPDIR:-/tmp}/an-canary.yaml" <<CANARY
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: $CANARY
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-probe
  namespace: $CANARY
spec:
  podSelector:
    matchLabels: {app: canary-listener}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: {app: canary-prober}
      ports:
        - {port: 18080, protocol: TCP}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-probe-egress
  namespace: $CANARY
spec:
  podSelector:
    matchLabels: {app: canary-prober}
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector:
            matchLabels: {app: canary-listener}
      ports:
        - {port: 18080, protocol: TCP}
---
apiVersion: v1
kind: Pod
metadata:
  name: canary-listener
  namespace: $CANARY
  labels: {app: canary-listener}
spec:
  automountServiceAccountToken: false
  containers:
    - name: listener
      image: netbirdio/netbird:0.77.1@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451
      command: ["/bin/sh", "-c", "while true; do printf ok | nc -l -p 18080; done"]
---
apiVersion: v1
kind: Pod
metadata:
  name: canary-prober
  namespace: $CANARY
  labels: {app: canary-prober}
spec:
  automountServiceAccountToken: false
  containers:
    - name: prober
      image: netbirdio/netbird:0.77.1@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451
      command: ["/bin/sh", "-c", "sleep 3600"]
CANARY
  apply "${TMPDIR:-/tmp}/an-canary.yaml"
  rm -f "${TMPDIR:-/tmp}/an-canary.yaml"
  kubectl -n "$CANARY" wait --for=condition=Ready pod/canary-listener pod/canary-prober --timeout=300s \
    || { evidence "canary pods"; log "FATAL: the canary pods never became Ready"; exit 1; }
  listener_ip=$(kubectl -n "$CANARY" get pod canary-listener -o jsonpath='{.status.podIP}')
  probe() { kubectl -n "$CANARY" exec canary-prober -- sh -c "nc -w 4 $1 $2 </dev/null" >/dev/null 2>&1; }
  if ! probe "$listener_ip" 18080; then
    evidence "canary allow"
    log "FATAL: the canary's single allowed path is not admitted; NetworkPolicy is not enforcing as required"
    exit 1
  fi
  if probe 1.1.1.1 443; then
    log "FATAL: the canary prober reached the internet under default-deny; NetworkPolicy is not enforced on this cluster"
    exit 1
  fi
  kube_dns=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "10.245.0.10")
  if probe "$kube_dns" 53; then
    log "FATAL: the canary prober reached kube-dns across namespaces under default-deny"
    exit 1
  fi
  kubectl delete namespace "$CANARY" --ignore-not-found --timeout=120s >/dev/null || true
  touch "$STATE/canary-passed"
  log "canary passed: default-deny holds, the single allow admits exactly its path"
fi

# --- namespaces --------------------------------------------------------------

apply "$MAN/namespaces.yaml"

# --- create-once cluster secrets --------------------------------------------
#
# Create-once is what keeps the deployment alive: a regenerated datastore
# encryption key orphans the peer database, a regenerated session cookie key
# logs the admin out, a regenerated relay secret breaks relayed peers while
# every pod stays green. A converge finding them present touches nothing —
# the idempotency the parent package proved the hard way.

gen_secret() { # gen_secret NAME BYTES FILTER — FILTER strips what the consumer rejects
  if ! kubectl -n "$GW" get secret "$1" >/dev/null 2>&1; then
    log "generating create-once secret $1"
    openssl rand -base64 "$2" | tr -d "$3" \
      | kubectl -n "$GW" create secret generic "$1" --from-file=value=/dev/stdin >/dev/null
  fi
}
# The datastore and cookie keys must remain STRICT base64 — the server's
# field encryptor rejects unpadded input ("illegal base64 data") — so only
# newlines are stripped there; the relay secret is a plain shared string and
# drops padding like the parent's.
gen_secret an-relay-auth 32 '\n='
gen_secret an-session-cookie 32 '\n'
gen_secret an-datastore-key 32 '\n'
gen_secret an-admin-password 24 '\n='

read_secret() { kubectl -n "$GW" get secret "$1" -o jsonpath='{.data.value}' | base64 -d; }

# --- the server configuration -----------------------------------------------
#
# Substitution happens here rather than in the rendered template so the
# secrets never enter .colors/. The pod CIDR is substituted here too — a
# read-back run fact, not desired state. The final document is itself a
# Secret; a changed one restarts the server, an unchanged one restarts
# nothing.

tmpdir=$(mktemp -d /dev/shm/an-doks.XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
sed -e "s|__RELAY_AUTH_SECRET__|$(read_secret an-relay-auth)|" \
    -e "s|__SESSION_COOKIE_ENCRYPTION_KEY__|$(read_secret an-session-cookie)|" \
    -e "s|__DATASTORE_ENCRYPTION_KEY__|$(read_secret an-datastore-key)|" \
    -e "s|__POD_CIDR__|$POD_CIDR|" \
    "$DIR/netbird-config.yaml" > "$tmpdir/config.yaml"

new_sum=$(sha256sum "$tmpdir/config.yaml" | awk '{print $1}')
old_sum=$(kubectl -n "$GW" get secret netbird-server-config \
            -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d | sha256sum | awk '{print $1}' || true)
if [[ "$new_sum" != "$old_sum" ]]; then
  log "server configuration changed; applying"
  kubectl -n "$GW" create secret generic netbird-server-config \
    --from-file=config.yaml="$tmpdir/config.yaml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$GW" rollout restart statefulset/netbird-server 2>/dev/null || true
fi

# --- the pull credential, refreshed every converge ---------------------------
#
# The kubelet's pull — which bypasses pod NetworkPolicy by design — uses the
# long-lived read-only credential; re-applying it each converge is the
# rotation contract's second half. The PUSH credential is deliberately NOT
# installed here: it exists only inside the build branch below, under an
# EXIT trap, for exactly as long as kaniko needs it.

kubectl -n "$AG" create secret generic registry-pull \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$STATE/pull-dockerconfig.json" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- the gateway core --------------------------------------------------------

kubectl -n "$GW" create configmap traefik-dynamic \
  --from-file=dynamic.yaml="$DIR/traefik-dynamic.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

apply "$MAN/networkpolicies.yaml"
apply "$MAN/traefik.yaml"
apply "$MAN/netbird-server.yaml"
apply "$MAN/dashboard.yaml"

log "waiting for the NetBird server (readiness = OIDC discovery, probed by the kubelet)"
kubectl -n "$GW" rollout status statefulset/netbird-server --timeout=900s \
  || { evidence "netbird-server rollout"; exit 1; }
kubectl -n "$GW" rollout status deployment/dashboard --timeout=600s \
  || { evidence "dashboard rollout"; exit 1; }

# --- pod CIDR sanity ---------------------------------------------------------
#
# The read-back subnet is the authority; live pod addresses are the
# cross-check. A pod outside the subnet the API reported would mean the
# trusted-proxy ranges rendered above are silently wrong.

ip_to_int() { # dotted quad -> integer
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}
in_cidr() { # in_cidr IP CIDR
  local ip=$1 base=${2%/*} mask=${2#*/}
  [[ $(( $(ip_to_int "$ip") >> (32 - mask) )) -eq $(( $(ip_to_int "$base") >> (32 - mask) )) ]]
}
server_ip=$(kubectl -n "$GW" get pod -l app=netbird-server -o jsonpath='{.items[0].status.podIP}')
if ! in_cidr "$server_ip" "$POD_CIDR"; then
  log "FATAL: pod address $server_ip is outside the read-back cluster subnet $POD_CIDR"
  exit 1
fi

# --- the proxy access token, create-once -------------------------------------
#
# Preserved untouched while the Secret exists: a healthy converge never
# rotates a credential the running proxy depends on. Delete-by-name-before-
# create runs only on a fresh mint, so a crash between create and persist
# leaves an orphan the next run closes rather than an undiscoverable live
# token. The value travels a pipe-only path into the Secret.

admin() { kubectl -n "$GW" exec netbird-server-0 -- \
  /go/bin/netbird-server admin "$@" --config /etc/netbird/config.yaml; }
proxy_token_healthy() {
  # Healthy = the Secret exists AND the server still lists an unrevoked
  # colors-proxy token. A Secret whose token was revoked server-side would
  # leave the proxy permanently unable to register while looking fine.
  kubectl -n "$GW" get secret proxy-token >/dev/null 2>&1 \
    && admin token list 2>/dev/null \
       | awk '$2=="colors-proxy" && $NF=="no"' | grep -q .
}
if ! proxy_token_healthy; then
  log "minting the proxy access token"
  for id in $(admin token list 2>/dev/null \
              | awk '$2=="colors-proxy" && $NF=="no" {print $1}'); do
    admin token revoke "$id" >/dev/null 2>&1 || true
  done
  token=$(admin token create --name colors-proxy 2>/dev/null \
          | grep '^Token:' | awk '{print $2}')
  [[ -n $token ]] || { log "FATAL: no proxy token minted"; exit 1; }
  printf '%s' "$token" \
    | kubectl -n "$GW" create secret generic proxy-token --from-file=token=/dev/stdin \
        --dry-run=client -o yaml 2>/dev/null \
    | kubectl apply -f - >/dev/null \
    || { printf '%s' "$token" \
         | kubectl -n "$GW" create secret generic proxy-token --from-file=token=/dev/stdin >/dev/null; }
  unset token
  kubectl -n "$GW" rollout restart deployment/reverse-proxy 2>/dev/null || true
fi

# --- the reverse proxy (applied, not awaited) --------------------------------

traefik_internal=$(kubectl -n "$GW" get svc traefik-internal -o jsonpath='{.spec.clusterIP}')
sed -e "s|__TRAEFIK_INTERNAL_IP__|$traefik_internal|" \
    -e "s|__POD_CIDR__|$POD_CIDR|" "$MAN/proxy.yaml" > "$tmpdir/proxy.yaml"
apply "$tmpdir/proxy.yaml"

# --- the agent image ---------------------------------------------------------
#
# Deterministic context (sorted names, zeroed mtimes) so the context sha is a
# statement about content; the Job is named by that sha, so an unchanged
# context is an already-completed Job. The deploy consumes only the digest
# read back from the registry API — tags are never trusted.

( cd "$DIR/agent-image" && tar --sort=name --mtime=@0 --owner=0 --group=0 -czf "$tmpdir/context.tgz" . )
ctx_sha=$(sha256sum "$tmpdir/context.tgz" | awk '{print $1}')
ctx8=${ctx_sha:0:16}
image_dest="$REGISTRY_HOST/$REGISTRY_NAME/$REGISTRY_REPO:ctx-$ctx8"

manifest_digest() {
  curl -fsS -H "Authorization: Bearer ${COLORS_PAR_DO_TOKEN:?COLORS_PAR_DO_TOKEN is not set}" \
    "https://api.digitalocean.com/v2/registry/$REGISTRY_NAME/repositories/$REGISTRY_REPO/tags?per_page=200" 2>/dev/null \
    | jq -r --arg t "ctx-$ctx8" '.tags[]? | select(.tag==$t) | .manifest_digest // empty' | head -1
}

digest=$(manifest_digest || true)
if [[ -z $digest ]]; then
  log "building the agent image in-cluster (context ctx-$ctx8)"
  # The registry-wide WRITE credential exists in the cluster only for this
  # build: created here, removed by the EXIT trap on every path out of this
  # script, and again explicitly the moment the build completes.
  kubectl -n "$BLD" create secret generic registry-push \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$STATE/push-dockerconfig.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  trap 'kubectl -n "$BLD" delete secret registry-push --ignore-not-found >/dev/null 2>&1 || true; rm -rf "$tmpdir"' EXIT

  sed -e "s|__CONTEXT_SHA__|$ctx_sha|" -e "s|__CONTEXT_SHA8__|$ctx8|" \
      -e "s|__IMAGE_DEST__|$image_dest|" "$MAN/build-job.yaml" > "$tmpdir/build-job.yaml"
  kubectl -n "$BLD" delete job "agent-image-build-$ctx8" --ignore-not-found >/dev/null
  apply "$tmpdir/build-job.yaml"

  log "waiting for the build pod's init container"
  pod=""
  for _ in $(seq 1 60); do
    pod=$(kubectl -n "$BLD" get pod -l "job-name=agent-image-build-$ctx8" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n $pod ]] && state=$(kubectl -n "$BLD" get pod "$pod" \
      -o jsonpath='{.status.initContainerStatuses[0].state.running}' 2>/dev/null || true) || state=""
    [[ -n ${state:-} ]] && break
    sleep 5
  done
  [[ -n ${state:-} ]] || { evidence "build init"; log "FATAL: the build pod's init container never ran"; exit 1; }

  log "streaming the build context"
  kubectl -n "$BLD" exec -i "$pod" -c wait-context -- sh -c 'cat > /workspace/context.tgz' \
    < "$tmpdir/context.tgz"
  kubectl -n "$BLD" exec "$pod" -c wait-context -- touch /workspace/.ready

  log "waiting for kaniko"
  if ! kubectl -n "$BLD" wait --for=condition=complete "job/agent-image-build-$ctx8" --timeout=1800s; then
    log "FATAL: the build failed; last log lines:"
    kubectl -n "$BLD" logs "job/agent-image-build-$ctx8" --tail=50 >&2 || true
    exit 1
  fi
  kubectl -n "$BLD" delete secret registry-push --ignore-not-found >/dev/null 2>&1 || true
  digest=$(manifest_digest)
  [[ -n $digest ]] || { log "FATAL: the pushed image has no readable digest"; exit 1; }
fi
printf '%s' "$digest" > "$STATE/agent-image-digest"
printf '%s' "$ctx_sha" > "$STATE/agent-image-ctx"
log "agent image: $REGISTRY_HOST/$REGISTRY_NAME/$REGISTRY_REPO@$digest"

# --- the load balancer -------------------------------------------------------

log "waiting for the load balancer address"
lb=""
for _ in $(seq 1 120); do
  lb=$(kubectl -n "$GW" get svc traefik \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n $lb ]] && break
  sleep 10
done
[[ -n $lb ]] || { evidence "load balancer"; log "FATAL: the load balancer never received an address"; exit 1; }
printf '%s' "$lb" > "$STATE/lb-ip"
log "load balancer: $lb"
log "converge phase one complete"
