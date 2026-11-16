#!/usr/bin/env bash
# Builds the Marah OS USB stick from a minimal image in root's container storage: it runs
# build-iso.sh in a privileged Fedora bootc container, from the repository root. os.yml and
# `make os-iso` run it:
#   make-iso.sh [IMAGE] [OUTPUT]   default localhost/marah-os:minimal, marah-os-x86_64-<version>.iso
#   (the version from version.txt)
# BASE: the Fedora bootc image to run in (default quay.io/fedora/fedora-bootc:44). METHOD goes
# to build-iso.sh (xorriso for the hand-made ISO).
set -euo pipefail
core=${1:-localhost/marah-os:minimal}
out=${2:-marah-os-x86_64-$(cat version.txt).iso}
base=${BASE:-quay.io/fedora/fedora-bootc:44}
podman=(podman)
sudo=()
[ "$(id -u)" = 0 ] || { podman=(sudo podman); sudo=(sudo); }

mkdir -p "$(dirname "$out")"
"${podman[@]}" run --rm --privileged --network host -v /var/lib/containers:/var/lib/containers \
    -v "$PWD:/src" -w /src -e CORE="$core" -e WORK=/src/.iso-work ${METHOD:+-e METHOD="$METHOD"} \
    "$base" ./build-iso.sh "$out"
"${sudo[@]}" rm -rf .iso-work
"${sudo[@]}" chown "$(id -u):$(id -g)" "$out"
ls -l "$out"
