#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/Arbor-version.zip" >&2
  exit 2
fi

package_path=$1
sign_update=${SPARKLE_SIGN_UPDATE:-}
keychain_item=${SPARKLE_EDDSA_KEYCHAIN_ITEM:-}

if [[ -z "$sign_update" || -z "$keychain_item" ]]; then
  echo "set SPARKLE_SIGN_UPDATE and SPARKLE_EDDSA_KEYCHAIN_ITEM in the environment" >&2
  exit 2
fi
if [[ ! -x "$sign_update" || ! -f "$package_path" ]]; then
  echo "Sparkle sign_update tool or package not found" >&2
  exit 2
fi

# The EdDSA key is resolved by Sparkle from the keychain item; it is never a
# command-line secret, repository file, or log value.
exec "$sign_update" --account "$keychain_item" "$package_path"
