(ns io.github.getcolors.agent-network-doks.validate
  "Credential-free desired-state validation for the DOKS Agent Network demo.
  Depends only on the SDK: like `k8s`, this package carries its own provider
  registry rather than pinning ONCE for one lookup table."
  (:require [clojure.string :as str]
            [io.github.getcolors.compute :as compute]
            [io.github.getcolors.compute-managed :as managed]
            [clojure.walk :as walk]
            [green.cli :as green-cli]
            [io.github.getcolors.agent-network-doks.utils :as utils]))

(def profile-par (green-cli/par-name :profile))

(def providers
  {:provider-registry {"digitalocean" {:secrets [:do-token] :tofu-env {:do-token "DIGITALOCEAN_TOKEN"}}}
   :provider-dns {"cloudflare" {:secrets [:cloudflare-api-token] :tofu-env {:cloudflare-api-token "CLOUDFLARE_API_TOKEN"}}}
   :provider-backend (into {} (for [[key descriptor] (:backend compute/registry)]
     [(name key) (assoc descriptor :secrets (mapv keyword (:secrets descriptor)))]))})

(def required
  "Every key desired state must carry unconditionally. There is no
  `digitalocean-name`: the Compute Name Standard's optional override applies,
  and a colors.yml that omits it is complete and names the cluster, node
  pool, load balancer and a created registry after the profile. There is no
  pod- or service-CIDR key: DOKS subnets are outputs read back from the
  cluster, never inputs. `digitalocean-registry-tier` is conditionally
  required — create mode only — and validated separately."
  [:digitalocean-region :profile :workdir :provider-compute :provider-dns :provider-backend
   :compute-prevent-destroy
   :agent-network-host :agent-network-letsencrypt-email
   :agent-network-admin-email :agent-network-admin-name
   :agent-network-provider-models :agent-network-allowed-models
   :agent-network-policy-budget-usd-per-day :agent-network-policy-tokens-per-day
   :agent-network-global-budget-usd-per-day :agent-network-global-tokens-per-day
   :agent-network-log-retention-days :agent-network-log-level
   :agent-network-server-image :agent-network-dashboard-image
   :agent-network-proxy-image :agent-network-traefik-image
   :agent-network-client-image :agent-network-kaniko-image
   :agent-network-agent-base-image
   :agent-network-claude-code-version :agent-network-privoxy-version
   :agent-network-gost-version :agent-network-gost-sha256
   :agent-network-lego-version
   ])

(def image-keys
  [:agent-network-server-image :agent-network-dashboard-image
   :agent-network-proxy-image :agent-network-traefik-image
   :agent-network-client-image :agent-network-kaniko-image
   :agent-network-agent-base-image])

