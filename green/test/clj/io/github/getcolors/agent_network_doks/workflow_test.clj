(ns io.github.getcolors.agent-network-doks.workflow-test
  (:require [clojure.string :as str]
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
    (is (= [:agent-network-doks/infrastructure :agent-network-doks/deploy
            :agent-network-doks/dns :agent-network-doks/certificate
            :agent-network-doks/bootstrap :agent-network-doks/agent
            :agent-network-doks/acceptance]
           (chain :create)))))

(deftest delete-ordering
  (testing "in-cluster teardown precedes the infrastructure destroy; local
            access material goes last"
    (is (= [:agent-network-doks/teardown :agent-network-doks/dns
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
      (is (str/includes? (str (:green/err out)) ":doks-version"))))
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
