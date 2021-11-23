resource "digitalocean_vpc" "www-jasonernst-vpc" {
  name = "www-jasonernst-vpc"
  region = "sfo2"
  ip_range = "10.10.10.0/24"
}

# size chart: https://developers.digitalocean.com/documentation/changelog/api-v2/new-size-slugs-for-droplet-plan-changes/
resource "digitalocean_droplet" "www-jasonernst-com" {
  image = "ubuntu-20-04-x64"
  name = "www-jasonernst-com"
  region = "sfo2"
  size = "s-1vcpu-2gb"
  ipv6 = true
  vpc_uuid = digitalocean_vpc.www-jasonernst-vpc.id
  ssh_keys = [28506911]
}

resource "aws_instance" "lp-jasonernst-com" {
  ami = "ami-053ac55bdcfe96e85"
  instance_type = "t2.micro"
  key_name = aws_key_pair.aws_devops.key_name
}

resource "digitalocean_domain" "default" {
  name = "jasonernst.com"
  ip_address = digitalocean_droplet.www-jasonernst-com.ipv4_address
}

resource "digitalocean_record" "AAAA" {
  domain = digitalocean_domain.default.name
  type = "AAAA"
  name = "@"
  value = digitalocean_droplet.www-jasonernst-com.ipv6_address
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
  value = "98.207.181.75"
}

resource "digitalocean_record" "CNAME-lp" {
  domain = digitalocean_domain.default.name
  type = "A"
  name = "lp"
  value = aws_instance.lp-jasonernst-com.public_ip
}

output "droplet_ip_addresses" {
  value = digitalocean_droplet.www-jasonernst-com.ipv4_address
}
