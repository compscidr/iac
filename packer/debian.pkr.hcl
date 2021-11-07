variable "version" {
  type    = string
  default = ""
}

locals { timestamp = regex_replace(timestamp(), "[- TZ:]", "") }

source "vagrant" "debian11" {
  add_force    = true
  communicator = "ssh"
  provider     = "virtualbox"
  source_path  = "debian/bullseye64"
}

build {
  sources = ["source.vagrant.debian11"]

  provisioner "shell" {
    execute_command = "echo 'vagrant' | {{.Vars}} sudo -S -E bash '{{.Path}}'"
    script = "scripts/setup.sh"
  }
}
