#!/usr/bin/env bash
# Checks the installer's answer to Marah Launcher's cancel: the line "cancel" on its standard
# input. Before the erase it stops and prints "error Cancelled"; once the erase starts it says it
# can't stop and goes on; the end of its input is no cancel. It runs the real installer with fake
# lsblk, findmnt, readlink, mokutil, curl, podman and blkid first on PATH. `make check` runs it:
#   tests/install-cancel.sh [INSTALLER]    default live/files/usr/libexec/marah-os/install
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
[ -f "$installer" ] || { echo "install-cancel: $installer is missing" >&2; exit 1; }
installer=$(cd "$(dirname "$installer")" && pwd)/$(basename "$installer")

if [ -z "${INSTALL_CANCEL_INSIDE:-}" ]; then
    command -v unshare >/dev/null || { echo "install-cancel: needs unshare (util-linux)" >&2; exit 1; }
    INSTALL_CANCEL_INSIDE=1 exec unshare -rm bash "$0" "$installer"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin
export FAKE=$work/case
mkdir -p "$bin"

# A PC with an NVIDIA card (vendor 0x10de, a display class), 16 GB free, and the disk vda with
# nothing written yet. Nothing else of /sys is read on the install path.
mount -t tmpfs none /sys
mkdir -p /sys/bus/pci/devices/0000:01:00.0 /sys/block/vda
echo 0x10de >/sys/bus/pci/devices/0000:01:00.0/vendor
echo 0x030000 >/sys/bus/pci/devices/0000:01:00.0/class
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
# finds the stick: lsblk -no PKNAME, or the walk that tests/install-disks.sh checks (findmnt,
# readlink, `[ -b ]` and lsblk -snro NAME,TYPE).
#
# Each fake notes its call in $FAKE/notes. A fake that gets arguments it doesn't know writes them
# to $FAKE/unknown and fails. `request POINT` sends the cancel when the case says so, at POINT.
cat >"$bin/request" <<'EOF'
#!/usr/bin/env bash
[ "$(cat "$FAKE/cancel_at" 2>/dev/null)" = "$1" ] && echo cancel >"$FAKE/input"
exit 0
EOF
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
# A fake too: the real one would follow this PC's own /run/initramfs/livedev, if it has one.
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
    "--import /usr/share/marah-os/secureboot.der") cat >/dev/null; request import ;;
    "--timeout -1" | --revoke-import) ;;
    *) echo "mokutil $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
echo 200
EOF
# The download takes 3 seconds, unless it's stopped. The erase takes 3 seconds: the installer's
# meter looks every 2 seconds.
cat >"$bin/podman" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "pull -q")
        echo "podman pull" >>"$FAKE/notes"
        trap 'echo "podman pull stopped" >>"$FAKE/notes"; exit 143' TERM
        request pull
        sleep 3 &
        wait $!
        ;;
    "image inspect") echo 3000000000 ;;
    "run --rm")
        echo "podman run" >>"$FAKE/notes"
        request erase
        sleep 3
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

# A new case: Secure Boot `off` or `on`, and the point the player cancels at, if any.
fresh() {
    rm -rf "$FAKE"
    mkdir -p "$FAKE"
    : >"$FAKE/notes"
    echo /dev/sda1 >"$FAKE/block"
    [ "$1" = on ] && echo enabled >"$FAKE/secure_boot"
    [ -n "${2:-}" ] && echo "$2" >"$FAKE/cancel_at"
    mkfifo "$FAKE/input"
}

# The `[` in bash-env must take over, or an installer that checks `[ -b ]` refuses vda.
fresh off
BASH_ENV="$work/bash-env" bash -c '[ -b /dev/sda1 ]' || {
    echo "install-cancel: this bash doesn't take the [ from BASH_ENV, so nothing was tested" >&2
    exit 1
}

failed=0
# expect NAME INPUT EXIT LAST [LINE] [NOTE] [NOT_NOTE]: runs the installer on /dev/vda with INPUT
# on its standard input (null, or pipe: the case's pipe, held open and silent unless a fake sends
# the cancel). Checks its exit code, its last line of output and, when given, that the output has
# a line matching LINE, that the notes have NOTE and not NOT_NOTE. Its output must end within 60
# seconds of the start: nothing it started may hold it after the end.
expect() {
    local name=$1 input=$2 want_code=$3 want_last=$4 line=${5:-} note=${6:-} not_note=${7:-} out
    local from=/dev/null
    [ "$input" = pipe ] && from=$FAKE/input
    exec 4<>"$FAKE/input"
    set +e
    PATH="$bin:$PATH" BASH_ENV="$work/bash-env" bash "$installer" /dev/vda <"$from" 2>"$work/err" | timeout 60 cat >"$work/out"
    local code=${PIPESTATUS[0]} held=${PIPESTATUS[1]}
    set -e
    exec 4>&-
    local why=()
    [ "$held" = 0 ] || why+=("its output stayed open for 60 seconds")
    [ "$code" = "$want_code" ] || why+=("exit $code, expected $want_code")
    out=$(tail -1 "$work/out")
    [ "$out" = "$want_last" ] || why+=("last line: $out" "expected:  $want_last")
    [ -z "$line" ] || grep -qE -- "$line" "$work/out" || why+=("no line matches: $line")
    [ -z "$note" ] || grep -qxF -- "$note" "$FAKE/notes" || why+=("not called: $note")
    [ -z "$not_note" ] || ! grep -qxF -- "$not_note" "$FAKE/notes" || why+=("called: $not_note")
    [ ! -s "$FAKE/unknown" ] || why+=("a fake got arguments it doesn't know:" "$(cat "$FAKE/unknown")")
    if [ "${#why[@]}" = 0 ]; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        printf '%s\n' "${why[@]}" "output:" "$(cat "$work/out")" | sed 's/^/     /'
        failed=1
    fi
}

done_line="done minimal-nvidia"
fresh off
expect "an older launcher's empty input is no cancel" null 0 "$done_line" "" "podman run"
fresh off
expect "a silent input is no cancel" pipe 0 "$done_line" "" "podman run"
fresh off pull
expect "a cancel during NVIDIA's download stops it" pipe 1 "error Cancelled" "" "podman pull stopped" "podman run"
fresh on import
expect "a cancel after the Secure Boot key was queued takes it back" pipe 1 "error Cancelled" "" \
    "mokutil --revoke-import" "podman run"
fresh off erase
expect "a cancel during the erase doesn't stop it" pipe 0 "$done_line" \
    "^progress [0-9]+ Can't stop now: the disk is being written$" "podman run"

[ "$failed" = 0 ] && echo "install-cancel: the installer stops only before it erases the disk"
exit "$failed"
