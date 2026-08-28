(ns io.github.getcolors.agent-network-doks.workflow
  (:require [green.cli :as green-cli]
            [green.dry-run :as dry-run]
            [green.lifecycle :as lifecycle]
            [green.progress :as progress]
            [green.tofu :as tofu]
            [green.workflow :as wf]
            [io.github.getcolors.agent-network-doks.tools :as tools]
            [io.github.getcolors.agent-network-doks.validate :as validate]))

(def defaults {:provider-compute "digitalocean" :provider-dns "cloudflare"
               :provider-backend "local" :compute-prevent-destroy true
               :workdir ".colors"})

(defn start-step
  ([opts] (start-step opts (System/getenv)))
  ([opts env]
   (lifecycle/preflight
    opts {:defaults defaults :overlay green-cli/read-pars
          :validators
          [(fn [_ env _] (validate/env-errors env))
           (fn [opts _ _] (validate/state-errors opts))
           (fn [opts _ {:keys [event real?]}]
             (when (and real? (contains? #{:create :delete} event))
               (validate/secret-errors opts event)))
           (fn [opts _ {:keys [event real?]}]
             (when (and real? (= :delete event) (:compute-prevent-destroy opts))
               [(str "compute destruction is protected; set "
                     (green-cli/par-name :compute-prevent-destroy) "=false to delete")]))]}
    env)))

(defn wire-fn [step run-opts]
  (if (= :delete (:green/event run-opts))
    ;; In-cluster teardown first: the CSI volumes and the CCM-created load
    ;; balancer are Kubernetes-managed and invisible to the infrastructure
    ;; state, so destroying the cluster before removing them would orphan
    ;; them in the account. Local access material goes last — the kubeconfig
    ;; is needed by the teardown and dead only after the destroy.
    (case step
      :agent-network-doks/start [start-step :agent-network-doks/teardown]
      :agent-network-doks/teardown [tools/teardown-step :agent-network-doks/dns]
      :agent-network-doks/dns [tools/dns-step :agent-network-doks/infrastructure]
      :agent-network-doks/infrastructure [tools/infrastructure-step :agent-network-doks/cleanup]
      :agent-network-doks/cleanup [tools/cleanup-step])
    ;; Create: the cluster first; then the workloads (the edge and the proxy
    ;; are applied but deliberately not awaited — they mount a TLS Secret
    ;; that does not exist yet); DNS once the load balancer has an address;
    ;; the certificate once DNS can answer DNS-01; then the control plane,
    ;; the two-pod application, and the gates.
    (case step
      :agent-network-doks/start [start-step :agent-network-doks/infrastructure]
      :agent-network-doks/infrastructure [tools/infrastructure-step :agent-network-doks/deploy]
      :agent-network-doks/deploy [tools/deploy-step :agent-network-doks/dns]
      :agent-network-doks/dns [tools/dns-step :agent-network-doks/certificate]
      :agent-network-doks/certificate [tools/certificate-step :agent-network-doks/bootstrap]
      :agent-network-doks/bootstrap [tools/bootstrap-step :agent-network-doks/agent]
      :agent-network-doks/agent [tools/agent-step :agent-network-doks/acceptance]
      :agent-network-doks/acceptance [tools/acceptance-step])))

(defn backend-advice [tool]
  (tofu/conventional-backend-advice
   {:dir-fn #(tools/tool-dir % tool)
    :key-fn #(str (:profile %) "/" tool ".tfstate")}))

(def side-effecting
  [:agent-network-doks/infrastructure :agent-network-doks/deploy
   :agent-network-doks/dns :agent-network-doks/certificate
   :agent-network-doks/bootstrap :agent-network-doks/agent
   :agent-network-doks/acceptance :agent-network-doks/teardown
   :agent-network-doks/cleanup])

(def workflow
  (-> (wf/workflow {:start :agent-network-doks/start :wire-fn wire-fn})
      (wf/advice-add :agent-network-doks/infrastructure :before ::backend
                     (backend-advice tools/infrastructure-tool))
      (wf/advice-add :agent-network-doks/dns :before ::backend (backend-advice tools/dns-tool))
      progress/advise
      (dry-run/advise side-effecting)))
