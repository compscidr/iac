# Infrastructure as Code

## Preqreqs:
- terraform 0.13.1 on the local deploy machine

Terraform is used to deploy resources on digital ocean. Then once the resources
are deployed, ansible is used to configure them.

Most of this was created from this guide:
https://www.digitalocean.com/community/tutorials/how-to-use-terraform-with-digitalocean#step-4-%E2%80%94-using-terraform-to-create-the-nginx-server

Everything is made to work via setting two environment variables. The DO_PAT
is the digital ocean API token. The pvt_key is set to the key which should be
rolled out to the deployed resources.

## Terraform Commands:
To plan:
`terraform plan -var "do_token=${DO_PAT}" -var "pvt_key=$HOME/.ssh/id_rsa" -var "pub_key=$HOME/.ssh/id_rsa.pub"`

To apply:
`terraform apply -var "do_token=${DO_PAT}" -var "pvt_key=$HOME/.ssh/id_rsa" -var "pub_key=$HOME/.ssh/id_rsa.pub"`

To show state:
`terraform show terraform.tfstate`

To destroy:
`terraform plan -destroy -out=terraform.tfplan \
      -var "do_token=${DO_PAT}" \
      -var "pvt_key=$HOME/.ssh/id_rsa" \
      -var "pub_key=$HOME/.ssh/id_rsa.pub"`

to make the destroy plan and `terraform apply terraform.tfplan`

## Ansible
https://www.digitalocean.com/community/tutorials/how-to-use-ansible-with-terraform-for-configuration-management
