# Homelab

Infrastructure configuration for a home network built around open standards and self-hosted services.

## Objective

The aim of this project is to build a homelab that provides control over the home network, particularly Wi-Fi authentication and the services that support it.

The intended core services are:

* **FreeRADIUS** — Wi-Fi authentication and network access control
* **LDAP** — Identity and device information used by network services
* **Pi-hole** — DNS filtering and local network name resolution
* **NGINX** — Common entry point and proxy for network services
* **Internal PKI** — Certificates for securing homelab services

The project is intended to be simple, reproducible and easy to extend as additional services are added.

## Architecture

```text
                         Home Network
                              │
                         Wi-Fi clients
                              │
                              ▼
                         FreeRADIUS
                              │
                              ▼
                            LDAP
                              │
             ┌────────────────┼────────────────┐
             │                │                │
          Pi-hole          Services        Network
             │                │             access
             │                │
             └────────── NGINX ───────────────┘
                              │
                         TLS certificates
                              │
                         Intermediate CA
                              │
                         Offline Root CA
```

Ansible provides the main deployment entry point and configures both the underlying host and the services running on it.

Containerised services run under rootless Podman and are managed through Quadlet and systemd.

The Root CA remains offline. An online Intermediate CA issues certificates for services within the homelab.

## Technology

| Component     | Purpose                        |
| ------------- | ------------------------------ |
| **Ansible**   | Host and service configuration |
| **Podman**    | Rootless container runtime     |
| **Quadlet**   | Container service definitions  |
| **systemd**   | Service lifecycle management   |
| **NGINX**     | HTTP/HTTPS and network proxy   |
| **LDAP**      | Directory and identity service |
| **Pi-hole**   | DNS and network filtering      |
| **Smallstep** | Internal certificate authority |
| **GHCR**      | Container image registry       |

## Repository Structure

```text
homelab/
├── ansible/
│   ├── site.yml
│   ├── inventory/
│   ├── group_vars/
│   └── roles/
│       ├── base_host/
│       ├── certificate/
│       ├── intermediate-ca/
│       ├── ldap/
│       ├── ldap-config/
│       ├── nginx/
│       ├── pihole/
│       └── software-inventory/
│
├── ca/
│   └── root/
│       └── ansible/
│
└── containers/
    └── ldap/
```

## Certificate Architecture

```text
                    Offline Root CA
                         │
                         │ signs
                         ▼
                 Intermediate CA
                         │
                    issues certificates
                         │
              ┌──────────┼──────────┐
              │          │          │
            LDAP       NGINX     Other services
           (LDAPS)       │
                       HTTPS
```

The Root CA private key never leaves the offline Root CA.

The Intermediate CA operates online and uses its own protected private key to issue and renew certificates for homelab services.

## Current Status

### Infrastructure

* [x] Base host configuration and hardening
* [x] Rootless Podman
* [x] NGINX
* [x] Pi-hole
* [x] Software inventory

### Identity and Network Services

* [x] LDAP container
* [x] LDAP configuration
* [ ] FreeRADIUS
* [ ] Wi-Fi authentication
* [ ] Device authentication
* [ ] Network access control

### Certificate Authority

* [x] Offline Root CA
* [x] Online Intermediate CA
* [x] Quadlet/systemd deployment
* [x] ACME provisioner
* [x] Service certificates
* [x] LDAPS certificate
* [ ] Device certificate provisioner
* [ ] Client/mTLS provisioner

### Future Network Security

The longer-term goal is to use device identity and authentication to control network access.

This may include separate network segments for trusted and untrusted devices, allowing devices that require remediation or do not meet the required security state to be isolated from the normal network.

## AI Assistance

This project has been developed with assistance from AI tools.

AI assistance is used for research, design discussion, troubleshooting, documentation and code generation. **All generated code and configuration is subject to human review, testing and approval before being considered part of the intended system.**
