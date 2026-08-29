(ns pin (:require [clojure.java.shell :as sh] [clojure.string :as str]))
;; One SHA, three payloads. Every payload is born unpinned — no invented SHAs —
;; and `bb pin` stamps or re-stamps it after a clean, pushed HEAD. Each site
;; recognises exactly two forms, its unpinned birth shape and its pinned shape,
;; and the run fails loudly when a payload matches neither.
;;
;; The launchers pin only agent-network-doks. `green` comes transitively from
;; green/deps.edn, and the red and blue SDK pins ride inside each payload
;; beside the package pin, so this task rewrites one site per colour.
(defn git [& args] (let [{:keys [exit out]} (apply sh/sh "git" args)] (when (zero? exit) (str/trim out))))

(defn stamp-green [s sha]
  (when (re-find #"\(def \^:private agent-network-doks-sha (?:nil|\"[0-9a-f]{40}\")\)" s)
    (str/replace-first s #"\(def \^:private agent-network-doks-sha (?:nil|\"[0-9a-f]{40}\")\)"
                       (str "(def ^:private agent-network-doks-sha \"" sha "\")"))))

(defn stamp-red [s sha]
  (let [pinned (str "\"package-agent-network-doks-red\": \"github:getcolors/agent-network-doks#" sha "\",")]
    (cond (str/includes? s "\"package-agent-network-doks-red\": null,")
          (str/replace-first s "\"package-agent-network-doks-red\": null," pinned)
          (re-find #"\"package-agent-network-doks-red\": \"github:getcolors/agent-network-doks#[0-9a-f]{40}\"," s)
          (str/replace-first s #"\"package-agent-network-doks-red\": \"github:getcolors/agent-network-doks#[0-9a-f]{40}\"," pinned))))

(def blue-unpinned-meta "# dependencies = []\n# ///")
(defn blue-pinned-meta [sha]
  (str "# dependencies = [\"package-agent-network-doks-blue\", \"blue\"]\n"
       "#\n"
       "# [tool.uv.sources]\n"
       "# package-agent-network-doks-blue = { git = \"https://github.com/getcolors/agent-network-doks.git\", rev = \"" sha "\", subdirectory = \"blue\" }\n"
       "# blue = { git = \"https://github.com/getcolors/blue.git\", rev = \"290f313ead5ca162875c33a049c880da017eae09\" }\n"
       "# ///"))
(defn stamp-blue [s sha]
  ;; First stamp is structural: the metadata block gains its git sources and the
  ;; UNPINNED paragraph collapses to a pinned-state note. Re-pinning is a SHA swap.
  (cond (str/includes? s blue-unpinned-meta)
        (-> s
            (str/replace-first blue-unpinned-meta (blue-pinned-meta sha))
            (str/replace-first #"(?s)# UNPINNED:.*?AGENT_NETWORK_DOKS_LIB_ROOT=/path/to/agent-network-doks\n"
                               "# Stamped by `bb pin`. AGENT_NETWORK_DOKS_LIB_ROOT=/path/to/agent-network-doks\n# still overrides the pin with a working tree.\n"))
        (re-find #"agent-network-doks\.git\", rev = \"[0-9a-f]{40}\"" s)
        (str/replace-first s #"agent-network-doks\.git\", rev = \"[0-9a-f]{40}\""
                           (str "agent-network-doks.git\", rev = \"" sha "\""))))

(def sites
  [{:path "../skills/package-agent-network-doks-green/green" :stamp stamp-green}
   {:path "../skills/package-agent-network-doks-red/red" :stamp stamp-red}
   {:path "../skills/package-agent-network-doks-blue/blue" :stamp stamp-blue}])

(let [dirty (git "status" "--porcelain") sha (git "rev-parse" "HEAD") remotes (git "branch" "-r" "--contains" sha)]
  (cond (seq dirty) (do (binding [*out* *err*] (println "agent-network-doks working tree is dirty; commit before pinning")) (System/exit 2))
        (not (str/includes? (str remotes) "origin/")) (do (binding [*out* *err*] (println "agent-network-doks HEAD is not pushed")) (System/exit 2))
        :else (let [errors (atom [])]
                (doseq [{:keys [path stamp]} sites]
                  (let [s (slurp path) n (stamp s sha)]
                    (if n (spit path n) (swap! errors conj (str "could not locate a pin form in " path)))))
                (if (seq @errors)
                  (do (binding [*out* *err*] (println (str/join "\n" @errors))) (System/exit 2))
                  (println "pinned 3 launchers to" (subs sha 0 7))))))
