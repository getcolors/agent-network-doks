(ns io.github.getcolors.agent-network-doks.utils
  (:require [clojure.string :as str]))

(def contract 1)

(defn registrable-domain
  "The registrable (zone) domain of a hostname: its last two labels. Good
  enough for the zones this package serves; a public-suffix list would be a
  dependency for a case no deployment has."
  [host]
  (let [labels (str/split (str host) #"\.")]
    (str/join "." (take-last 2 labels))))

(defn registry-name
  "What this deployment names a created container registry. DigitalOcean
  registry names accept lowercase alphanumerics and hyphens, so the
  profile-derived name (Compute Name Standard) is the profile lowercased with
  every other character removed."
  [profile]
  (str/replace (str/lower-case (str profile)) #"[^a-z0-9-]" ""))
