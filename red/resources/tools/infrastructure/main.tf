terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" }
    time         = { source = "hashicorp/time", version = "~> 0.12" }
  }
}

provider "digitalocean" {
  # token comes from DIGITALOCEAN_TOKEN in the environment
}

# Every label derives from one resolved name (Compute Name Standard §3), which
# defaults to the profile. Templates never branch on whether an override was
# supplied — that decision was made once, in Clojure. There is no firewall
# resource and no SSH key: the nodes are DOKS-managed, every operation goes
# through the kubeconfig, and the only public surface is the load balancer
# the cloud controller creates from the Traefik Service.
#
# Networking is the deliberately-accepted legacy (non-VPC-native) mode:
# neither cluster_subnet nor service_subnet is supplied, and both are READ
# BACK as outputs — everything CIDR-derived downstream renders from the
# read-back values, never from desired-state input.
resource "digitalocean_kubernetes_cluster" "agent_network_doks" {
  name    = "<{ compute-name }>"
  region  = "<{ digitalocean-region }>"
  version = "<{ doks-version }>"

  # Explicit, never the provider default: the paid HA control plane is out
  # of scope for this disposable demo.
  ha = false

  node_pool {
    name       = "<{ compute-name }>"
    size       = "<{ digitalocean-node-size }>"
    node_count = <{ digitalocean-node-count }>
  }

  lifecycle { prevent_destroy = <{ compute-prevent-destroy }> }
}

output "params" {
  value = {
    name       = "<{ compute-name }>"
    cluster-id = digitalocean_kubernetes_cluster.agent_network_doks.id
    endpoint   = digitalocean_kubernetes_cluster.agent_network_doks.endpoint
  }
}

# The DO provider exposes structured kube_config entries, not Vultr's base64
# string; base64encode(raw_config) keeps the consumer's decode contract in
# one place and the tests assert it.
output "kubeconfig-b64" {
  value     = base64encode(digitalocean_kubernetes_cluster.agent_network_doks.kube_config[0].raw_config)
  sensitive = true
}

output "cluster-subnet" {
  value = digitalocean_kubernetes_cluster.agent_network_doks.cluster_subnet
}

output "service-subnet" {
  value = digitalocean_kubernetes_cluster.agent_network_doks.service_subnet
}
