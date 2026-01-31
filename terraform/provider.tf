terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.75.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 2.0"
    }
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