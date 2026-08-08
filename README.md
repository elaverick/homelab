# Homelab

Infrastructure configuration and container definitions for my homelab.

## Services
- LDAP — OpenLDAP server running in a Podman container
- Certificate Authority — Internal certificate services
- More services will be added as required.

### Structure
    homelab/
    └── ldap
      ├── Containerfile
      ├── README.md
      └── ansible/

## Approach
GitHub — Source control  
Podman — Container runtime  
GHCR — Container image registry  
Ansible — Server and service configuration  

Container images are built locally or through CI and published to GitHub Container Registry. Servers pull the required images and Ansible applies the environment-specific configuration.