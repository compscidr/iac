## Prerequisites on the terraform deploy machine
AWS and Digital Ocean credentials should be setup via the `development/ops` ansible role in advance.
This will also setup the terraform tool.

## Terraform Commands:

To start:
`terraform init`

To plan:
`terraform plan`

To apply:
`terraform apply`

To show state:
`terraform show terraform.tfstate`

To destroy:
`terraform plan -destroy -out=terraform.tfplan \
      -var "do_token=${DO_PAT}" \
      -var "pvt_key=$HOME/.ssh/id_rsa" \
      -var "pub_key=$HOME/.ssh/id_rsa.pub"`

to make the destroy plan and `terraform apply terraform.tfplan`

Ansible automatically runs as part of the terraform script, but this guide
was used to update the terraform to work together:
https://www.digitalocean.com/community/tutorials/how-to-use-ansible-with-terraform-for-configuration-management
