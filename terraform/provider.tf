terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
      version = "2.16.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

module "ssh-key" {
  source          = "clouddrove/ssh-key/digitalocean"
  version         = "0.15.0"
  key_path        = "~/.ssh/id_rsa.pub"
  key_name        = "devops"
  enable_ssh_key  = true
}

# Configure the AWS Provider
provider "aws" {
  region = "us-west-1" # n. california
}