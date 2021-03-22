# Infrastructure as Code

Most of this was created from this guide:
https://www.digitalocean.com/community/tutorials/how-to-use-terraform-with-digitalocean#step-4-%E2%80%94-using-terraform-to-create-the-nginx-server

## Commands:
To plan:
`terraform plan -var "do_token=${DO_PAT}" -var "pvt_key=$HOME/.ssh/id_rsa"`

To apply:
`terraform apply -var "do_token=${DO_PAT}" -var "pvt_key=$HOME/.ssh/id_rsa"`

To show state:
`terraform show terraform.tfstate`

To destroy:
`terraform plan -destroy -out=terraform.tfplan \
      -var "do_token=${DO_PAT}" \
      -var "pvt_key=$HOME/.ssh/id_rsa" \`

to make the destroy plan and `terraform apply terraform.tfplan`
