# pi-tailscale

Remote SSH (and, optionally, a web admin page) to a Raspberry Pi over
[Tailscale](https://tailscale.com), without opening anything to the network
the device sits on.

`install.sh` installs Tailscale from its own apt repository and then **adds
to whatever firewall the device already has**: only the rules needed, only
where something would otherwise block Tailscale, and nothing at all if
nothing would. Everything it adds is tagged `pi-tailscale` and comes out
again with `uninstall.sh`.

Written for Raspberry Pi OS (Debian 12/13) and devices running
[star-lan-bridge](https://github.com/rtfmoz2/star-lan-bridge), but nothing in
it depends on star-lan-bridge.

## Install

```bash
git clone https://github.com/rtfmoz2/pi-tailscale.git
cd pi-tailscale
sudo ./install.sh
sudo tailscale up          # open the link it prints to add the device to your tailnet
```

Then, in the Tailscale admin console, **turn off key expiry** for the device.
Otherwise it drops off the tailnet after 180 days and needs someone on site
to log it in again.

Options:

| Option | What it does |
|---|---|
| `--ports "22 80"` | TCP ports allowed in over Tailscale. Default: `22`, plus `80` if star-lan-bridge's admin page is installed. Saved in `/etc/default/pi-tailscale`. |
| `--auto-updates` | Let unattended-upgrades update Tailscale too (adds the Tailscale origin; only if unattended-upgrades is installed and on). |
| `--no-log-upload` | Stop tailscaled sending its logs to Tailscale (`--no-logs-no-support`). Tailscale support can't help with this device afterwards. |

Running it again is safe; it updates the add-on's files and leaves your
settings alone (unless you pass `--ports`).

## Uninstall

```bash
sudo ./uninstall.sh                     # remove the add-on; Tailscale stays
sudo ./uninstall.sh --remove-tailscale  # also log out and remove Tailscale
```

## What it changes

**Tailscale itself:** the `tailscale` package and its apt source. Its
preferences are left at their defaults, which suit a device like this: it
doesn't accept routes from other devices and doesn't use an exit node, so
Tailscale never becomes the default route and the device's LAN addresses and
services are unaffected.

**The firewall.** Each rule accepts the chosen TCP ports **only when they
arrive on the `tailscale0` interface**, plus Tailscale's own UDP port (41641,
or `PORT=` in `/etc/default/tailscaled`) so devices can connect directly
rather than through a relay. Matching the interface rather than Tailscale's
address range (100.64.0.0/10) matters: some networks use that range too, and
they must not get in this way.

| Firewall on the device | What pi-tailscale adds |
|---|---|
| None, or one that accepts everything | **Nothing.** Tailscale already gets through. |
| nftables (`/etc/nftables.conf`) | `/etc/nftables.d/tailscale-00.nft`: rules for each input chain in your config that can drop packets. If `nftables.conf` doesn't include `/etc/nftables.d/*.nft` already, one line is added at its end (marked `# added by pi-tailscale`). |
| ufw | `ufw allow in on tailscale0 ...` rules, saved by ufw. |
| firewalld | `/etc/firewalld/zones/pi-tailscale.xml`: a zone holding `tailscale0` and the chosen ports. |
| iptables / ip6tables rules loaded some other way | Rules at the top of `INPUT`, if `INPUT` can drop packets. |

Saved rules apply whenever that firewall is on, **including if it's switched
on later**: the nftables drop-in, ufw rules and firewalld zone are written even
while the firewall is off.

How the nftables drop-in stays correct:

* It's generated from your `/etc/nftables.conf`, read in a throwaway network
  namespace, so the running firewall is never touched to work out what's
  needed.
* It's rewritten just before nftables loads (a drop-in for
  `nftables.service`), so it always matches the chains your config defines,
  even after you edit it.
* Every change is checked with `nft -c` first and reverted if the check
  fails. (A failed reload leaves the previous rules running anyway: nftables
  loads atomically.)

Rules in the running firewall are put back if something reloads it without
the drop-in (for example an older script running `nft -f` on its own
config): `pi-tailscale-firewall.service` re-applies them when nftables or
netfilter-persistent loads, and a timer re-checks every 5 minutes. It writes
to the journal only when it actually adds something.

**star-lan-bridge's admin page** (only if it's installed and port 80 is
chosen): a systemd drop-in that adds Tailscale's addresses to the page's
allowed list (`IPAddressAllow`). The printer ports are never opened over
Tailscale.

To see what's in place:

```bash
sudo pi-tailscale-firewall status
```

## Tested

On a Raspberry Pi 4 (Raspberry Pi OS, Debian 13, Tailscale 1.104):

* no firewall running: nothing added
* star-lan-bridge's hardened nftables firewall: SSH and the admin page over
  Tailscale work, the printer ports aren't reachable over Tailscale, and LAN
  access is unchanged; rules survive nftables start, restart and reload; a
  manual `nft -f` without the drop-in is repaired by the re-check; a partly
  deleted or outdated rule set is replaced, an up-to-date one left alone
* `uninstall.sh` removes everything it added and nothing else

The ufw, firewalld and plain iptables paths have **not** been tested on a
device yet.

## Performance on a Raspberry Pi 4

Measured from a Mac on the same Wi-Fi network, Tailscale connecting directly
(not relayed), one TCP stream of 150 MB each way, compared with the same
transfer over the LAN:

| | LAN | Tailscale |
|---|---|---|
| Idle CPU (tailscaled) | | 0.3% of one core |
| Memory (tailscaled) | | 43 MB of 1.8 GB |
| Ping (average) | 6.6 ms | 8.2 ms (+1.6 ms) |
| Throughput to the device | ~110 Mbit/s | ~85 Mbit/s (−22%) |
| Throughput from the device | ~112 Mbit/s | ~100 Mbit/s (−10%) |
| Device CPU, all 4 cores, receiving | 10% | 33% (tailscaled ~0.9 of a core) |
| Device CPU, all 4 cores, sending | 6% | 21% (tailscaled ~0.65 of a core) |

Wi-Fi was the limit on the LAN. The difference over Tailscale is WireGuard
encryption in software, mostly on the receiving side. SSH and an admin page
use a tiny fraction of this, so in day-to-day use only the idle figures
matter. Printing through star-lan-bridge (status polls, print round-trips)
timed the same with Tailscale running and stopped. Not measured: a relayed
connection (adds latency, not device CPU) or slower boards such as a Pi Zero.

## Before deploying to a device you can't easily reach

* Turn off **key expiry** for the device in the Tailscale admin console.
* Review your tailnet's **access policy**: by default every device on the
  tailnet can reach every port the firewall lets in. Consider a tag for these
  devices and a rule allowing only `tcp:22` (and `tcp:80`) from your own
  devices.
* Decide on updates: `--auto-updates` if unattended-upgrades runs on the
  device, otherwise `sudo apt upgrade` when you log in.
* Decide on log upload (`--no-log-upload`). Locally, tailscaled logs to the
  journal like any other service and stays well inside a capped journal.
* Keep an SSH key for LAN access too: if Tailscale is down, you can still get
  in on site.

## Licence

MIT, see [LICENSE](LICENSE).
