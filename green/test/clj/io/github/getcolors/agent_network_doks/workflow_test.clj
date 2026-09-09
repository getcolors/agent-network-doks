(ns io.github.getcolors.agent-network-doks.workflow-test
  (:require [io.github.getcolors.agent-network-doks.tools :as tools] [green.workflow :as wf] [clojure.java.io :as io] [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [green.cli :as green-cli]
            [io.github.getcolors.agent-network-doks.workflow :as workflow]))

(defn fixture []
  (green-cli/read-state "test/fixtures/colors.yml" (slurp "test/fixtures/colors.yml")))

(defn chain [event]
  (loop [step :agent-network-doks/start acc []]
    (let [[_ next-step] (workflow/wire-fn step {:green/event event})]
      (if next-step
        (recur next-step (conj acc next-step))
        acc))))

(deftest create-ordering
  (testing "cluster → workloads → dns → certificate → bootstrap → agent → gates"
    (is (= [:agent-network-doks/infrastructure :agent-network-doks/registry :agent-network-doks/deploy
            :agent-network-doks/dns :agent-network-doks/certificate
            :agent-network-doks/bootstrap :agent-network-doks/agent
            :agent-network-doks/acceptance]
           (chain :create)))))

(deftest delete-ordering
  (testing "in-cluster teardown precedes the infrastructure destroy; local
            access material goes last"
    (is (= [:agent-network-doks/load-infrastructure :agent-network-doks/teardown :agent-network-doks/dns :agent-network-doks/registry
            :agent-network-doks/infrastructure :agent-network-doks/cleanup]
           (chain :delete)))))

(deftest every-side-effecting-step-is-dry-runnable
  (let [wired (distinct (concat (chain :create) (chain :delete)))]
    (doseq [step wired]
      (is (some #{step} workflow/side-effecting) (str step)))))

(deftest start-validates
  (testing "a valid fixture passes"
    (let [out (workflow/start-step (assoc (fixture) :green/event :build) {})]
      (is (zero? (:green/exit out)))))
  (testing "missing desired state aggregates every error at exit 2"
    (let [out (workflow/start-step (-> (fixture)
                                       (dissoc :agent-network-host :doks-version)
                                       (assoc :green/event :build))
                                   {})]
      (is (= 2 (:green/exit out)))
      (is (str/includes? (str (:green/err out)) ":agent-network-host"))
      (is (str/includes? (str (:green/err out)) "missing managed Kubernetes settings"))))
  (testing "the profile guard refuses the overlay"
    (let [out (workflow/start-step (assoc (fixture) :green/event :build)
                                   {"COLORS_PAR_PROFILE" "other"})]
      (is (= 2 (:green/exit out)))))
  (testing "a real delete is refused while the guard stands"
    (let [out (workflow/start-step (assoc (fixture)
                                          :green/event :delete
                                          :do-token "x"
                                          :cloudflare-api-token "x")
                                   {})]
      (is (= 2 (:green/exit out)))
      (is (str/includes? (str (:green/err out)) "COLORS_PAR_COMPUTE_PREVENT_DESTROY")))))

(deftest retired-resumes-only-idempotent-local-cleanup
  (let [dir (.toFile (java.nio.file.Files/createTempDirectory "agent-network-doks-retired-" (make-array java.nio.file.attribute.FileAttribute 0)))
        opts {:profile "retired" :workdir (str dir) :green/event :delete}
        paths [(io/file (tools/kubeconfig-path opts)) (io/file (tools/state-dir opts) "leftover") (io/file (tools/profile-dir opts) "proofs/leftover") (io/file (tools/lego-dir opts) "accounts/private-key")]
        keep (io/file dir "keep") seen (atom []) inspection-exit (atom 0)
        native (wf/workflow {:start :agent-network-doks/start :next-fn workflow/next-steps
          :wire-fn (fn [step current]
            (case step
              :agent-network-doks/start [(fn [o] (swap! seen conj step) (assoc o :green/exit 0)) :agent-network-doks/load-managed]
              :agent-network-doks/load-managed [(fn [o] (swap! seen conj step) (assoc o :green/exit @inspection-exit :agent-network-doks/already-destroyed true)) :forbidden/remote]
              :agent-network-doks/cleanup [(fn [o] (swap! seen conj step) ((first (workflow/wire-fn step o)) o))]
              [(fn [_] (throw (ex-info "unexpected remote stage" {:step step})))]))})]
    (try
      (doseq [path paths] (io/make-parents path) (spit path "synthetic leftover"))
      (spit keep "unrelated")
      (dotimes [_ 2]
        (reset! seen [])
        (is (zero? (:green/exit (wf/run native opts))))
        (is (= [:agent-network-doks/start :agent-network-doks/load-managed :agent-network-doks/cleanup] @seen))
        (is (every? #(not (.exists %)) paths))
        (is (= "unrelated" (slurp keep))))
      (reset! inspection-exit 1) (reset! seen [])
      (is (= 1 (:green/exit (wf/run native opts))))
      (is (= [:agent-network-doks/start :agent-network-doks/load-managed] @seen))
      (is (= [] (workflow/next-steps :agent-network-doks/load-managed [:forbidden/remote] (assoc opts :green/exit 1 :agent-network-doks/already-destroyed true))))
      (is (not (.exists (io/file dir ".ssh"))))
      (finally (doseq [f (reverse (file-seq dir))] (io/delete-file f true))))))
