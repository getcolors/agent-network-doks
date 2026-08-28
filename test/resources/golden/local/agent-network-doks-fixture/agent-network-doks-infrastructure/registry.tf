# Registry create mode: no digitalocean-registry-name was supplied, so this
# deployment owns a profile-named registry. The launcher's tier-aware
# capacity preflight ran before this file was applied — DOCR registries are
# account-scoped and tier-limited, and the subscription is account-global,
# so this resource exists only where that preflight said it can.
resource "digitalocean_container_registry" "agent_network_doks" {
  name                   = "agent-network-doks-fixture"
  subscription_tier_slug = "basic"
  region                 = "ams3"

  lifecycle { prevent_destroy = true }
}

locals {
  registry_name = digitalocean_container_registry.agent_network_doks.name
}

# Asymmetric credential lifetimes, both rotated deterministically:
#
#  - the WRITE credential exists for kaniko's push alone. It is short-lived
#    (26h expiry, rotated every 24h) — a daily converge always has a valid
#    one, and a leaked copy dies within a day. The converge script deletes
#    its cluster Secret the moment the build completes, success or failure.
#  - the READ-ONLY pull credential backs the kubelet's imagePullSecrets and
#    must survive between converges: a node replacement or eviction weeks
#    later still has to pull. 90-day expiry, rotated every 30 days, and the
#    Secret is re-applied on every converge.
#
# Both are REGISTRY-wide (DOCR offers no repository-scoped tokens) — an
# honest limit, documented rather than pretended away. registry_name is the
# resource reference, never the raw profile string, so the credentials can
# never race registry creation.
resource "time_rotating" "registry_write" {
  rotation_hours = 24
}

resource "time_rotating" "registry_read" {
  rotation_days = 30
}

resource "digitalocean_container_registry_docker_credentials" "write" {
  registry_name  = local.registry_name
  write          = true
  expiry_seconds = 93600

  lifecycle { replace_triggered_by = [time_rotating.registry_write] }
}

resource "digitalocean_container_registry_docker_credentials" "read" {
  registry_name  = local.registry_name
  write          = false
  expiry_seconds = 7776000

  lifecycle { replace_triggered_by = [time_rotating.registry_read] }
}

output "registry-host" {
  value = "registry.digitalocean.com"
}

output "registry-name" {
  value = local.registry_name
}

output "push-dockerconfig" {
  value     = digitalocean_container_registry_docker_credentials.write.docker_credentials
  sensitive = true
}

output "pull-dockerconfig" {
  value     = digitalocean_container_registry_docker_credentials.read.docker_credentials
  sensitive = true
}
