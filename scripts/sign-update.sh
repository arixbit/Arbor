#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/Arbor-version.zip" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
package_path=$1
if [[ ! -f "$package_path" ]]; then
  echo "update package not found: $package_path" >&2
  exit 2
fi
"$repo_root/scripts/prepare-sparkle.sh"
package_dir=$(cd -- "$(dirname -- "$package_path")" && pwd -P)
package_name=$(basename -- "$package_path")
package_path="$package_dir/$package_name"
version=$(unzip -p "$package_path" Arbor.app/Contents/Info.plist | python3 -c \
  'import plistlib, sys; print(plistlib.loads(sys.stdin.buffer.read())["CFBundleShortVersionString"])')

# Only the ZIP belongs in the generator's input; the release directory also
# contains a DMG for manual installs of the same version.
staging_dir=$(mktemp -d "$package_dir/sparkle.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
ln -- "$package_path" "$staging_dir/$package_name"
generator=(
  "$repo_root/build/Sparkle/bin/generate_appcast"
  --download-url-prefix "https://github.com/arixbit/Arbor/releases/download/v$version/"
  --link "https://github.com/arixbit/Arbor/releases/tag/v$version"
  --maximum-deltas 0
  -o "$staging_dir/appcast.xml"
)

# CI sends its secret over stdin; local releases use the login Keychain.
# Neither path puts the private key in command arguments or build artifacts.
if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" | "${generator[@]}" --ed-key-file - "$staging_dir"
else
  "${generator[@]}" --account "${SPARKLE_EDDSA_KEYCHAIN_ITEM:-com.arbor.app}" "$staging_dir"
fi

# generate_appcast only warns when the key does not match the app. Do not
# publish the unsigned feed it produces in that case.
python3 - "$staging_dir/appcast.xml" <<'PY'
import base64
import sys
import xml.etree.ElementTree as ET

namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(sys.argv[1]).findall("./channel/item")
if len(items) != 1:
    sys.exit("Expected exactly one signed update in appcast.xml")
enclosure = items[0].find("enclosure")
signature = enclosure.get(namespace + "edSignature", "") if enclosure is not None else ""
if len(base64.b64decode(signature, validate=True)) != 64:
    sys.exit("Update signature missing. Use the private key matching ARBOR_SPARKLE_PUBLIC_KEY; see RELEASE.md.")
PY
mv -- "$staging_dir/appcast.xml" "$package_dir/appcast.xml"
