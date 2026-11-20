#!/usr/bin/env bash
# Checks that the installer never offers the USB stick Marah OS started from. It runs the real
# installer with fake findmnt, lsblk, losetup and readlink first on PATH and compares what it
# prints. The fakes follow the sticks of the QEMU test in the pull request, with made-up values.
# `make check` runs it:
#   tests/install-disks.sh [INSTALLER]    default live/files/usr/libexec/marah-os/install
# It needs no root and touches no disk.
#
# The installer asks `[ -b PATH ]` whether a path is a block device. `[` is a bash builtin, so a
# fake on PATH can't answer it. Bash reads the file in BASH_ENV before it runs a script, and a
# function there wins over a builtin: that file defines `[`, answers -b from the case's list of
# fake devices and hands every other test to the builtin. The installer itself is unchanged.
# pkexec clears the environment, so this can't reach a real install.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
installer=${1:-$here/../live/files/usr/libexec/marah-os/install}
[ -f "$installer" ] || { echo "install-disks: $installer is missing" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin
export FAKE=$work/case
mkdir -p "$bin"

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

# A fake that gets arguments it doesn't know writes them to $FAKE/unknown and fails. The
# installer drops the fakes' stderr, so the test checks that file after each run.
cat >"$bin/findmnt" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-no SOURCE /run/initramfs/live") cat "$FAKE/live" 2>/dev/null ;;
    "-no SOURCE /run/initramfs/isoscan") cat "$FAKE/isoscan" 2>/dev/null ;;
    *) echo "findmnt $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
# Without the link, readlink -f still prints the path when /run/initramfs exists.
cat >"$bin/readlink" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-f /run/initramfs/livedev") cat "$FAKE/livedev" 2>/dev/null || echo /run/initramfs/livedev ;;
    *) echo "readlink $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
# lsblk -s prints the device, then each layer under it down to the disks. A device's parent
# (PKNAME, which the old installer read) is the second row: none for a disk or a loop.
cat >"$bin/lsblk" <<'EOF'
#!/usr/bin/env bash
tree() { cat "$FAKE/tree/${1//\//_}" 2>/dev/null || { echo "lsblk: no tree for $1" >>"$FAKE/unknown"; exit 99; }; }
case "$*" in
    "-snro NAME,TYPE "*) tree "$3" ;;
    "-no PKNAME "*) tree "$3" | sed -n '2{s/ .*//;p;q}' | grep . || echo ;;
    "-dnbr -o NAME,PATH,SIZE,TYPE,RO,MODEL") cat "$FAKE/list" ;;
    "-nro FSTYPE /dev/sda") printf '\niso9660\nvfat\n' ;;
    "-nro FSTYPE /dev/sdb" | "-nro FSTYPE /dev/vda") echo ;;
    "-dno TRAN /dev/sd"?) echo usb ;;
    "-dno TRAN /dev/vda") echo ;;
    *) echo "lsblk $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
cat >"$bin/losetup" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-nO BACK-MAJ:MIN /dev/loop"*) cat "$FAKE/back/${3#/dev/}" ;;
    *) echo "losetup $*" >>"$FAKE/unknown"; exit 99 ;;
