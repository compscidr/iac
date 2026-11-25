# LAN hosts reachable by `.local` or Tailscale

## Intent

The home machines are named in `ansible/inventory.yml` by their mDNS name
(`ubuntu-beast.local`). Away from home that name resolves to nothing, so every
playbook run needed `-e ansible_host=ubuntu-beast` by hand. The same command
should work from home and from anywhere else.

Decision (2026-11-25): always try `.local` first and fall back to Tailscale.

## Scope

- Hosts: `ubuntu-beast.local`, `ubuntu-silverstone.local`, `ubuntu-cube.local`,
  `ubuntu-work-laptop.local`, `jasons-macbook-air.local`.
- Not included: the asus and toshiba laptops and `nas.local`, which are not on
  the tailnet.
- Inventory names, `host_vars` file names and `--limit ubuntu-beast.local` do
  not change. A bare `--limit ubuntu-beast` is not added.

## Approaches

1. **Group variable calling a cached helper (chosen).** A `lan` inventory
   group sets `ansible_host` from `ansible/scripts/lan-or-tailscale`. Covers
   every play and ad-hoc command with no per-playbook change.
2. **Pre-task per play.** This existed as `tasks/lan_or_tailnet.yml`, used by
   one playbook. It needs `gather_facts: false` plus an include in every play,
   does nothing for ad-hoc commands, and relies on `getent`, which macOS
   lacks. Removed in favour of approach 1 so there is one mechanism.
3. **SSH `ProxyCommand` fallback.** Keeps Ansible unaware of the switch, but
   pays the failed lookup on every new connection and hides which route was
   used.

## Design

- `lan-or-tailscale <inventory-hostname>` prints the address to use.
  - Opens a TCP connection to port 22 on the `.local` name, with a 2-second
    limit on the whole attempt including name resolution. Connecting, not
    just resolving, means a stale mDNS answer still falls back.
  - On success prints the `.local` name; otherwise the name without `.local`.
  - Caches the answer per host for 5 minutes in
    `$XDG_RUNTIME_DIR/lan-or-tailscale` (else `~/.cache/lan-or-tailscale`),
    because Ansible re-evaluates `ansible_host` for every task and a failed
    mDNS lookup blocks for about 5 seconds.
  - Python, standard library only, so it runs on a Linux or macOS controller.
- `ansible/group_vars/lan.yml` sets `ansible_host` through a `pipe` lookup.
- Tests in `ansible/scripts/test_lan_or_tailscale.py`, run in the CI lint job.

## Known costs

- After changing networks mid-session the cached answer can be wrong for up to
  5 minutes; deleting the cache directory resets it.
- A host unreachable both ways fails under its Tailscale name, so the error
  mentions `ubuntu-beast`, not `ubuntu-beast.local`.
- Host keys must be trusted under both names on the controller. They are on
  the work laptop today; a new controller will prompt once per name.
