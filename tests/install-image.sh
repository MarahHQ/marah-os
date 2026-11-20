#!/usr/bin/env bash
# Checks that the installer installs the system stored on the USB stick and downloads nothing it
# doesn't mean to. With the stored system there, bootc's container gets the stick's storage
# drop-in and nothing is pulled. Without it, the installer stops with an error before it pulls,
# queues a Secure Boot key or erases anything. On an NVIDIA PC online with room, it still
# downloads the NVIDIA version on purpose. It also checks that the drop-in lists both stores. It
# runs the real installer with fake lsblk, findmnt, readlink, mokutil, curl, podman and blkid
# first on PATH. `make check` runs it:
#   tests/install-image.sh [INSTALLER]    default live/files/usr/libexec/marah-os/install
# It needs no root and touches no disk.
#
# The installer asks `[ -b PATH ]` whether the stick's live source is a block device. `[` is a
# bash builtin, so a fake on PATH can't answer it. Bash reads the file in BASH_ENV before it runs
# a script, and a function there wins over a builtin: that file defines `[`, answers -b from the
# case's list of fake devices and hands every other test to the builtin, as in
# tests/install-disks.sh.
#
# The installer reads /sys and /proc/meminfo itself to find an NVIDIA card and the memory free.
# The test runs in a user and mount namespace of its own (unshare -rm, no sudo): it is root there,
# with a tmpfs over /sys and a fake /proc/meminfo that the rest of the system never sees.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
installer=${1:-$here/../live/files/usr/libexec/marah-os/install}
dropin=$here/../live/files/etc/containers/storage.rootful.conf.d/90-marah-os-stick.conf
[ -f "$installer" ] || { echo "install-image: $installer is missing" >&2; exit 1; }
installer=$(cd "$(dirname "$installer")" && pwd)/$(basename "$installer")

if [ -z "${INSTALL_IMAGE_INSIDE:-}" ]; then
    command -v unshare >/dev/null || { echo "install-image: needs unshare (util-linux)" >&2; exit 1; }
    INSTALL_IMAGE_INSIDE=1 exec unshare -rm bash "$0" "$installer"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin
export FAKE=$work/case
mkdir -p "$bin"

# 16 GB free, and the disk vda with nothing written yet. A case adds the NVIDIA card. Nothing
# else of /sys is read on the install path.
mount -t tmpfs none /sys
mkdir -p /sys/bus/pci/devices /sys/block/vda
echo '0 0 0 0 0 0 0 0 0 0 0' >/sys/block/vda/stat
printf 'MemTotal: 32000000 kB\nMemAvailable: 16000000 kB\n' >"$work/meminfo"
mount --bind "$work/meminfo" /proc/meminfo
# No Wi-Fi saved: the installer would copy the PC's own into the new system.
[ -d /etc/NetworkManager ] && mount -t tmpfs none /etc/NetworkManager

# The `[` that knows the fake block devices. Only `[[ ]]` and `builtin [` inside: a bare `[`
# would call this function again.
cat >"$work/bash-env" <<'EOF'
[() {
    if [[ $# = 3 && $1 = -b && $3 = "]" ]]; then
        grep -qxF -- "$2" "$FAKE/block"
    else
        builtin [ "$@"
    fi
}
EOF

# The stick is sda, and its live filesystem is on sda1. The fakes answer both ways an installer
# finds the stick: lsblk -no PKNAME, or the walk that tests/install-disks.sh checks.
#
# Each fake notes its call in $FAKE/notes. A fake that gets arguments it doesn't know writes them
# to $FAKE/unknown and fails.
cat >"$bin/lsblk" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-dnbr -o NAME,PATH,SIZE,TYPE,RO,MODEL") echo 'vda /dev/vda 68719476736 disk 0 QEMU\x20HARDDISK' ;;
    "-no PKNAME /dev/sda1") echo sda ;;
    "-snro NAME,TYPE /dev/sda1") printf 'sda1 part\nsda disk\n' ;;
    "-nro FSTYPE /dev/vda" | "-dno TRAN /dev/vda") echo ;;
    *) echo "lsblk $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
