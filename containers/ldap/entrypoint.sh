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
# LDAP naming
#

LDAP_ADMIN_PASSWORD="$(cat "${LDAP_ADMIN_PASSWORD_FILE}")"

LDAP_BASE_DN="dc=${LDAP_DOMAIN//./,dc=}"
LDAP_ADMIN_DN="cn=admin,${LDAP_BASE_DN}"
LDAP_POLICY_OU_DN="ou=Policies,${LDAP_BASE_DN}"
LDAP_POLICY_DN="cn=default,${LDAP_POLICY_OU_DN}"

#
# Persistent bootstrap markers.
#
# These are only optimisation markers. The LDAP configuration itself
# remains authoritative and is checked before anything is created.
#

PPOLICY_MARKER="/etc/ldap/slapd.d/.ppolicy-configured"
MANAGED_DEVICE_MARKER="/etc/ldap/slapd.d/.managed-device-schema-configured"

#
# First-time slapd initialisation
#

if [ ! -s /etc/ldap/slapd.d/cn=config.ldif ]; then

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

    # Recreate the Debian slapd configuration using the runtime
    # debconf values.
    dpkg-reconfigure slapd

    echo "LDAP initialisation complete."

else

    echo "Existing LDAP configuration found."
    echo "Skipping LDAP initialisation."

fi

#
# Start a temporary slapd instance so that cn=config can be inspected
# and modified using SASL/EXTERNAL.
#
# We do this whenever either bootstrap component may still need work.
#

if [ -f "${PPOLICY_MARKER}" ] && [ -f "${MANAGED_DEVICE_MARKER}" ]; then

    echo "LDAP bootstrap already completed."
    echo "Skipping temporary slapd bootstrap."

else

    echo "Starting temporary slapd for LDAP bootstrap..."

    /usr/sbin/slapd \
        -h "ldap:/// ldapi:///" \
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
    # Wait for LDAPI socket.
    #

    echo "Waiting for LDAPI socket..."

    for i in {1..40}; do
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
    # The socket appearing does not necessarily mean slapd is ready
    # to accept LDAP operations. Wait for an actual SASL/EXTERNAL
    # LDAP query to succeed.
    #

    echo "Waiting for slapd to become ready..."

    LDAP_READY=false

    for i in {1..40}; do

        if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
            -b "cn=config" \
            -s base \
            -LLL \
            dn >/dev/null 2>&1; then

            LDAP_READY=true
            break

        fi

        sleep 0.5

    done

    if [ "${LDAP_READY}" = false ]; then
        echo "ERROR: slapd did not become ready for LDAPI operations."
        exit 1
    fi

    echo "slapd is ready."

    #
    # ------------------------------------------------------------------
    # managedDevice schema
    # ------------------------------------------------------------------
    #

    if [ -f "${MANAGED_DEVICE_MARKER}" ]; then

        echo "Existing managedDevice schema configuration found."
        echo "Skipping managedDevice schema configuration."

    else

        echo "Checking managedDevice schema..."

        if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
            -b "cn=schema,cn=config" \
            -LLL \
            -s one \
            "(cn=managedDevice)" \
            dn 2>/dev/null | grep -q '^dn:'; then

            echo "managedDevice schema already loaded."

        else

            echo "Loading managedDevice schema..."

            ldapadd -Q -Y EXTERNAL -H ldapi:/// \
                -f /etc/ldap/schema/managedDevice.ldif

        fi

        touch "${MANAGED_DEVICE_MARKER}"

        echo "managedDevice schema configuration complete."

    fi

    #
    # ------------------------------------------------------------------
    # ppolicy
    # ------------------------------------------------------------------
    #

    if [ -f "${PPOLICY_MARKER}" ]; then

        echo "Existing ppolicy configuration found."
        echo "Skipping ppolicy configuration."

    else

        echo "Checking for existing ppolicy overlay..."

        #
        # Versions before the persistent marker was introduced may
        # already have a fully configured ppolicy overlay. If so,
        # we don't need to bootstrap ppolicy again.
        #

        if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
            -b "olcDatabase={1}mdb,cn=config" \
            -LLL \
            "(olcOverlay=ppolicy)" \
            dn 2>/dev/null | grep -q '^dn:'; then

            echo "Existing ppolicy overlay found."
            echo "Marking ppolicy configuration as complete."

            touch "${PPOLICY_MARKER}"

        else

            echo "No existing ppolicy overlay found."
            echo "Performing ppolicy bootstrap..."

            #
            # Load the ppolicy module.
            #

            echo "Checking ppolicy module..."

            if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
                -b "cn=module{0},cn=config" \
                -LLL \
                olcModuleLoad 2>/dev/null |
                grep -q '^olcModuleLoad: ppolicy$'; then

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
            # Create the Policies OU in the normal LDAP database.
            #
            # This cannot be done with SASL/EXTERNAL because that
            # authentication controls cn=config, not the directory
            # database.
            #

            echo "Checking Policies OU..."

            if ldapsearch -x \
                -H ldap://localhost:389 \
                -D "${LDAP_ADMIN_DN}" \
                -w "${LDAP_ADMIN_PASSWORD}" \
                -b "${LDAP_BASE_DN}" \
                -LLL \
                "(&(objectClass=organizationalUnit)(ou=Policies))" \
                dn 2>/dev/null | grep -q '^dn: ou=Policies,'; then

                echo "Policies OU already exists."

            else

                echo "Creating Policies OU..."

                ldapadd -x \
                    -H ldap://localhost:389 \
                    -D "${LDAP_ADMIN_DN}" \
                    -w "${LDAP_ADMIN_PASSWORD}" <<EOF
