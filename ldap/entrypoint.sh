#!/bin/bash

set -euo pipefail

LDAP_DOMAIN="${LDAP_DOMAIN:?LDAP_DOMAIN must be set}"
LDAP_ORGANISATION="${LDAP_ORGANISATION:?LDAP_ORGANISATION must be set}"
LDAP_ADMIN_PASSWORD_FILE="${LDAP_ADMIN_PASSWORD_FILE:-/run/secrets/ldap_admin_password}"

if [ ! -f "${LDAP_ADMIN_PASSWORD_FILE}" ]; then
    echo "ERROR: LDAP admin password secret not found:"
    echo "       ${LDAP_ADMIN_PASSWORD_FILE}"
    exit 1
fi

if [ ! -s "${LDAP_ADMIN_PASSWORD_FILE}" ]; then
    echo "ERROR: LDAP admin password secret is empty:"
    echo "       ${LDAP_ADMIN_PASSWORD_FILE}"
    exit 1
fi


#
# First-time slapd initialisation
#

if [ ! -s /etc/ldap/slapd.d/cn=config.ldif ]; then

    echo "Initialising LDAP..."
    echo "Domain: ${LDAP_DOMAIN}"
    echo "Organisation: ${LDAP_ORGANISATION}"

    LDAP_ADMIN_PASSWORD="$(cat "${LDAP_ADMIN_PASSWORD_FILE}")"

    debconf-set-selections <<EOF
slapd slapd/no_configuration boolean false
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string ${LDAP_ORGANISATION}
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/move_old_database boolean true
slapd slapd/purge_database boolean true
EOF

    # Recreate the Debian slapd configuration using the runtime
    # debconf values.
    dpkg-reconfigure slapd

    unset LDAP_ADMIN_PASSWORD

    echo "LDAP initialisation complete."

else

    echo "Existing LDAP configuration found."
    echo "Skipping LDAP initialisation."

fi


#
# Configure ppolicy overlay
#
# cn=config can only be modified using the local LDAPI socket with
# SASL/EXTERNAL authentication.
#

echo "Checking ppolicy configuration..."

PPOLICY_CONFIGURED=false

if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
    -b "cn=config" \
    -LLL \
    "(olcOverlay=ppolicy)" \
    dn 2>/dev/null | grep -q '^dn:'; then

    PPOLICY_CONFIGURED=true
fi

if [ "${PPOLICY_CONFIGURED}" = false ]; then

    echo "ppolicy overlay is not configured."
    echo "Starting temporary slapd for configuration..."

    #
    # Run slapd in the foreground so $! is its actual PID.
    #
    /usr/sbin/slapd \
        -h "ldapi:///" \
        -F /etc/ldap/slapd.d \
        -u openldap \
        -g openldap \
        -d 0 &

    TEMP_SLAPD_PID=$!

    cleanup() {
        if kill -0 "${TEMP_SLAPD_PID}" 2>/dev/null; then
            echo "Stopping temporary slapd..."
            kill "${TEMP_SLAPD_PID}" 2>/dev/null || true
            wait "${TEMP_SLAPD_PID}" 2>/dev/null || true
        fi
    }

    trap cleanup EXIT


    #
    # Wait for the LDAPI socket.
    #
    echo "Waiting for LDAPI socket..."

    for i in {1..20}; do
        if [ -S /run/slapd/ldapi ]; then
            break
        fi

        sleep 0.5
    done

    if [ ! -S /run/slapd/ldapi ]; then
        echo "ERROR: slapd LDAPI socket was not created."
        exit 1
    fi


    #
    # Load the ppolicy module.
    #
    echo "Checking ppolicy module..."

    if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
        -b "cn=config" \
        -LLL \
        "(olcModuleLoad=*ppolicy*)" \
        dn 2>/dev/null | grep -q '^dn:'; then

        echo "ppolicy module already loaded."

    else

        echo "Loading ppolicy module..."

        ldapmodify -Q -Y EXTERNAL -H ldapi:/// <<'EOF'
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy
EOF

    fi


    #
    # Load the ppolicy schema.
    #
    echo "Checking ppolicy schema..."

    if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
        -b "cn=schema,cn=config" \
        -LLL \
        -s one \
        "(cn=ppolicy)" \
        dn 2>/dev/null | grep -q '^dn:'; then

        echo "ppolicy schema already loaded."

    else

        echo "Loading ppolicy schema..."

        ldapadd -Q -Y EXTERNAL -H ldapi:/// \
            -f /etc/ldap/schema/ppolicy.ldif

    fi


    #
    # Attach the ppolicy overlay to the MDB database.
    #
    echo "Creating ppolicy overlay..."

    if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
        -b "olcDatabase={1}mdb,cn=config" \
        -LLL \
        "(olcOverlay=ppolicy)" \
        dn 2>/dev/null | grep -q '^dn:'; then

        echo "ppolicy overlay already exists."

    else

        ldapadd -Q -Y EXTERNAL -H ldapi:/// <<'EOF'
dn: olcOverlay=ppolicy,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
EOF

        echo "ppolicy overlay created."

    fi

    echo "ppolicy configuration complete."

else

    echo "Existing ppolicy overlay found."
    echo "Skipping ppolicy configuration."

fi


#
# Stop temporary slapd if we started one.
#

trap - EXIT

if [ -n "${TEMP_SLAPD_PID:-}" ]; then
    echo "Stopping temporary slapd..."
    kill "${TEMP_SLAPD_PID}" 2>/dev/null || true
    wait "${TEMP_SLAPD_PID}" 2>/dev/null || true
fi


#
# Start the real slapd process.
#

echo "Starting slapd..."

exec "$@"