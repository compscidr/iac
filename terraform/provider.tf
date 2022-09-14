terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
      version = "2.22.3"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

resource "aws_key_pair" "aws_devops" {
  key_name   = "aws_devops"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC64NthfwLdmZW8H3hMCfR3gGbZhZvlSKrYiPNHVq5DwWmxZj0jmmvWKuKwCgwps9DDm01wS2++20Ow6btcXzIGqlK5zXrw2QzlLjf7LMh5bb1VQbGeX1jbiekY8ow5GF8zl3x/twlaiUPQJx2ZM3aQsqsboDbjon+ayyufyy+D90sRuOZUbS9KDxebLH4f34Rhp4XmG54QlvNH8duf0fazDpBrpzZX+vl/4v1xKU+6nTpyHNaWhciF02mOnE4aP+Ww3zn9NM1wJAMyZaYRLtUL0gjYt1OC+vQbrA/nddAdTDoDXQuV1AnKf2R4jIN/Gff4WMRe5/mPAfuo7/9YCCk/ ernstjason1@gmail.com"
}

# Configure the AWS Provider
provider "aws" {
  region = "us-west-1" # n. california
}