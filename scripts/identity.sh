#!/bin/zsh
# Creates Orbit's signing identity once: a self-signed code-signing certificate in a keychain of its own
# (~/Library/Application Support/Orbit/signing), never in your login keychain. build.sh signs Orbit.app with it.
#
# macOS ties the permissions you grant (an orbit reading iCloud Drive, say) to how an app is signed. With this
# identity they name the certificate and survive updates; ad hoc signing ties them to a single build. The keychain
# is separate because Orbit knows its password and can grant codesign the key once (the partition list), so there
# is never a "codesign wants to use" prompt. It is not in your search list, so Keychain Access doesn't show it, and
# the password file is only used to unlock it.
#
# Skipped when SIGN_ID names another identity. `make uninstall` removes it.
set -euo pipefail
source "${0:A:h}/lib.sh"

readonly name="Orbit Local Signing"

[[ -n ${SIGN_ID-} ]] && exit 0
if [[ -f $signing/password ]] && security find-certificate -c "$name" $keychain >/dev/null 2>&1; then
  exit 0
fi

print "  creating  signing certificate"
umask 077
mkdir -p $signing
rm -f $keychain
password=$(/usr/bin/openssl rand -hex 24)
print -r -- $password > $signing/password

searchlist=("${(@f)$(keychains)}")
security create-keychain -p $password $keychain
security list-keychains -d user -s $searchlist                  # keep it out of the search list
security set-keychain-settings $keychain                        # no auto-lock
security unlock-keychain -p $password $keychain

tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem -name "$name" \
  -passout pass:orbit -out $tmp/identity.p12
security import $tmp/identity.p12 -k $keychain -P orbit -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $password $keychain >/dev/null
