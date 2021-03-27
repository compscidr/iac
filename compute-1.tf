resource "digitalocean_droplet" "compute" {
  count = 1
  image = "ubuntu-20-10-x64"
  name = "compute-${count.index}"
  region = "sfo2"
  size = "s-1vcpu-1gb"
  ipv6 = true
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
}

# https://www.digitalocean.com/community/tutorials/how-to-create-reusable-infrastructure-with-terraform-modules-and-templates
# https://coffay.haus/pages/terraform+ansible/
resource "local_file" "ansible_inventory" {
  content = templatefile("inventory.tmpl", {
      droplets = digitalocean_droplet.compute,
  })
  filename = format("%s/%s", abspath(path.root), "inventory.yml")
}

# assuming we're only working with a single compute for now
resource "digitalocean_domain" "default" {
  name = "jasonernst.com"
  ip_address = digitalocean_droplet.compute[0].ipv4_address
}

resource "digitalocean_record" "AAAA" {
  domain = digitalocean_domain.default.name
  type = "AAAA"
  name = "@"
  value = digitalocean_droplet.compute[0].ipv6_address
}

resource "digitalocean_record" "CNAME-www" {
  domain = digitalocean_domain.default.name
  type = "CNAME"
  name = "www"
  value = "@"
}

resource "digitalocean_record" "CNAME-ombi" {
  domain = digitalocean_domain.default.name
  type = "CNAME"
  name = "ombi"
  value = "@"
}

resource "digitalocean_record" "txt" {
  domain = digitalocean_domain.default.name
  type = "TXT"
  name = "@"
  value = "keybase-site-verification=YuSsvhu0S_6Oy2jZeTSr9ZojN-hYTcSl4HlWTvYxZBw"
}

resource "digitalocean_record" "A-home" {
  domain = digitalocean_domain.default.name
  type = "A"
  name = "home"
  value = "24.6.50.83"
}

resource "digitalocean_record" "AAAA-home" {
  domain = digitalocean_domain.default.name
  type = "AAAA"
  name = "home"
  value = "2601:646:ca00:f9b0:5e09:5ca:caeb:8f27"
}

output "droplet_ip_addresses" {
  value = {
    for droplet in digitalocean_droplet.compute:
    droplet.name => droplet.ipv4_address
  }
}
