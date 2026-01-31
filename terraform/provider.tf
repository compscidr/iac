terraform {
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
    endpoint                    = "sfo3.digitaloceanspaces.com"
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

# 1Password provider - uses CLI/desktop app integration
provider "onepassword" {
  account = "CZG3A4373RA2FC5W5JKFUMYILI"
}

# Get SSH key from 1Password
data "onepassword_item" "github_ssh" {
  vault = "Infrastructure"
  title = "Github SSH"
}

# Upload the public key to DigitalOcean
resource "digitalocean_ssh_key" "github" {
  name       = "github-ssh"
  public_key = data.onepassword_item.github_ssh.public_key
}