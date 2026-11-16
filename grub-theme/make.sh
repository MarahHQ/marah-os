#!/usr/bin/env bash
# Makes the Marah OS boot menu theme in grub-theme/marah-os/ from grub-theme/src/ (the logo
# and Inter): grub-theme/make.sh. The results are kept in the repository, so a build needs no
# image tools; run this again after changing the logo or the text. Needs rsvg-convert and
# ImageMagick's magick.
#
# With Secure Boot, Fedora's signed GRUB loads no font file ("prohibited by secure boot
# policy"), so the menu items use GRUB's own font. The fixed text (the title and the hint) is
# drawn here with Inter, as pictures. Every PNG is 8-bit RGB or RGBA: GRUB reads no palette PNG.
set -euo pipefail
cd "$(dirname "$0")"
src=src out=marah-os
mkdir -p "$out"
rm -f "$out"/*.png

magick -size 1920x1080 radial-gradient:'#16324a'-'#0b1520' -depth 8 -define png:color-type=2 "$out/background.png"
rsvg-convert -w 128 -h 128 "$src/logo.svg" -o "$out/logo.png"
magick -background none -fill '#eef6fb' -font "$src/Inter-SemiBold.ttf" -pointsize 40 label:'Marah OS' \
    -depth 8 PNG32:"$out/title.png"
magick -background none -fill '#8aa4b8' -font "$src/Inter-Regular.ttf" -pointsize 26 \
    label:'Up and down to choose · Enter to start' -depth 8 PNG32:"$out/hint.png"

# The selected entry: a rounded box in the accent, cut into GRUB's nine pieces of 12 px.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
magick -size 36x36 xc:none -fill '#4c8bdc' -draw 'roundrectangle 0,0 35,35 10,10' -depth 8 PNG32:"$work/box.png"
for spec in "nw 0 0" "n 12 0" "ne 24 0" "w 0 12" "c 12 12" "e 24 12" "sw 0 24" "s 12 24" "se 24 24"; do
    # shellcheck disable=SC2086 # three words on purpose
    set -- $spec
    magick "$work/box.png" -crop "12x12+$2+$3" +repage -depth 8 PNG32:"$out/select_$1.png"
    magick -size 12x12 xc:none -depth 8 PNG32:"$out/menu_$1.png"
done

# The title and the hint are centred by half their width.
tw=$(magick identify -format %w "$out/title.png")
hw=$(magick identify -format %w "$out/hint.png")
sed -e "s/HALF_TITLE/$((tw / 2))/" -e "s/HALF_HINT/$((hw / 2))/" theme.txt.in > "$out/theme.txt"
cp "$src/OFL-Inter.txt" "$out/"

# The lines that turn the theme on, for after the menu's `search ... --set=root` line. GRUB uses
# the theme only when every file is there: a missing one would stop the menu at "Press any key
# to continue", with no keyboard in reach of a TV. Otherwise it shows its plain text menu.
files=$(cd "$out" && ls -- *.png theme.txt | tr '\n' ' ')
cat > theme.cfg <<'CFG'
# The Marah OS menu theme (grub-theme/), when all its files are on this disk.
set marah_theme=($root)/themes/marah-os
set marah_whole=y
for f in FILES; do
    if [ ! -f $marah_theme/$f ]; then set marah_whole=n; fi
done
if [ "$marah_whole" = y ]; then
    insmod all_video
    insmod gfxterm
    insmod png
    set gfxmode=1280x720,1280x800,1024x768,auto
    terminal_output gfxterm
    set theme=$marah_theme/theme.txt
fi
CFG
sed -i "s/FILES/${files% }/" theme.cfg
echo "made $out/: $(ls "$out" | wc -l) files"
