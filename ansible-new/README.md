# Ansible

## Example commands

Run all the roles in the common playbook:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass`

Run specific roles by tag in the common playbook
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --tags sometag`

Run all roles in the common playbook on a specific machine:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --limit ubuntu-beast`

Run all roles in the common playbook on a specific machine that requires an ssh password:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --ask-pass --limit nas.local`
