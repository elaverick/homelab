# Backups

Huginn's state that the playbook cannot rebuild is backed up to a USB disk
that is kept offline: plugged in only while a backup runs, then unplugged
and stored away. Backups are encrypted with [restic](https://restic.net/),
taken by hand about once a month, and each one is tested by restoring it
before the disk is unmounted. The `backup` role installs the
`homelab-backup` command; this page covers using it and restoring.

## What is backed up

| Export | From | How it is taken |
|---|---|---|
| `ldap-config.ldif`, `ldap-data.ldif` | LDAP: configuration, and the directory (users, groups, devices, certificate serials) | `slapcat`, consistent while slapd runs |
| `intermediate-ca-data.tar` | step-ca's volume: configuration, certificates, the encrypted Intermediate CA key and the database (issued and revoked certificates, ACME accounts) | Volume export, with step-ca stopped for a few seconds |
| `pihole-teleporter.zip` | Pi-hole: configuration, lists and groups | Pi-hole's Teleporter export |

Everything else (FreeRADIUS, NGINX, service certificates, cert-enrolment,
podwatch) is rebuilt by running `site.yml`, or holds no state.

## Taking a backup

1. Plug the backup disk into Huginn.
2. Run:

   ```sh
   sudo homelab-backup
   ```

   It mounts the disk, exports LDAP, Pi-hole and the Intermediate CA,
   stores them, keeps the latest 12 backups, checks the repository, then
   restores the new backup into throwaway containers to prove it works: the
   LDAP directory must load every entry, the Intermediate CA must start and
   pass `step ca health`, and the Pi-hole archive must be intact.
3. Wait for **"The backup disk is unmounted and safe to unplug."**, then
   unplug the disk and put it away.

If anything fails, the command says so, starts the Intermediate CA again if
it had stopped it, and still unmounts the disk. The running services are not
otherwise touched. The command stops straight away if no disk is plugged in.

Other commands, with the disk plugged in:

```sh
sudo homelab-backup test        # restore-test the latest backup again
sudo homelab-backup snapshots   # list the backups on the disk
```

## The disk and the password

* The disk is found by its filesystem label, `homelab-backup`, and mounted
  at `/srv/backup` only while the command runs. Any disk prepared with that
  label works, so two can be rotated; each holds its own backups.
* The backups are in a restic repository on the disk, encrypted with
  `backup_password` from the Ansible vault. **Without that password
  the backups cannot be read**; the vault password is in Bitwarden.
* The disk is portable: plugged into any Linux machine with restic, it can
  be restored with the password.

### Preparing a disk

The playbook and the command never format a disk. For a new disk, on Huginn:

```sh
lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL     # identify the USB disk, e.g. /dev/sdX
sudo mkfs.ext4 -L homelab-backup /dev/sdX1
```

Check the device name carefully: `mkfs` erases it. The first
`homelab-backup` on a disk creates its repository.

## Restoring

Plug the disk in and mount it, restore the backup you want (`latest`, or an
ID from `snapshots`), then restore each service as needed. Podman commands
run as the service user, which needs its runtime directory:

```sh
sudo mkdir -p /srv/backup
sudo mount LABEL=homelab-backup /srv/backup
sudo restic -r /srv/backup/restic --password-file /etc/homelab-backup/restic-password \
    restore latest --tag homelab --target /var/tmp/restore
sudo umount /srv/backup                  # the disk can be unplugged now
sudo chown -R app-runner: /var/tmp/restore
R=/var/tmp/restore/var/lib/homelab-backup/staging

alias as-app='sudo -u app-runner XDG_RUNTIME_DIR=/run/user/$(id -u app-runner)'
```

### LDAP

Replaces the directory and its configuration with the backup:

```sh
as-app systemctl --user stop ldap-server.service
as-app podman volume rm ldap-data ldap-config
as-app podman volume create ldap-data
as-app podman volume create ldap-config
as-app podman run --rm --entrypoint sh \
    -v ldap-config:/etc/ldap/slapd.d -v ldap-data:/var/lib/ldap -v "$R:/restore:ro" \
    ghcr.io/elaverick/homelab/ldap:1.3.6 -c '
        set -e
        slapadd -n 0 -F /etc/ldap/slapd.d -l /restore/ldap-config.ldif
        slapadd -n 1 -F /etc/ldap/slapd.d -l /restore/ldap-data.ldif
        chown -R openldap:openldap /etc/ldap/slapd.d /var/lib/ldap'
as-app systemctl --user start ldap-server.service
```

Use the LDAP image version from `ldap_image` in the ldap role. The server
recognises the restored configuration and does not initialise a new one.

### Intermediate CA

```sh
as-app systemctl --user stop intermediate-ca.service
as-app podman volume rm intermediate_ca_data
as-app podman volume create intermediate_ca_data
as-app podman volume import intermediate_ca_data "$R/intermediate-ca-data.tar"
as-app systemctl --user start intermediate-ca.service
```

### Pi-hole

In Pi-hole's web interface: Settings › Teleporter › Import, choosing
`pihole-teleporter.zip` from `$R`.

When finished, remove `/var/tmp/restore`.

### Rebuilding Huginn from scratch

1. Install Debian 13 and meet [deployment.md](deployment.md).
2. Run `site.yml`. The services start with empty state.
3. Restore LDAP, the Intermediate CA and Pi-hole as above.
4. Run `site.yml` again, so that everything configured from LDAP and the CA
   is consistent.

Enrolled devices keep working: their certificates and serials are in the
restored directory and CA.

## Limits

* Anything changed since the last backup is lost in a restore: for
  example, devices enrolled or certificates renewed since then. Devices
  whose renewed certificate is not in the restored directory must be
  enrolled again.
* The disk is stored beside Huginn, so a fire or theft that takes Huginn may
  take the disk too. Keeping a second disk elsewhere, rotated with the first,
  covers that.
