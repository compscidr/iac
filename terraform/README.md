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
`terraform plan -destroy -out=terraform.tfplan`

to make the destroy plan and `terraform apply terraform.tfplan`

Ansible automatically runs as part of the terraform script, but this guide
was used to update the terraform to work together:
https://www.digitalocean.com/community/tutorials/how-to-use-ansible-with-terraform-for-configuration-management

## Prep for ansible
For DigitalOcean, you'll want to do an `ssh root@www.jasonernst.com` and for aws, `ssh ubuntu@lp.jasonernst.com`.
You'll likely have to clear out any old ssh keys before using ansible.

Then for ansible:
`ansible-playbook playbook.yml -i inventory.yml -u root --limit www.jasonernst.com --tags user`
and
`ansible-playbook playbook.yml -i inventory.yml -u ubuntu --limit lp.jasonernst.com --tags user`