# Registry adopt mode: digitalocean-registry-name names an existing,
# account-owned registry. It is a data source — never created, never
# destroyed by this deployment — and only the profile-named repository
# inside it is deployment-owned (teardown deletes exactly that repository
# through the API). The launcher's adopt-mode preflight verified existence
# and capacity, reuse-first, before this file was applied.
data "digitalocean_container_registry" "agent_network_doks" {
  name = "<{ registry-name }>"
}

locals {
  registry_name = data.digitalocean_container_registry.agent_network_doks.name
}

# Same asymmetric, deterministically rotated credential pair as create mode;
# see registry-create.tf for the rationale. DOCR credentials are
# REGISTRY-wide even in adopt mode — an adopted registry shared with other
# consumers extends that trust to this deployment, which is the documented
# cost of adopting.
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
