# Bootstrapping
The machine running the ansible plays requires ansible >= 3.2. 
Note, this doesn't have to be the target machine where you are deploying things to.
If you want to add it to ubuntu, for example, do the following (the ansible included in ubuntu is very old)
```sudo add-apt-repository ppa:ansible/ansible && sudo apt update && sudo apt install ansible ansible-lint```

The machine running the ansible plays also needs to install the meta requirements.
This can be done with:
```ansible-galaxy install -r meta/requirements.yml```


## Ubuntu 24.04
- Install ssh and import ssh authorized key: 
```
sudo apt install ssh
ssh-import-id gh:compscidr
```