(def host-re #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")
(def email-re #"^[^@\s]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")
;; `tag@sha256:...` — the shape every image key here actually carries — pins
;; both the human-readable version and the exact bytes.
(def image-pinned-re #"^[^\s@]+(?::[^\s:@]+@sha256:[0-9a-f]{64}|:[^\s:@]+|@sha256:[0-9a-f]{64})$")
(def cidr-re #"^(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}$")

(defn ipv4-cidr?
  "A real IPv4 CIDR: shape, octets 0-255, prefix 0-32. The shape regex alone
  admits 999.999.999.999/99, which would fail late — after infrastructure
  exists — instead of at validation."
  [s]
  (boolean
   (when (re-matches cidr-re (str s))
     (let [[addr prefix] (clojure.string/split (str s) #"/")
           octets (map #(Long/parseLong %) (clojure.string/split addr #"\."))]
       (and (every? #(<= 0 % 255) octets)
            (<= 0 (Long/parseLong prefix) 32))))))
(def version-re #"^[0-9]+\.[0-9]+\.[0-9]+$")
;; A Debian package version: upstream plus revision, e.g. 3.0.34-1.
(def deb-version-re #"^[0-9][0-9A-Za-z.+~:-]*$")
(def sha256-re #"^[0-9a-f]{64}$")
;; DOKS version slugs are Kubernetes semver plus DO's build suffix:
;; 1.36.3-do.2. The changelog sometimes prints x.y.z.do-v; the slug — the
;; only form the API accepts — is always x.y.z-do.v.
(def doks-version-re #"^[0-9]+\.[0-9]+\.[0-9]+-do\.[0-9]+$")
(def model-id-re #"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
;; DigitalOcean resource names accept letters, digits, dashes and periods.
(def do-name-re #"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$")
;; DOCR registry names: lowercase alphanumerics and hyphens.
(def do-registry-re #"^[a-z0-9][a-z0-9-]{1,62}$")
(def registry-tiers #{"starter" "basic" "professional"})

(defn missing? [x] (or (nil? x) (and (string? x) (str/blank? x))))

(defn placeholder?
  "Absent, blank or REPLACE_ME all mean 'use the profile' (Compute Name
  Standard §2: presence is the only switch)."
  [v]
  (or (missing? v) (= "REPLACE_ME" (str/trim (str v)))))

(defn compute-name [opts]
  (try (get-in (managed/plan-managed-kubernetes opts) [:params :name])
       (catch Exception _ (str (:profile opts)))))

(defn adopt-registry? [opts]
  (not (placeholder? (:digitalocean-registry-name opts))))

(defn registry-name
  "The registry this deployment pushes to and pulls from: the adopted name,
  or the compute name reduced to what DOCR accepts."
  [opts]
  (if (adopt-registry? opts)
    (str/trim (str (:digitalocean-registry-name opts)))
    (utils/registry-name (compute-name opts))))

(defn registry-repository
  "The one repository this deployment owns inside whichever registry was
  adopted or created — always the profile, so teardown can delete exactly it."
  [opts]
  (str (:profile opts)))

(defn zone
  "The Cloudflare zone the host and its wildcard belong to."
  [opts]
  (utils/registrable-domain (:agent-network-host opts)))

(defn provider-models
  "The models the Anthropic provider claims, keywordized however YAML handed
  them over."
  [opts]
  (mapv walk/keywordize-keys (:agent-network-provider-models opts)))

(defn allowed-models [opts]
  (mapv str (:agent-network-allowed-models opts)))

(defn allowed-model
  "The model every Claude Code knob is pinned to."
  [opts]
  (first (allowed-models opts)))

(defn denied-claimed-model
  "A model the provider claims but the guardrail does not allow — the
  guardrail-denial probe's negative case. Its existence is validated, so
  acceptance can rely on it."
  [opts]
  (let [allowed (set (allowed-models opts))]
    (some #(when-not (contains? allowed (str (:id %))) (str (:id %)))
          (provider-models opts))))

(defn pos-num? [x] (and (number? x) (pos? x)))

(defn model-errors [opts]
  (let [models (provider-models opts)
        allowed (allowed-models opts)
        claimed (set (map #(str (:id %)) models))]
    (concat
     (when-not (and (sequential? (:agent-network-provider-models opts)) (seq models))
       [":agent-network-provider-models must be a non-empty list"])
     (for [m models
           :when (or (missing? (:id m)) (not (re-matches model-id-re (str (:id m)))))]
       ":agent-network-provider-models entries must carry a model id")
     (for [m models
           :let [in (:input-per-1k m) out (:output-per-1k m)]
           :when (not (and (pos-num? in) (pos-num? out)))]
       (str "model " (:id m) " must carry positive input-per-1k and output-per-1k prices"))
     (when-not (and (sequential? (:agent-network-allowed-models opts)) (seq allowed))
       [":agent-network-allowed-models must be a non-empty list"])
     (for [m allowed :when (not (contains? claimed m))]
       (str ":agent-network-allowed-models entry " m " is not claimed by the provider"))
     ;; The demo's guardrail-denial probe needs a model that routing accepts
     ;; and the allowlist rejects. Without one, gate 3b has no negative case
     ;; and the guardrail is configured but never demonstrated.
     (when (and (seq models) (seq allowed)
                (every? #(contains? (set allowed) (str (:id %))) models))
       [":agent-network-provider-models must claim at least one model outside :agent-network-allowed-models"]))))

(defn registry-errors
  "The adopt-or-create contract. Create mode (no registry name) requires the
  tier; adopt mode rejects it — the subscription tier is account-global and
  an adopted registry's tier is not this deployment's to declare."
  [opts]
  (if (adopt-registry? opts)
    (concat
     (when-not (re-matches do-registry-re (str/trim (str (:digitalocean-registry-name opts))))
       [":digitalocean-registry-name must be lowercase alphanumerics and hyphens"])
     (when-not (missing? (:digitalocean-registry-tier opts))
       [":digitalocean-registry-tier is create-mode-only; remove it when adopting a registry via :digitalocean-registry-name"]))
    (concat
     (when (missing? (:digitalocean-registry-tier opts))
       [":digitalocean-registry-tier is required when no :digitalocean-registry-name adopts an existing registry"])
     (when (and (not (missing? (:digitalocean-registry-tier opts)))
                (not (contains? registry-tiers (str (:digitalocean-registry-tier opts)))))
       [":digitalocean-registry-tier must be starter, basic, or professional"])
     (when-not (re-matches do-registry-re (registry-name opts))
       [(str "the profile-derived registry name " (registry-name opts) " is not a valid DOCR name")]))))

(defn env-errors [env]
  (when (not-empty (str (get env profile-par)))
    [(str profile-par " is set; profile must come from colors.yml only")]))

(defn- entry [opts slot] (get-in providers [slot (get opts slot)]))

(defn managed-application-errors [opts]
  (when-not (seq (managed/managed-errors opts))
    (try
      (let [settings (managed/managed-application-settings opts)]
        (if-not (:pod_cidr settings) [":compute-pod-cidr is required"]
          (do (managed/managed-application-artifacts opts ["managed-cleanup.sh" "managed-ingress.sh"]) [])))
      (catch Exception error [(ex-message error)]))))

(defn state-errors [opts]
  (vec
   (concat
    (for [k required :when (missing? (get opts k))] (str k " is required"))
    (managed/managed-errors opts)
    (managed-application-errors opts)
    (when-not (= "cloudflare" (:provider-dns opts))
      [":provider-dns must be cloudflare"])

    (when-not (boolean? (:compute-prevent-destroy opts))
      [":compute-prevent-destroy must be true or false"])
    (when (and (not (missing? (:agent-network-host opts)))
               (not (re-matches host-re (str (:agent-network-host opts)))))
      [":agent-network-host must be a fully qualified hostname"])
    (for [k [:agent-network-letsencrypt-email :agent-network-admin-email]
          :let [v (get opts k)]
          :when (and (not (missing? v)) (not (re-matches email-re (str v))))]
      (str k " must be an email address"))
    (for [k image-keys
          :let [v (get opts k)]
          :when (and (not (missing? v)) (not (re-matches image-pinned-re (str v))))]
      (str k " must carry an explicit image tag or digest"))
    ;; This package owns its manifests rather than following the upstream
    ;; installer, so nothing tells it when a floating tag moved underneath it.
    (for [k image-keys
          :let [v (str (get opts k))]
          :when (or (str/ends-with? v ":latest") (str/ends-with? v ":main")
                    (str/includes? v ":latest@") (str/includes? v ":main@"))]
      (str k " must not track a floating tag; pin the version"))
    (for [k [:agent-network-claude-code-version :agent-network-lego-version]
          :let [v (get opts k)]
          :when (and (not (missing? v)) (not (re-matches version-re (str v))))]
      (str k " must be an exact x.y.z version"))
    (when-not (or (missing? (:agent-network-privoxy-version opts))
                  (re-matches deb-version-re (str (:agent-network-privoxy-version opts))))
      [":agent-network-privoxy-version must be an exact Debian package version"])
    (when-not (or (missing? (:agent-network-gost-version opts))
                  (re-matches version-re (str (:agent-network-gost-version opts))))
      [":agent-network-gost-version must be an exact x.y.z version"])
    (when-not (or (missing? (:agent-network-gost-sha256 opts))
                  (re-matches sha256-re (str (:agent-network-gost-sha256 opts))))
      [":agent-network-gost-sha256 must be the 64-hex sha256 of the release tarball"])
    (when-not (or (missing? (:agent-network-log-level opts))
                  (contains? #{"error" "warn" "info" "debug"}
                             (str (:agent-network-log-level opts))))
      [":agent-network-log-level must be error, warn, info, or debug"])
    ;; 7-90 mirrors the dashboard's own retention range; usage metering is
    ;; unconditional and unaffected.
    (when-not (or (missing? (:agent-network-log-retention-days opts))
                  (and (integer? (:agent-network-log-retention-days opts))
                       (<= 7 (:agent-network-log-retention-days opts) 90)))
      [":agent-network-log-retention-days must be an integer between 7 and 90"])
    (for [k [:agent-network-policy-budget-usd-per-day
             :agent-network-policy-tokens-per-day
             :agent-network-global-budget-usd-per-day
             :agent-network-global-tokens-per-day]
          :let [v (get opts k)]
          :when (and (not (missing? v)) (not (pos-num? v)))]
      (str k " must be a positive number"))
    ;; The global rule is the backstop: a policy cap above it would never bind
    ;; and the desired state would be lying about which limit is the ceiling.
    (when (and (pos-num? (:agent-network-policy-budget-usd-per-day opts))
               (pos-num? (:agent-network-global-budget-usd-per-day opts))
               (> (:agent-network-policy-budget-usd-per-day opts)
                  (:agent-network-global-budget-usd-per-day opts)))
      [":agent-network-policy-budget-usd-per-day must not exceed the global budget"])
    (when (and (pos-num? (:agent-network-policy-tokens-per-day opts))
               (pos-num? (:agent-network-global-tokens-per-day opts))
               (> (:agent-network-policy-tokens-per-day opts)
                  (:agent-network-global-tokens-per-day opts)))
      [":agent-network-policy-tokens-per-day must not exceed the global token cap"])
    (when (seq (remove missing? [(:agent-network-provider-models opts)
                                 (:agent-network-allowed-models opts)]))
      (model-errors opts))
    (registry-errors opts)
    ;; The override is validated against the provider's rules rather than
    ;; passed through unread (Compute Name Standard §2).
)))

(defn backend-secrets [opts]
  (:secrets (entry opts :provider-backend)))

(def provider-secrets
  "What talking to the providers needs, on any real event."
  [:do-token :cloudflare-api-token])

(def application-secrets
  "What converging the cluster needs, and therefore only a create.

  One entry, deliberately. Everything else this deployment holds is generated
  in-cluster and supplied by nobody: the relay auth secret, the datastore
  encryption key, the session cookie key, the proxy access token, the local
  admin password, the durable automation token, and the agent's one-off setup
  key. The Anthropic key is the exception because it authenticates against an
  account this cluster does not own; it is handed to NetBird's encrypted store
  at converge time and the agent pod never sees it."
  [:anthropic-api-key])

(defn secret-errors
  "Credentials a real event needs. A delete tears down infrastructure with the
  provider credentials alone: this deployment is disposable by design, holds
  nothing worth a final archive, and demanding the Anthropic key to destroy a
  cluster would just be a lock on the exit."
  [opts event]
  (let [keys (concat provider-secrets
                     (case event
                       :create application-secrets
                       [])
                     (backend-secrets opts))]
    (for [k (distinct keys) :when (missing? (get opts k))]
      (str "required credential is not set: " (green-cli/par-name k)))))

(defn tofu-env [opts slot]
  (case slot
    :provider-registry {:do-token "DIGITALOCEAN_TOKEN"}
    :provider-dns {:cloudflare-api-token "CLOUDFLARE_API_TOKEN"}
    :provider-backend (if (= "r2" (:provider-backend opts)) {:r2-access-key-id "AWS_ACCESS_KEY_ID" :r2-secret-access-key "AWS_SECRET_ACCESS_KEY"} {})
    {}))
