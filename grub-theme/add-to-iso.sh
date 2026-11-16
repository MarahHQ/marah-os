#!/usr/bin/env bash
# Puts the boot menu theme on a finished USB stick image: grub-theme/add-to-iso.sh <ISO>.
# build-iso.sh runs it after image-builder, whose menu has no theme setting. The UEFI menu file,
# EFI/BOOT/grub.cfg, is in three places, all the same: the ISO's files, /images/efiboot.img, and
# the EFI partition appended to the stick (a copy of efiboot.img), which is the one the PC reads.
# The theme lines (grub-theme/theme.cfg) go after its `search ... --set=root` line, and the
# theme's files to /themes/marah-os on the ISO, where that search points. The BIOS menu
# (/boot/grub2) stays as it is. Needs xorriso and mtools.
set -euo pipefail
iso="${1:?usage: $0 <ISO>}"
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT/grub.cfg "$work/grub.cfg" \
    -extract /images/efiboot.img "$work/efiboot.img" 2>/dev/null
grep -q "^search --no-floppy --set=root " "$work/grub.cfg" ||
    { echo "error: $iso: EFI/BOOT/grub.cfg has no search line to put the theme after" >&2; exit 1; }
awk -v theme="$here/theme.cfg" '
    { print }
    /^search --no-floppy --set=root / && !done { print ""; while ((getline line < theme) > 0) print line; done = 1 }
' "$work/grub.cfg" > "$work/themed.cfg"

# Only the theme lines are new.
added=$(diff "$work/grub.cfg" "$work/themed.cfg" | grep -c '^>' || true)
want=$(($(wc -l < "$here/theme.cfg") + 1))
[ "$added" -eq "$want" ] && ! diff "$work/grub.cfg" "$work/themed.cfg" | grep -q '^<' ||
    { echo "error: the menu changed in more than the theme lines" >&2; exit 1; }

mcopy -o -i "$work/efiboot.img" "$work/themed.cfg" ::/EFI/BOOT/grub.cfg

# Replay keeps the stick's boot setup; the EFI partition is given again, so the edited copy is
# the one appended, not the old one.
xorriso -indev "$iso" -outdev "$work/themed.iso" -boot_image any replay \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$work/efiboot.img" \
    -map "$work/themed.cfg" /EFI/BOOT/grub.cfg -map "$work/efiboot.img" /images/efiboot.img \
    -map "$here/marah-os" /themes/marah-os 2>&1 | grep -E "^(xorriso : (FAILURE|SORRY|WARNING)|libisofs: (FAILURE|SORRY))" || true
[ -s "$work/themed.iso" ] || { echo "error: xorriso made no ISO" >&2; exit 1; }

# The EFI partition the PC reads now holds the themed menu.
start=$(xorriso -indev "$work/themed.iso" -report_system_area plain 2>/dev/null |
    awk '$1 == "GPT" && $2 == "start" && $6 == 2 { print $7 }')
size=$(xorriso -indev "$work/themed.iso" -report_system_area plain 2>/dev/null |
    awk '$1 == "GPT" && $2 == "start" && $6 == 2 { print $8 }')
dd if="$work/themed.iso" of="$work/esp.img" bs=512 skip="$start" count="$size" status=none
mcopy -i "$work/esp.img" ::/EFI/BOOT/grub.cfg "$work/esp.cfg"
cmp -s "$work/esp.cfg" "$work/themed.cfg" ||
    { echo "error: the stick's EFI partition doesn't hold the themed menu" >&2; exit 1; }

mv "$work/themed.iso" "$iso"
echo "themed $iso: menu in $(basename "$iso"):/EFI/BOOT/grub.cfg and its EFI partition, files in /themes/marah-os"
