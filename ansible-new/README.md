# Ansible
For any plays which deploy secrets / credentials, all of these are managed by 1password.
The plays are setup to lookup the secrets using 1password cli (op). In order for this 
to work, you must login to onepassword in the terminal you are doing the deploying from.

You can do this: `eval $(op signin)` in order to login, and enter your 1password password.

After this, you can run any of the example commands below

## Example commands

Run all the roles in the common playbook:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass`

Run specific roles by tag in the common playbook
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --tags sometag`

Run all roles in the common playbook on a specific machine:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --limit ubuntu-beast`

Run all roles in the common playbook on a specific machine that requires an ssh password:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --ask-pass --limit nas.local`
