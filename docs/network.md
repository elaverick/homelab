# Network design

The target network once the Check Point firewall and the UniFi access points
are in place. The Asus router it replaces does not appear in the final design.

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
| 50 | Servers | 192.168.50.0/24 | Huginn (`.89`), Muninn | Static |
| 60 | Onboarding | 192.168.60.0/24 | Devices being enrolled | DHCP |

The Servers VLAN keeps today's `192.168.50.0/24` so that Huginn is not
renumbered. The zone to VLAN map FreeRADIUS uses is `freeradius_zone_vlans` in
`ansible/group_vars/all/vars.yaml`.

### DHCP

The Check Point serves DHCP on each VLAN that uses it, handing out:

* the Check Point as the gateway and NTP server;
* Pi-hole as the only DNS server (both Huginn and Muninn once Muninn exists);
* `laverick.home.arpa` as the search domain.

### DNS

Pi-hole answers for every VLAN. The firewall allows DNS only to Pi-hole, so
devices cannot bypass it with their own resolvers; Pi-hole alone forwards to
the internet. Local names (`join`, `ra`, `ca`, `unifi`, …) are Pi-hole records.

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
  and `Tunnel-Private-Group-Id = <VLAN>`; the SSID needs RADIUS-assigned VLANs
  enabled.

### Onboarding network

The captive portal is the enrolment portal served over plain HTTP, so that
a device which does not yet trust the Root CA can sign in, register and
download its enrolment script in one step; the script installs the Root CA.
OWE encrypts the radio link, which keeps passwords from being captured
passively. The accepted risk, a fake onboarding network, is described in the
cert-enrolment README.

Pre-authorisation access on the AP: DNS, `join` and `ra`. The portal never
authorises a client, so nothing reaches the internet.

### IoT network

The IoT devices (Blink doorbell, Amazon Alexa devices, Nest Protect, Nest
thermostat) are all controlled through their vendors' clouds, so they need
DNS and the internet and nothing local. One shared password; per-device
passwords (UniFi PPSK) can be added later without redesign. Casting that
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
| Trusted, admin devices only | Servers, Management | SSH 22, HTTPS 443, LDAPS 636, UniFi controller UI |
| Quarantine | Servers | HTTPS 443 to Huginn (`join`, `ra`: re-enrolment) |
| Quarantine | Internet | Operating system updates only (see below) |
| Onboarding | Servers | HTTP 80 and HTTPS 443 to Huginn (`join`, `ra`) |
| Onboarding | Internet | Nothing |
| IoT | Internet | Any |
| IoT | Any other VLAN | Nothing |
| Management (APs) | Servers | RADIUS UDP 1812, 1813 to Huginn and Muninn; UniFi inform TCP 8080 and STUN UDP 3478 to the controller |
| Management | Internet | Firmware downloads |
| Servers | Internet | Any (updates, container images, Pi-hole upstream DNS) |
| Servers | Management | SSH 22 (UniFi controller adopting APs) |

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

### What the Servers rules cannot distinguish

Port 443 on Huginn is one NGINX SNI router for every service (`join`, `ra`,
`ca`, `pihole`, …). The firewall allows the port, not the name, so a
quarantined or onboarding device can reach any of those names; each service
still requires its own authentication. Restricting by name, if wanted, is
done in NGINX by source address.

## UniFi controller

UniFi Network Server runs as a container on Huginn (Podman and Quadlet, like
the other services), with backups that can be restored on Muninn; it does not
cluster. Access points keep serving Wi-Fi, including EAP-TLS, while the
controller is down; whether the captive portal also needs it is to be
confirmed when the APs arrive.

Access points on Management find the controller on Servers through the
Pi-hole record `unifi.laverick.home.arpa`.

## High availability (Muninn)

| Service | With Muninn |
|---|---|
| RADIUS | Second FreeRADIUS; secondary RADIUS server on every AP |
| DNS | Second Pi-hole; both handed out by DHCP |
| LDAP | Replicated |
| step-ca | Single; while it is down no certificates are issued or renewed, but Wi-Fi authentication continues |
| UniFi controller | Backup restored on Muninn when needed |

## When the hardware arrives

1. Firewall: VLAN interfaces, DHCP scopes, the policy above; move Huginn's
   gateway from the Asus to the Check Point.
2. Pi-hole: records for `unifi`, and every VLAN allowed to query.
3. UniFi controller on Huginn; adopt the APs on Management.
4. FreeRADIUS: an entry per AP in `freeradius_clients`, and
   `freeradius_client_networks` set to `192.168.10.0/24`. Run
   `eapol-test.yml` again.
5. SSIDs as above; enrol a test device through `Laverick-Setup`.
6. NGINX: serve plain-HTTP `join` only to the Onboarding subnet.
7. Remove hosts-file entries on devices that no longer need them.

## Not in scope yet

* A guest network (may be revisited).
* Per-device IoT passwords (UniFi PPSK).
* Posture checks and automatic quarantine.
* iOS enrolment (with NanoMDM).
