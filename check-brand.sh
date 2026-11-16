#!/usr/bin/env bash
# Checks that this tree makes the paths Marah Launcher looks for on Marah OS. The launcher reads
# them from the [os] section of its brand.toml (MarahHQ/marah-launcher): a change on either side
# must be made on both. It reads nothing from the network. Run it from the repository root.
set -euo pipefail

# A copy of marah-launcher's brand.toml [os] values.
release_marker=/usr/lib/marah-os/release
installer=/usr/libexec/marah-os/install
install_command=marah-os-install
update_service=marah-os-update.service

fail=0
problem() { echo "check-brand: $*" >&2; fail=1; }

# The marker: the Containerfile writes it at build time.
grep -qF "$release_marker" Containerfile || problem "Containerfile never writes $release_marker"
# The installer, on the stick.
[ -f "live/files$installer" ] || problem "live/files$installer is missing"
# The command that runs it, on the stick's PATH: a link to the installer.
link="live/files/usr/bin/$install_command"
[ -L "$link" ] || problem "$link is missing or not a link"
[ "$(realpath -m "$(dirname "$link")/$(readlink "$link")")" = "$(realpath -m "live/files$installer")" ] \
    || problem "$link doesn't point to $installer"
# The update service, which "check now" starts.
[ -f "files/usr/lib/systemd/system/$update_service" ] || problem "files/usr/lib/systemd/system/$update_service is missing"

[ "$fail" = 0 ] && echo "check-brand: the launcher's [os] paths are all made here"
exit "$fail"