esac
EOF
# The install path checks for root before it checks the disk.
cat >"$bin/id" <<'EOF'
#!/usr/bin/env bash
[[ $* = -u ]] || { echo "id $*" >>"$FAKE/unknown"; exit 99; }
echo 0
EOF
# What runs after the disk check. If the installer gets that far it reaches these, never the
# real ones: each one notes its call and fails.
for tool in podman mokutil curl blkid mount systemctl; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE/reached"\nexit 1\n' "$tool" >"$bin/$tool"
done
chmod +x "$bin"/*

# The disks of the QEMU test, as lsblk would list them: the stick (sda, 64 GB on USB), the disk to install on (vda),
# a small read-only disk, the squashfs loop, a CD drive and zram. Raw output, so the spaces in a
# model are \x20 and an empty model leaves a trailing space.
list='loop0 /dev/loop0 1610612736 loop 1
sda /dev/sda 68719476736 disk 0 QEMU\x20HARDDISK
sr0 /dev/sr0 1073741824 rom 0 QEMU\x20DVD-ROM
vda /dev/vda 68719476736 disk 0
vdb /dev/vdb 1048576 disk 1
zram0 /dev/zram0 6442450944 disk 0 '
vda='disk /dev/vda 68719476736 0 0 Disk'
error="The USB stick Marah OS started from wasn't found, so no disk is offered."

# A new case: no source, no block device, the list above.
fresh() {
    rm -rf "$FAKE"
    mkdir -p "$FAKE/tree" "$FAKE/back"
    : >"$FAKE/block"
    printf '%s\n' "$list" >"$FAKE/list"
}
# source_is live|livedev|isoscan PATH: what findmnt (or readlink -f, for livedev) prints for it.
source_is() { echo "$2" >"$FAKE/$1"; }
# tree PATH ROW…: PATH is a fake block device, and lsblk -snro NAME,TYPE prints these rows for it.
tree() {
    local dev=$1
    shift
    echo "$dev" >>"$FAKE/block"
    printf '%s\n' "$@" >"$FAKE/tree/${dev//\//_}"
}
# back LOOP TEXT: what losetup -nO BACK-MAJ:MIN prints for the loop. Root gets "8:1" padded with
# spaces; anyone else gets an empty line.
back() { printf '%s\n' "$2" >"$FAKE/back/$1"; }

failed=0
# expect NAME EXIT STDOUT STDERR_LINE ARGS…: runs the installer with ARGS and checks its exit
# code, its whole stdout and, unless STDERR_LINE is empty, that stderr has that line. The installer reads
# /usr/lib/marah-os/image first, which only Marah OS has, so stderr is never compared whole.
expect() {
    local name=$1 want_code=$2 want_out=$3 want_err=$4 code=0 out
    shift 4
    rm -f "$FAKE/unknown" "$FAKE/reached"
    out=$(env -u MARAH_OS_MIN_DISK PATH="$bin:$PATH" BASH_ENV="$work/bash-env" \
        bash "$installer" "$@" 2>"$work/err") || code=$?
    local why=()
    [ "$code" = "$want_code" ] || why+=("exit $code, expected $want_code")
    [ "$out" = "$want_out" ] || why+=("stdout:" "$out" "expected:" "$want_out")
    [ -z "$want_err" ] || grep -qxF -- "$want_err" "$work/err" || why+=("stderr has no line: $want_err")
    [ ! -s "$FAKE/unknown" ] || why+=("a fake got arguments it doesn't know:" "$(cat "$FAKE/unknown")")
    [ ! -s "$FAKE/reached" ] || why+=("the install went past the disk check:" "$(cat "$FAKE/reached")")
    if [ "${#why[@]}" = 0 ]; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        printf '%s\n' "${why[@]}" | sed 's/^/     /'
        failed=1
    fi
}

# The `[` in bash-env must take over, or every case below means nothing.
fresh
echo /dev/install-disks-probe >"$FAKE/block"
FAKE=$FAKE BASH_ENV="$work/bash-env" bash -c '[ -b /dev/install-disks-probe ]' || {
    echo "install-disks: this bash doesn't take the [ from BASH_ENV, so nothing was tested" >&2
    exit 1
}

# Stick A: the ISO written with dd. The live filesystem is on a partition of the stick.
fresh
source_is live /dev/sda1
source_is livedev /dev/sda1
tree /dev/sda1 'sda1 part' 'sda disk'
expect "A: live on sda1, a partition of the stick" 0 "$vda" "" --disks

# Stick B: the ISO on the whole stick, with no partition table. The stick has no parent.
fresh
source_is live /dev/sda
source_is livedev /dev/sda
tree /dev/sda 'sda disk'
expect "B: live on sda, the whole stick" 0 "$vda" "" --disks
expect "B: install on the stick is refused" 1 "error Marah OS can't be installed on /dev/sda." "" /dev/sda

# Stick C: an ISO file on the stick's ext4 partition, booted with iso-scan/filename=. The live
# filesystem is on a loop over that file; the partition holding it is mounted at isoscan.
stick_c() {
    fresh
    source_is live /dev/loop0
    source_is livedev /dev/loop0
    tree /dev/loop0 'loop0 loop'
    tree /dev/sda1 'sda1 part' 'sda disk'
    tree /dev/block/8:1 'sda1 part' 'sda disk'
}
stick_c
source_is isoscan /dev/sda1
back loop0 '      8:1'
expect "C: live on loop0 over sda1, as root" 0 "$vda" "" --disks
expect "C: install on the stick is refused, as root" 1 "error Marah OS can't be installed on /dev/sda." "" /dev/sda
back loop0 ''
expect "C: live on loop0 over sda1, not root (isoscan finds the stick)" 0 "$vda" "" --disks

# Stick C with isoscan unmounted: as root losetup still leads to the stick; anyone else can't
# find it, so nothing is offered.
stick_c
back loop0 '      8:1'
expect "C without isoscan, as root" 0 "$vda" "" --disks
back loop0 ''
expect "C without isoscan, not root: nothing offered" 1 "" "$error" --disks

# The live filesystem on a device mapper device over a partition of the stick.
fresh
source_is live /dev/mapper/live-rw
tree /dev/mapper/live-rw 'live-rw dm' 'sda1 part' 'sda disk'
expect "dm over sda1" 0 "$vda" "" --disks

# The live filesystem on md or dm over two disks: both are hidden. No QEMU run had this shape.
list_two="$list
sdb /dev/sdb 68719476736 disk 0 QEMU\x20HARDDISK"
fresh
printf '%s\n' "$list_two" >"$FAKE/list"
source_is live /dev/md127
tree /dev/md127 'md127 raid1' 'sda1 part' 'sda disk' 'sdb1 part' 'sdb disk'
expect "md over sda1 and sdb1" 0 "$vda" "" --disks
fresh
printf '%s\n' "$list_two" >"$FAKE/list"
source_is live /dev/mapper/live-rw
tree /dev/mapper/live-rw 'live-rw dm' 'sda disk' 'sdb disk'
expect "dm over sda and sdb" 0 "$vda" "" --disks

# The ISO as a CD, with no stick: the CD counts as found.
fresh
grep -v '^sda ' <<<"$list" >"$FAKE/list"
source_is live /dev/sr0
source_is livedev /dev/sr0
tree /dev/sr0 'sr0 rom'
expect "CD: live on sr0" 0 "$vda" "" --disks

# No source (a network boot, or the stick unmounted): nothing is offered and no disk installs.
fresh
expect "no source: nothing offered" 1 "" "$error" --disks
expect "no source: install on vda is refused" 1 "error Marah OS can't be installed on /dev/vda." "" /dev/vda

[ "$failed" = 0 ] && echo "install-disks: the installer never offers the stick it started from"
exit "$failed"
