#!/bin/bash
# run as root
# https://www.bisecthosting.com/clients/index.php?rp=/knowledgebase/618/How-to-setup-automatic-server-wipes-on-a-Rust-server.html
docker stop rust-weekly
rm server/rust_docker_weekly/player.deaths.*
rm server/rust_docker_weekly/*.map
rm server/rust_docker_weekly/*.sav*
sudo sed -i~ '/^RUST_SERVER_SEED=/s/=.*/='$RANDOM'/' seed.env
docker start rust-weekly