cat >"$bin/findmnt" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-no SOURCE /run/initramfs/live") echo /dev/sda1 ;;
    "-no SOURCE /run/initramfs/isoscan") exit 1 ;;
    *) echo "findmnt $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
cat >"$bin/readlink" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-f /run/initramfs/livedev") echo /dev/sda1 ;;
    "-f /dev/vda") echo /dev/vda ;;
    *) echo "readlink $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
# Secure Boot is on when the case says so; the key is never enrolled yet.
cat >"$bin/mokutil" <<'EOF'
#!/usr/bin/env bash
echo "mokutil $*" >>"$FAKE/notes"
case "$*" in
    --sb-state) echo "SecureBoot $(cat "$FAKE/secure_boot" 2>/dev/null || echo disabled)" ;;
    "--test-key /usr/share/marah-os/secureboot.der") echo "not enrolled" ;;
    "--import /usr/share/marah-os/secureboot.der") cat >/dev/null ;;
    "--timeout -1" | --revoke-import) ;;
    *) echo "mokutil $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
# ghcr.io answers when the case is online. Offline, curl prints 000 and fails, as the real one.
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -e "$FAKE/online" ] && { echo 200; exit 0; }
echo 000
exit 6
EOF
# $FAKE/images lists the images podman has, one reference per line: the stored system, and what
# a pull adds. A pull works only online. `podman run` of an image podman doesn't have pulls it
# first, as the real one does.
cat >"$bin/podman" <<'EOF'
#!/usr/bin/env bash
has() { grep -qxF -- "$1" "$FAKE/images"; }
pull() {
    echo "podman pull $1" >>"$FAKE/notes"
    [ -e "$FAKE/online" ] || return 125
    echo "$1" >>"$FAKE/images"
}
case "$1 $2" in
    "image inspect" | "image exists")
        has "${!#}" || exit 125
        [ "$2" = inspect ] && echo 3000000000
        exit 0
        ;;
    "pull -q") pull "$3" ;;
    "run --rm")
        echo "podman $*" >>"$FAKE/notes"
        args=("$@")
        for i in "${!args[@]}"; do
            [ "${args[$i]}" = bootc ] && image=${args[$((i - 1))]} && break
        done
        has "${image:-}" || pull "${image:-}" || exit 125
        echo "Installing bootloader"
        ;;
    *) echo "podman $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
cat >"$bin/blkid" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$bin"/*

