# Vagrant
This lets us spin up a blank slate virtual machine of a specific
OS and then test the ansible setup on it.

The only requirement to make this work is having an env variable
set on the host which is the `OP_SERVICE_ACCOUNT_TOKEN` variable.
If the host has been deployed via ansible it should already be
set. 

On CI, to run these smoke tests, it would need to be set also.

All that you need to do is:
`vagrant up`
and if its already up,
`vagrant provision`
although, that will not necessarily run on a clean setup.

In order to do that, you can do:
`vagrant destroy` first.