# Network design

The target network once the Check Point firewall and the access points (Cudy
AP3000 running OpenWrt) are in place. The Asus router it replaces does not appear in the final design.

Everything here is agreed design; the configuration in `ansible/` implements
the server side (FreeRADIUS, Pi-hole, NGINX, cert-enrolment), and the firewall
and access points are configured from this document.

## Principles

* **The firewall enforces, FreeRADIUS assigns.** FreeRADIUS decides which VLAN
  a device joins; the Check Point decides what each VLAN may reach.
* **Default deny between VLANs.** Anything not listed under
  [Firewall policy](#firewall-policy) is refused, and refusals are logged.
* **Nothing depends on the servers for connectivity.** The firewall routes
  and serves DHCP; the servers provide DNS, identity and authentication, and
  a second server (Muninn) will make those highly available.

## VLANs and addressing

The third octet of each subnet is the VLAN ID. The Check Point is `.1` on
every VLAN and the default gateway.

| VLAN | Name | Subnet | Who is on it | Addressing |
|---|---|---|---|---|
| 10 | Management | 192.168.10.0/24 | Switches, access points, firewall management | Static or DHCP reservations |
| 20 | Trusted | 192.168.20.0/24 | Enrolled devices, placed by FreeRADIUS (`deviceZone: trusted`) | DHCP |
| 30 | Quarantine | 192.168.30.0/24 | Enrolled devices placed by FreeRADIUS (`deviceZone: quarantine`) | DHCP |
| 40 | IoT | 192.168.40.0/24 | Devices on the IoT Wi-Fi | DHCP |
| 50 | Servers | 192.168.50.0/24 | Huginn (`.89`), the enrolment address (`.90`), Muninn | Static |
| 60 | Onboarding | 192.168.60.0/24 | Devices being enrolled | DHCP |

The Servers VLAN keeps today's `192.168.50.0/24` so that Huginn is not
renumbered. The zone to VLAN map FreeRADIUS uses is `freeradius_zone_vlans` in
`ansible/group_vars/all/vars.yaml`.

### The enrolment address

Huginn has a second address, `192.168.50.90` (`enrolment_ipv4_address`),
used only by the enrolment services: `join` and `ra` resolve to it, and
NGINX serves those two names there and nothing else. Huginn's other
services (`ca`, `pihole`, podwatch, …) are not served on it. The firewall
can then let the low-trust VLANs reach exactly the enrolment services by
address, rather than every service behind Huginn's port 443.

The address is a `/32` added by `homelab-enrolment-address.service`, so it
is independent of Huginn's DHCP lease and outgoing traffic keeps using
`.89`. Until the Check Point replaces the Asus router, the Asus reserves
`.90` for an unused MAC address (`02:00:00:00:00:90`) so that it is never
leased to another device. With Muninn it becomes a floating address shared
by both servers.

### DHCP

The Check Point serves DHCP on each VLAN that uses it, handing out:

* the Check Point as the gateway and NTP server;
* Pi-hole as the only DNS server (both Huginn and Muninn once Muninn exists);
* `laverick.home.arpa` as the search domain.

### DNS

Pi-hole answers for every VLAN. The firewall allows DNS only to Pi-hole, so
devices cannot bypass it with their own resolvers; Pi-hole alone forwards to
the internet. Local names (`join`, `ra`, `ca`, …) are Pi-hole records.

## Wi-Fi

| SSID | Security | VLAN | Notes |
|---|---|---|---|
| `Laverick` | WPA3-Enterprise, EAP-TLS (TLS 1.3 only) | Assigned by FreeRADIUS | Only enrolled devices. A device FreeRADIUS does not accept never joins |
| `Laverick-Setup` | Enhanced Open (OWE), never plain open | 60 | External captive portal at `http://join.laverick.home.arpa/`, which is the enrolment portal itself. Never authorised to reach the internet |
| `Laverick-IoT` | WPA2-Personal (or WPA2/WPA3 transition), 2.4 GHz required | 40 | Client isolation on. Nest Protect joins only 2.4 GHz WPA2 |

### Trusted network and RADIUS

* Access points authenticate to FreeRADIUS on Huginn at
  `192.168.50.89:1812` (accounting `1813`); Muninn will be the secondary
  RADIUS server on every AP.
* Every access point is a separate RADIUS client with its own secret, in
  `freeradius_clients` (secrets in the vault). FreeRADIUS sees each AP's own
  address, since traffic between VLANs is routed, not NATed.
* `freeradius_client_networks`, which UFW admits to RADIUS, becomes the
  Management subnet `192.168.10.0/24`.
* FreeRADIUS returns `Tunnel-Type = VLAN`, `Tunnel-Medium-Type = IEEE-802`
  and `Tunnel-Private-Group-Id = <VLAN>`; `hostapd` on each AP places the
  client in that VLAN (OpenWrt's `dynamic_vlan`), and a client given no VLAN
  is refused.

### Onboarding network

The captive portal is the enrolment portal served over plain HTTP, so that
a device which does not yet trust the Root CA can sign in, register and
download its enrolment script in one step; the script installs the Root CA.
OWE encrypts the radio link, which keeps passwords from being captured
passively. The accepted risk, a fake onboarding network, is described in the
cert-enrolment README.

Nothing on the onboarding network is ever authorised to reach the internet,
so the portal only has to be found, never to let anyone through. Two ways of
sending devices to it, to be settled when the AP role is prototyped:

* **DNS (preferred).** DHCP on the Onboarding VLAN hands out a small resolver
  on the enrolment address that answers every name with that address. A
  device's captive-portal check (for example `http://captive.apple.com/`)
  then reaches NGINX on `.90` port 80, where any name other than `join` and
  `ra` is already answered by the portal. Nothing runs on the access points.
* **openNDS on each AP.** OpenWrt's usual captive portal, with the enrolment
  portal as its external page and DNS, `join` and `ra` allowed before
  authorisation.

### IoT network

The IoT devices (Blink doorbell, Amazon Alexa devices, Nest Protect, Nest
thermostat) are all controlled through their vendors' clouds, so they need
DNS and the internet and nothing local. One shared password, with client
isolation on (OpenWrt's `isolate`); per-device passwords, each able to carry
its own VLAN (`hostapd`'s per-station keys), can be added later without
redesign. Casting that
depends on local discovery (mDNS) from Trusted to IoT will not work across
VLANs; cloud-based control, including Spotify Connect, does.

## Firewall policy

Rules from each source VLAN. Replies to allowed connections are always
allowed (stateful); everything else between VLANs is denied and logged.

| From | To | Allowed |
|---|---|---|
| All VLANs | Pi-hole (Huginn, Muninn) | DNS, TCP and UDP 53 |
| All VLANs | Check Point | NTP, DHCP |
| All VLANs | Internet | No DNS (53, 853) except from Pi-hole |
| Trusted | Internet | Any |
| Trusted | Servers | HTTPS 443 (NGINX) |
| Trusted | IoT | Any (starting connections to IoT devices) |
| Trusted, admin devices only | Servers, Management | SSH 22 (including Ansible configuring the access points), HTTPS 443, LDAPS 636 |
| Quarantine | Servers | HTTPS 443 to the enrolment address (`join`, `ra`: re-enrolment) |
| Quarantine | Internet | Operating system updates only (see below) |
| Onboarding | Servers | HTTP 80 and HTTPS 443 to the enrolment address (`join`, `ra`); DNS 53 to it instead of Pi-hole if the DNS captive portal is chosen |
| Onboarding | Internet | Nothing |
| IoT | Internet | Any |
| IoT | Any other VLAN | Nothing |
| Management (APs) | Servers | RADIUS UDP 1812, 1813 to Huginn and Muninn |
| Management | Internet | OpenWrt firmware and package downloads |
| Servers | Internet | Any (updates, container images, Pi-hole upstream DNS) |

### Quarantine: operating system updates only

Quarantined devices may reach Windows Update, their Linux distribution's
package mirrors, and Apple's software update service, and nothing else on
the internet. On the Check Point this is Application Control and URL
Filtering (software update categories) or FQDN objects built from the
vendors' published lists:

* Windows: Microsoft's list of Windows Update endpoints.
* Linux: the distributions' mirrors in use (for example `deb.debian.org`,
  `security.debian.org`, `archive.ubuntu.com`, `security.ubuntu.com`).
* iOS: Apple's "Use Apple products on enterprise networks" list for software
  updates.

These lists change, so they are maintained on the firewall from the vendor
documents rather than copied here.

### Why the enrolment address

Huginn serves many names from one NGINX router on port 443, and a firewall
rule sees an address and a port, not a name. Were `join` and `ra` on `.89`,
allowing Quarantine and Onboarding to reach them would also let those
networks reach every other service on Huginn. On their own address, the
rules allow only them.

Trusted devices reach both addresses.

## Access points

Cudy AP3000 (v1) running OpenWrt, with no controller:

* **Hardware.** MediaTek MT7981, Wi-Fi 6 (2×2 on 2.4 and 5 GHz), one
  2.5 GbE port, powered by 802.3at PoE+, ceiling or wall mounted. Units
  shipped from early 2026 have a different network chip and need OpenWrt
  24.10.6 or later.
* **Network.** The single port is a trunk carrying VLANs 10 (the AP's own
  address, static on Management), 20, 30, 40 and 60.
* **Configuration.** Each AP is configured by Ansible over SSH (a role to be
  written), so the Wi-Fi settings live in this repository like everything
  else. Each AP has its own RADIUS secret.
* **Operation.** APs work independently: there is no controller to fail or
  to keep up to date. OpenWrt is upgraded with `sysupgrade`. Its failsafe
  mode on this model works only over IPv6.
* **Roaming.** With several APs, fast roaming (802.11r) avoids a full EAP-TLS
  exchange on every move; to be tested with the AP role.

## High availability (Muninn)

| Service | With Muninn |
|---|---|
| RADIUS | Second FreeRADIUS; secondary RADIUS server on every AP |
| Enrolment address | Floating between Huginn and Muninn (for example with keepalived) |
| DNS | Second Pi-hole; both handed out by DHCP |
| LDAP | Replicated |
| step-ca | Single; while it is down no certificates are issued or renewed, but Wi-Fi authentication continues |

## When the hardware arrives

1. Firewall: VLAN interfaces, DHCP scopes, the policy above; move Huginn's
   gateway from the Asus to the Check Point.
2. Pi-hole: every VLAN allowed to query; the onboarding resolver, if the
   DNS captive portal is chosen.
3. Access points: install OpenWrt on each AP3000 and apply the AP role.
4. FreeRADIUS: an entry per AP in `freeradius_clients`, and
   `freeradius_client_networks` set to `192.168.10.0/24`. Run
   `eapol-test.yml` again.
5. SSIDs as above; enrol a test device through `Laverick-Setup`.
6. NGINX: serve plain-HTTP `join` only to the Onboarding subnet.
7. Remove hosts-file entries on devices that no longer need them.
8. Remove the Asus reservation for `.90`; record `.90` as a Servers address on the Check Point.

## Not in scope yet

* A guest network (may be revisited).
* Per-device IoT passwords (`hostapd` per-station keys).
* Posture checks and automatic quarantine.
* iOS enrolment (with NanoMDM).