# The installer reads its registry from /usr/lib/marah-os/image, which only Marah OS has: here
# it is empty, and the fakes see the same empty name.
repo=$(cat /usr/lib/marah-os/image 2>/dev/null) || :
# fresh STORED NVIDIA ONLINE [SECURE_BOOT]: a new case. STORED: the stick's system is there
# (stored) or not (missing). NVIDIA: the PC has an NVIDIA card (nvidia) or not (none). ONLINE:
# ghcr.io answers (online) or not (offline). SECURE_BOOT: on, or off when not given.
fresh() {
    rm -rf "$FAKE" /sys/bus/pci/devices/*
    mkdir -p "$FAKE"
    : >"$FAKE/notes"
    : >"$FAKE/images"
    echo /dev/sda1 >"$FAKE/block"
    [ "$1" = stored ] && echo "$repo:minimal" >"$FAKE/images"
    if [ "$2" = nvidia ]; then
        mkdir -p /sys/bus/pci/devices/0000:01:00.0
        echo 0x10de >/sys/bus/pci/devices/0000:01:00.0/vendor
        echo 0x030000 >/sys/bus/pci/devices/0000:01:00.0/class
    fi
    [ "$3" = online ] && : >"$FAKE/online"
    [ "${4:-off}" = on ] && echo enabled >"$FAKE/secure_boot"
    return 0
}

# The `[` in bash-env must take over, or an installer that checks `[ -b ]` refuses vda.
fresh stored none offline
BASH_ENV="$work/bash-env" bash -c '[ -b /dev/sda1 ]' || {
    echo "install-image: this bash doesn't take the [ from BASH_ENV, so nothing was tested" >&2
    exit 1
}

failed=0
why=()
# noted TEXT / not_noted TEXT: a fake's call has TEXT in it, or none has.
noted() { grep -qF -- "$1" "$FAKE/notes" || why+=("not called: $1"); }
not_noted() { ! grep -F -- "$1" "$FAKE/notes" >/dev/null || why+=("called: $(grep -F -- "$1" "$FAKE/notes" | head -1)"); }
# install EXIT LAST: runs the installer on /dev/vda and checks its exit code and its last line.
install() {
    local want_code=$1 want_last=$2 code=0 last
    why=()
    PATH="$bin:$PATH" BASH_ENV="$work/bash-env" bash "$installer" /dev/vda </dev/null >"$work/out" 2>"$work/err" || code=$?
    [ "$code" = "$want_code" ] || why+=("exit $code, expected $want_code")
    last=$(tail -1 "$work/out")
    [ "$last" = "$want_last" ] || why+=("last line: $last" "expected:  $want_last")
}
# result NAME: prints ok or FAIL with the reasons the checks gave.
result() {
    [ ! -s "$FAKE/unknown" ] || why+=("a fake got arguments it doesn't know:" "$(cat "$FAKE/unknown")")
    if [ "${#why[@]}" = 0 ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '%s\n' "${why[@]}" "output:" "$(cat "$work/out")" "calls:" "$(cat "$FAKE/notes")" | sed 's/^/     /'
        failed=1
    fi
}

mount_dropin="-v /etc/containers/storage.rootful.conf.d:/etc/containers/storage.rootful.conf.d:ro"
missing="error The system stored on this USB stick wasn't found."

fresh stored none offline
install 0 "done minimal"
noted "$mount_dropin"
noted "$repo:minimal bootc install to-disk"
not_noted "podman pull"
result "the stored system: bootc's container gets the stick's drop-in, and nothing is pulled"

fresh missing none online
install 1 "$missing"
not_noted "podman run"
not_noted "podman pull"
result "no stored system: the installer stops, and neither pulls nor erases"

fresh missing nvidia online on
install 1 "$missing"
not_noted "podman pull"
not_noted "mokutil --import"
not_noted "podman run"
result "no stored system on an NVIDIA PC online: it stops before the download and the Secure Boot key"

fresh stored nvidia online
install 0 "done minimal-nvidia"
noted "podman pull $repo:minimal-nvidia"
noted "$mount_dropin"
noted "$repo:minimal-nvidia bootc install to-disk"
result "an NVIDIA PC online with room still downloads the NVIDIA version"

fresh stored nvidia offline
install 0 "done minimal nvidia-later"
not_noted "podman pull"
noted "$repo:minimal bootc install to-disk"
result "an NVIDIA PC offline installs the stored system"

# The drop-in keeps Fedora's store, since a later drop-in's list replaces an earlier one's.
why=()
fresh stored none offline
: >"$work/out"
if [ ! -f "$dropin" ]; then
    why+=("$dropin is missing")
else
    stores=$(sed -n 's/^additionalimagestores *= *//p' "$dropin")
    [ "$stores" = '["/usr/lib/containers/storage", "/run/rootfsbase/var/lib/containers/storage"]' ] ||
        why+=("its additionalimagestores: ${stores:-none}" "expected Fedora's store and the stick's")
fi
result "the stick's drop-in lists Fedora's store and the stick's"

[ "$failed" = 0 ] && echo "install-image: the installer installs the system stored on the stick, and downloads only NVIDIA's version"
exit "$failed"
