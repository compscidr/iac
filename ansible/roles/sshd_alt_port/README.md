# sshd_alt_port Role

Makes the **real** OpenSSH sshd listen on an alternate port (default `2222`) on every
Ubuntu host that has tailscale installed, so key-based automation keeps working on hosts
where Tailscale SSH owns port 22.

## Why

Tailscale SSH (`RunSSH=true`, the green "SSH" badge in the admin console) intercepts every
**tailnet** connection to port 22 and answers with Tailscale's own SSH server (`ssh -vv`:
`remote software version Tailscale`). It authenticates by tailnet identity + ACL — never
`authorized_keys` — and the tailnet's default `check` rule demands a browser re-auth, which
non-interactive clients can never satisfy. That's why the rustd.xyz panel on `projects`
could reach `nas` (no Tailscale SSH) but got "an auth request to tailscale" from
`ubuntu-cube` (badge on). LAN connections bypass the interception entirely, which is what
makes the failure look mysterious: the same host, key and client work from the LAN.

The alternatives all give up something (verified live 2026-08-13):

- `tailscale set --ssh=false` — loses Tailscale SSH's browser-gated access entirely.
- ACL `action: accept` — works (exec and SFTP through Tailscale SSH were verified working
  in accept/check-satisfied mode), but authorizes by node identity alone: one compromised
  tailnet node can then ssh into the rest with **no key**. Rejected for exactly that.
- **Alternate port (this role)** — keeps both properties: `:22` stays Tailscale SSH with
  check-mode for humans; `:2222` (configurable via `sshd_alt_port_number`) is the real
  sshd, key-auth only, so a compromised
  peer without the private key still gets nothing. Interception is port-22-only, so the
  alternate port passes straight through to the host over the tailnet.

## What it does

Gated on `ansible_distribution == "Ubuntu"` **and** `/usr/bin/tailscale` existing (so the
molecule container, the macbook and the UGOS nas all skip it). Then, whichever listen
mechanism is live gets the port:

- **Socket-activated** (`ssh.socket` enabled — Ubuntu 22.10+): drop-in
  `/etc/systemd/system/ssh.socket.d/alt-port.conf` with an additive `ListenStream`.
  `Port` lines in `sshd_config` are silently ignored on these hosts, a trap worth
  remembering.
- **Classic service**: `/etc/ssh/sshd_config.d/60-alt-port.conf` with BOTH `Port 22` and
  the alternate (once any `Port` appears, the default 22 is dropped), validated with
  `sshd -t` before landing.

Existing SSH sessions survive the socket/service restart.

## Consumers

The rustd.xyz panel's SSH credentials carry a port field — point a credential at the
host's tailscale address with port 2222 (e.g. `100.126.183.41:2222` for the bare-metal
test server) and key auth works over the tailnet regardless of the SSH badge.

## Firewall note

None of these hosts run a host firewall that filters the tailscale interface today. If
one ever does (ufw etc.), the alternate port needs allowing on `tailscale0` — the role
deliberately does not manage firewalls it can't see.
