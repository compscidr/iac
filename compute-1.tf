resource "digitalocean_droplet" "compute-1" {
  image = "ubuntu-20-10-x64"
  name = "compute-1"
  region = "sfo2"
  size = "s-1vcpu-1gb"
  private_networking = true
  ssh_keys = [
    data.digitalocean_ssh_key.terraform.id
  ]

  connection {
    host = self.ipv4_address
    user = "root"
    type = "ssh"
    private_key = file(var.pvt_key)
    timeout = "2m"
  }
}
