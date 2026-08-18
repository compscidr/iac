# sshd_alt_port_ugos Role

`sshd_alt_port` for the UGREEN NAS: a **second, stock OpenSSH instance** on port 2222
(`ssh-alt.service`, config `/etc/ssh/sshd_config_alt`), because on UGOS the Ubuntu
role's approach — extending the stock sshd's listen config — isn't available. The
vendor owns `sshd_config`, wraps shells/commands globally, and chroots the SFTP
subsystem to a share view (`/docker`, `/home`, `/storage`) that does not contain the
real filesystem.

## Why

Diagnosed live 2026-08-18 (rustd.xyz#456): the rustd.xyz panel's SSH credential for the
NAS-hosted game servers could run every exec command (wipes, snapshots, seed rewrites all
work through the wrapper), but every SFTP operation against a real path failed — Mina
reports `SFTP error (-2): Operation unsupported`, OpenSSH's sftp shows the path simply
absent from its chrooted view. That silently broke the panel's moderator roster, snapshot
listing, blueprint-preservation scan, vanilla map fetch and file browser for those
servers.

A second sshd instance with a clean config keeps the same account, groups, shell
environment and filesystem the panel's exec commands already use — only SFTP changes,
from the vendor's share view to the real filesystem. Port 2222 matches `sshd_alt_port`
everywhere else in the estate, and also pre-empts the Tailscale-SSH-owns-port-22 problem
that role exists for, should the badge ever be enabled on the NAS.

## What it deliberately does not do

- Touch the vendor sshd, its config, or port 22 in any way.
- Allow password auth, root, or any user beyond `sshd_alt_port_ugos_allow_users`.

After deploying, point the panel's SSH credential for the NAS servers at port 2222.
