#!/bin/bash
# run as root
# https://www.bisecthosting.com/clients/index.php?rp=/knowledgebase/618/How-to-setup-automatic-server-wipes-on-a-Rust-server.html
docker stop rust-monthly
rm server/rust_docker/player.deaths.*
rm server/rust_docker/*.map
rm server/rust_docker/*.sav*
sudo sed -i~ '/^RUST_SERVER_SEED=/s/=.*/='$RANDOM'/' seed.env
docker start rust-monthly