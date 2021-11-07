# Packer
It turns out I don't actually need to use packer much beyond just a default
box that is available online, however this setup currently has a default
debian image with a blank customization script if I ever do want to go down
that route.

https://dev.to/mattdark/a-custom-vagrant-box-with-packer-13ke

Instead, the repo where I want to use a vagrant dev environment has a
Vagrantfile and an ansible playbook which installs all the required tools
when the machine is created.
