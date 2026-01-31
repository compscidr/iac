terraform {
  required_version = ">= 1.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.75.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "2.1.2"
    }
  }

  # Remote state in DigitalOcean Spaces (S3-compatible)
  # Create bucket first: doctl spaces create terraform-state --region sfo3
  backend "s3" {
    endpoints = {
      s3 = "https://sfo3.digitaloceanspaces.com"
    }
    bucket                      = "terraform-state-jasonernst"
    key                         = "iac/terraform.tfstate"
    region                      = "us-east-1" # Required but ignored by DO
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

# 1Password provider
# - CI: uses OP_SERVICE_ACCOUNT_TOKEN env var
# - Local: uses CLI/desktop app integration (default signed-in account)
provider "onepassword" {}

# Get SSH key from 1Password
data "onepassword_item" "github_ssh" {
  vault = "Infrastructure"
  title = "Github SSH"
}

# Get Tailscale authkey from 1Password
data "onepassword_item" "tailscale" {
  vault = "Infrastructure"
  title = "Tailscale"
}

# Upload the public key to DigitalOcean
resource "digitalocean_ssh_key" "github" {
  name       = "github-ssh"
  public_key = data.onepassword_item.github_ssh.public_key
}