dn: ${LDAP_POLICY_OU_DN}
objectClass: organizationalUnit
ou: Policies
EOF

            fi

            #
            # Create the default password policy.
            #

            echo "Checking default password policy..."

            if ldapsearch -x \
                -H ldap://localhost:389 \
                -D "${LDAP_ADMIN_DN}" \
                -w "${LDAP_ADMIN_PASSWORD}" \
                -b "${LDAP_POLICY_OU_DN}" \
                -LLL \
                "(cn=default)" \
                dn 2>/dev/null | grep -q "^dn: ${LDAP_POLICY_DN}$"; then

                echo "Default password policy already exists."

            else

                echo "Creating default password policy..."

                ldapadd -x \
                    -H ldap://localhost:389 \
                    -D "${LDAP_ADMIN_DN}" \
                    -w "${LDAP_ADMIN_PASSWORD}" <<EOF
dn: ${LDAP_POLICY_DN}
objectClass: top
objectClass: device
objectClass: pwdPolicy
cn: default
pwdAttribute: userPassword
pwdCheckQuality: 2
pwdMinLength: 12
pwdInHistory: 5
pwdLockout: TRUE
pwdMaxFailure: 5
pwdLockoutDuration: 900
pwdFailureCountInterval: 0
EOF

            fi

            #
            # Attach the ppolicy overlay to the MDB database.
            #

            echo "Checking ppolicy overlay..."

            if ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
                -b "olcDatabase={1}mdb,cn=config" \
                -LLL \
                "(olcOverlay=ppolicy)" \
                dn 2>/dev/null | grep -q '^dn:'; then

                echo "ppolicy overlay already configured."

            else

                echo "Creating ppolicy overlay..."

                ldapadd -Q -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcOverlay=ppolicy,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
olcPPolicyDefault: ${LDAP_POLICY_DN}
olcPPolicyHashCleartext: TRUE
EOF

                echo "ppolicy overlay created."

            fi

            #
            # Everything required for ppolicy has completed successfully.
            #

            touch "${PPOLICY_MARKER}"

            echo "ppolicy configuration complete."

        fi

    fi

    #
    # Stop temporary slapd.
    #

    trap - EXIT

    if kill -0 "${TEMP_SLAPD_PID}" 2>/dev/null; then
        echo "Stopping temporary slapd..."
        kill "${TEMP_SLAPD_PID}" 2>/dev/null || true
        wait "${TEMP_SLAPD_PID}" 2>/dev/null || true
    fi

fi

unset LDAP_ADMIN_PASSWORD

#
# Start the real slapd process.
#

echo "Starting slapd..."

exec "$@"