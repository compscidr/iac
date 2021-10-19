#!/bin/bash

# Set up packages
apt-get install -y nano ssh-import-id

# Set up sudo
echo %$SUDO_USER ALL=NOPASSWD:ALL > /etc/sudoers.d/$SUDO_USER
chmod 0440 /etc/sudoers.d/$SUDO_USER

# Set up sudo to allow no-password sudo for "sudo"
usermod -a -G sudo $SUDO_USER

# Installing vagrant keys
mkdir /home/$SUDO_USER/.ssh
chmod 700 /home/$SUDO_USER/.ssh
cd /home/$SUDO_USER/.ssh
ssh-import-id gh:compscidr
chmod 600 /home/$SUDO_USER/.ssh/authorized_keys
chown -R $SUDO_USER /home/$SUDO_USER/.ssh

# Vagrant nfs
mkdir /vagrant

# Fix grub timeout
sed -i 's/GRUB_TIMEOUT.*/GRUB_TIMEOUT=0/' /etc/default/grub
grub-mkconfig
