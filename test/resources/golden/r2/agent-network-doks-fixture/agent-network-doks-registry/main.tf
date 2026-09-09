terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" }
    time         = { source = "hashicorp/time", version = "~> 0.12" }
  }
}

provider "digitalocean" {
  # token comes from DIGITALOCEAN_TOKEN in the environment
}

