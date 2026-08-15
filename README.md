# Homelab

Infrastructure configuration and container definitions for my homelab.

## Services

- **LDAP** — OpenLDAP running in a rootless Podman container
- **Intermediate CA** — Smallstep `step-ca` providing certificates for homelab services
- **Root CA** — Offline Root CA used to sign the Intermediate CA
- More services will be added as required.

## Approach

| Component | Purpose |
|---|---|
| **Ansible** | Host and service configuration |
| **Podman** | Rootless container runtime |
| **Quadlet** | Container service definitions |
| **systemd** | Service lifecycle management |
| **GHCR** | Container image registry |
| **Smallstep** | Certificate authority |

Services are deployed using Ansible and run under rootless Podman. Quadlet integrates the containers with the user-level systemd instance.

The Root CA remains offline. The Intermediate CA runs online and issues certificates for homelab services.

## Where to Find Things

```text
homelab/
├── ansible/
│   ├── site.yml                    # Main deployment playbook
│   ├── inventory/                  # Hosts
│   ├── group_vars/                 # Shared configuration and secrets
│   └── roles/
│       ├── base_host/              # Host configuration
│       ├── ldap/                   # LDAP container deployment
│       ├── ldap-config/            # LDAP configuration
│       └── intermediate-ca/        # Intermediate CA deployment
│
├── ca/
│   └── root/
│       └── ansible/                # Offline Root CA project
│
├── certs/                           # CA certificates and Intermediate CA key
│
└── containers/
    └── ldap/                        # LDAP container image definition
```

## Certificate Architecture

```text
                    Offline Root CA
                         │
                         │ signs
                         ▼
                 Intermediate CA
                 ca.laverick.home.arpa
                         │
              ┌──────────┴──────────┐
              │                     │
             ACME             Future clients/
              │                devices/mTLS
              │
        ┌─────┼─────┐
        │     │     │
      LDAPS  HTTPS  ...
```

The Root CA private key never leaves the offline Root CA.

The Intermediate CA uses the Root CA certificate and its own encrypted private key. Its private-key passphrase is managed through Ansible Vault and a Podman Secret.

## Current Status

- [x] Base host configuration
- [x] Rootless Podman
- [x] LDAP container
- [x] LDAP configuration
- [x] Offline Root CA
- [x] Intermediate CA
- [x] Quadlet/systemd deployment
- [x] ACME provisioner
- [ ] Device provisioner
- [ ] Client/mTLS provisioner
- [ ] LDAPS certificate issued by Intermediate CA