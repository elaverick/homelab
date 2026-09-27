# Deployment

What has to exist before `ansible/site.yml` can build a server, and how to
check the result. Everything listed here lives outside the playbook: files
kept out of Git, secrets in the vault, and settings on other devices.

## Control machine

* `ansible-core`, and the collections in `ansible/requirements.yml`:

  ```sh
  ansible-galaxy collection install -r ansible/requirements.yml
  ```

* SSH access to the server as a user that can `sudo`.
* The Ansible vault password. `ansible/bitwarden-vault-client.sh` fetches it
  from Bitwarden and needs the Bitwarden CLI (`bw`); the script describes its
  own settings.

## Files kept out of Git

These are listed in `.gitignore` and must be put in place on the control
machine:

| Path | What it is |
|---|---|
| `ansible/inventory/hosts` | The inventory: the `physical_servers` group and how to reach each server |
| `ansible/bitwarden-vault-client.sh` | Vault password helper (optional; any way of supplying the vault password works) |
| `certs/rootCA.crt` | Root CA certificate, from the offline Root CA (`ca/root/`) |
| `certs/intermediateCA.crt`, `certs/intermediateCA.key` | Intermediate CA certificate and key, signed by the offline Root CA |

## Vault

`ansible/group_vars/all/vault.yaml` is encrypted and holds:

| Variable | Used for |
|---|---|
| `ldap_password` | LDAP administrator password |
| `freeradius_bind_password` | FreeRADIUS's LDAP service account |
| `cert_enrolment_bind_password` | The cert-enrolment RA's LDAP service account |
| `cert_enrolment_provisioner_jwk` | Private key of the step-ca provisioner the RA signs tokens with (an EC P-256 JWK) |
| `pihole_webserver_api_password` | Pi-hole web interface |
| `intermediateCA_key_passphrase` | Passphrase of the Intermediate CA key |

RADIUS secrets for access points will be added here too, one per AP (see
`freeradius_clients` in the freeradius role).

The first run of `ldap-config` that creates users asks for each user's
initial password.

## The server

* Debian 13; `base_host` refuses anything else.
* Internet access, for Debian packages, the Smallstep repository and
  container images (`ghcr.io`, `docker.io`).

## The network

Until the Check Point replaces the Asus router (see
[network.md](network.md)):

| On the Asus | Why |
|---|---|
| Reserve Huginn's address (`192.168.50.89`) for its MAC address | Everything else refers to it: DNS records, RADIUS, firewall rules to come |
| Reserve `192.168.50.90` for the unused MAC `02:00:00:00:00:90` | The enrolment address (`enrolment_ipv4_address`), which Huginn claims itself; the reservation stops DHCP leasing it to another device |

The playbook checks the enrolment address before claiming it and stops if it
is not on the server's network or if another device answers for it.

### Names on client devices

Devices that use Pi-hole for DNS resolve everything. Devices that do not yet
use it need hosts-file entries:

| Address | Names |
|---|---|
| `192.168.50.89` | `ca`, `pihole`, `ldap`, `huginn` |
| `192.168.50.90` | `join`, `ra` |

All under `laverick.home.arpa`. An enrolled Windows or Linux device renews
its certificate through `ra`, so it must keep resolving `ra` correctly.

## Running

From `ansible/`:

```sh
ansible-playbook -i inventory --vault-password-file bitwarden-vault-client.sh site.yml
```

## Checking

* `https://join.laverick.home.arpa/` shows the sign-in page.
* `eapol-test.yml` tests Wi-Fi authentication end to end, standing in for an
  access point:

  ```sh
  ansible-playbook -i inventory --vault-password-file bitwarden-vault-client.sh eapol-test.yml
  ```
