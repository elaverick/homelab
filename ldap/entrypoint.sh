#!/bin/bash

set -e

LDAP_DOMAIN="${LDAP_DOMAIN:?LDAP_DOMAIN must be set}"
LDAP_ORGANISATION="${LDAP_ORGANISATION:?LDAP_ORGANISATION must be set}"
LDAP_ADMIN_PASSWORD_FILE="${LDAP_ADMIN_PASSWORD_FILE:-/run/secrets/ldap_admin_password}"

if [ ! -f "${LDAP_ADMIN_PASSWORD_FILE}" ]; then
    echo "ERROR: LDAP admin password secret not found:"
    echo "       ${LDAP_ADMIN_PASSWORD_FILE}"
    exit 1
fi

LDAP_ADMIN_PASSWORD="$(cat "${LDAP_ADMIN_PASSWORD_FILE}")"

# Only perform the initial slapd configuration when the
# persistent slapd configuration does not already exist.
if [ ! -f /etc/ldap/slapd.d/cn=config.ldif ]; then

    echo "Initialising LDAP..."
    echo "Domain: ${LDAP_DOMAIN}"
    echo "Organisation: ${LDAP_ORGANISATION}"

    debconf-set-selections <<EOF
slapd slapd/no_configuration boolean false
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string ${LDAP_ORGANISATION}
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/move_old_database boolean true
slapd slapd/purge_database boolean true
EOF

    dpkg-reconfigure slapd

    echo "LDAP initialisation complete."

else

    echo "Existing LDAP configuration found."
    echo "Skipping initialisation."

fi

# Remove the password from the shell environment as soon as
# initialisation has completed.
unset LDAP_ADMIN_PASSWORD

echo "Starting slapd..."

exec "$@"
