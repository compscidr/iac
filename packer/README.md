# Packer
Using this to generate VM images that are consistent without having to go
through the install process.

Source: https://github.com/glisignoli/packer-debian-sid

Goal is to get it to the stage where I can just run ansible on it like any
other host.

To make it easy, I'd like it to be on a bridge network so that it appears as if
it is any other machine on the lan (and thus gets an IP address that can be
reached by ansible from any other ansible ready machine).

It must also have ssh setup, and the ssh keys imported so that ansible may run.

The easiest way I've done this is via the github ssh key import.

After that, everything else is ready to rock.

To build the image:
`PACKER_PASSWORD=<insert password> packer build debian-sid.json`

Start it up in virtualbox, get the IP address, add it to the ansible inventories
and then run ansible.
