#!/usr/bin/env bash
# Downloads the Marah Launcher rpm that the image installs, from a Marah Launcher release (the latest by default),
# checks it against its .sha256, and leaves it alone in marah-launcher-rpm/ for Containerfile:
#   fetch-marah-launcher.sh [TAG]
# Needs gh, logged in or with GH_TOKEN set. GH_REPO picks the repository (default:
# MarahHQ/marah-launcher). Run it from the repository root.
set -euo pipefail
export GH_REPO=${GH_REPO:-MarahHQ/marah-launcher}
tag=${1:-}
dir=marah-launcher-rpm
rm -rf "$dir"
mkdir -p "$dir"
# shellcheck disable=SC2086 # no tag means the latest release
gh release download $tag --pattern 'marah-launcher-*.x86_64.rpm' --pattern 'marah-launcher-*.x86_64.rpm.sha256' --dir "$dir"
rpms=("$dir"/marah-launcher-*.x86_64.rpm)
if [ "${#rpms[@]}" -ne 1 ] || [ ! -f "${rpms[0]}" ]; then
    echo "error: expected one marah-launcher-*.x86_64.rpm in the release, found: ${rpms[*]}" >&2
    exit 1
fi
(cd "$dir" && sha256sum -c "$(basename "${rpms[0]}").sha256")
rm "$dir"/*.sha256
ls -l "$dir"
