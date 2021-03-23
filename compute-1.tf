resource "digitalocean_droplet" "compute" {
  count = 1
  image = "ubuntu-20-10-x64"
  name = "compute-${count.index}"
  region = "sfo2"
  size = "s-1vcpu-1gb"
  private_networking = true
  ssh_keys = [
    data.digitalocean_ssh_key.terraform.id
  ]

  provisioner "remote-exec" {
    inline = ["sudo apt update", "sudo apt install python3 -y", "echo Done!"]

    connection {
      host = self.ipv4_address
      user = "root"
      type = "ssh"
      private_key = file(var.pvt_key)
      timeout = "2m"
    }
  }

  # todo: enable this when we have local ansible and ansible galaxy setup
  # along with the ansible docker role
  # provisioner "local-exec" {
  #  command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u root -i '${self.ipv4_address},' --private-key ${var.pvt_key} -e 'pub_key=${var.pub_key}' apache-install.yml"
  # }
}

output "droplet_ip_addresses" {
  value = {
    for droplet in digitalocean_droplet.compute:
    droplet.name => droplet.ipv4_address
  }
}
