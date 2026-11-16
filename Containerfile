# Marah OS, minimal edition: Fedora's bootable container base with only what a console needs
# (drivers and firmware, gamescope, networking, Bluetooth, sound) and Marah Launcher as the whole screen.
# No desktop: Marah Launcher's Settings → System does Wi-Fi, pairing, sound output, updates and power.
# Updates replace the whole system atomically (bootc), with the previous one kept in the boot menu.
#
# Marah Launcher comes from its rpm, which fetch-marah-launcher.sh downloads from the latest Marah Launcher release into
# marah-launcher-rpm/ (or put a locally built one there). Build from the repository root
# (bootc-base-imagectl needs the extra privileges):
#   podman build --cap-add=all --security-opt=label=disable --device /dev/fuse -f Containerfile .
# then split it into one layer per package (the workflow does this), so updates only download
# what changed:
#   podman run --rm --privileged -v /var/lib/containers:/var/lib/containers quay.io/fedora/fedora-bootc:44 \
#     /usr/libexec/bootc-base-imagectl rechunk IMAGE-BUILT IMAGE
ARG BASE_IMAGE=quay.io/fedora/fedora-bootc:44
FROM ${BASE_IMAGE} AS builder
# Fedora's smallest bootable set (bootc, systemd, the kernel, dnf), from Fedora's own packages:
# its standard base is a headless server (cloud SDKs, QEMU for other processors, LVM, toolbox),
# about a fifth of the download, that a console never uses.
RUN /usr/libexec/bootc-base-imagectl build-rootfs --manifest=minimal / /target-rootfs

FROM scratch
COPY --from=builder /target-rootfs/ /

RUN set -eux; \
    dnf5 -y install --setopt=install_weak_deps=False \
        # Display: gamescope with its X server, and cage when gamescope can't drive the card.
        # Mesa covers AMD, Intel and (NVK) NVIDIA.
        gamescope xorg-x11-server-Xwayland greetd cage \
        mesa-dri-drivers mesa-vulkan-drivers vulkan-loader mesa-libEGL mesa-libGL libglvnd-gles libglvnd-opengl \
        # Firmware for graphics cards, Wi-Fi, Bluetooth and sound.
        linux-firmware amd-gpu-firmware intel-gpu-firmware nvidia-gpu-firmware amd-ucode-firmware \
        iwlwifi-mvm-firmware iwlwifi-dvm-firmware atheros-firmware brcmfmac-firmware mt7xxx-firmware \
        realtek-firmware intel-audio-firmware alsa-sof-firmware \
        # Network, Bluetooth, sound: what Settings → System runs (nmcli, bluetoothctl, pactl).
        NetworkManager NetworkManager-wifi wpa_supplicant bluez \
        pipewire pipewire-pulseaudio pipewire-alsa wireplumber alsa-ucm pulseaudio-utils \
        # What Marah Launcher and the emulators load (X11/Wayland, audio, input, archives, trailers).
        libX11 libXext libXcursor libXi libXfixes libXrandr libXScrnSaver libXtst \
        libxkbcommon libxkbcommon-x11 libwayland-client libwayland-cursor libwayland-egl \
        alsa-lib pulseaudio-libs dbus-libs libuuid libcap libarchive mpv-libs yt-dlp \
        xdotool xprop \
        # GameMode: Marah Launcher runs PC games through gamemoderun (the player is in its group).
        gamemode \
        # bubblewrap: the sandbox a Windows game runs in.
        bubblewrap \
        # Not in Fedora's minimal set, but used: tar (the emulators' updates), lspci (Settings →
        # This PC names the graphics card), rpm-ostree (Settings → System's update status),
        # chrony (the clock: HTTPS needs the right time), mokutil (Universal Blue's key for NVIDIA).
        tar pciutils rpm-ostree chrony mokutil \
        # The boot screen: the Marah Launcher logo instead of text (files/…/plymouth/themes/marah-os).
        plymouth plymouth-theme-spinner \
        fontconfig google-noto-sans-fonts google-noto-sans-arabic-fonts google-noto-emoji-fonts; \
    dnf5 clean all

# Universal Blue's kernel-module key: NVIDIA's driver (the :minimal-nvidia version) is signed
# with it, and with Secure Boot on, the PC needs it enrolled once (marah-os/update queues it).
RUN set -eux; \
    mkdir -p /usr/share/marah-os; \
    curl -fsSL --retry 3 -o /usr/share/marah-os/secureboot.der https://github.com/ublue-os/akmods/raw/main/certs/public_key.der; \
    echo "4e5c68474cb133fd8984d9599762cece9100c3e6cd8a9709aeaabd85dd9e70d1  /usr/share/marah-os/secureboot.der" | sha256sum -c -

# Declared after the packages, so a new value doesn't download them all again.
# OS_VERSION: version.txt. BUILD_DATE: the day it was built (daily rebuilds). Both are shown in
# Settings → System through os-release.
ARG OS_VERSION=dev
ARG BUILD_DATE=dev
# Where the PC updates from (without the tag), and the repository it comes from.
ARG IMAGE=ghcr.io/marahhq/marah-os
ARG REPO=MarahHQ/marah-launcher

# Marah Launcher itself, from its rpm: the binary in /usr/lib/marah-launcher, `marah-launcher` on the PATH, and the Marah Launcher
# session (/usr/bin/marah-session) that greetd runs. It's updated with the system, never in place.
RUN --mount=type=bind,source=marah-launcher-rpm,target=/tmp/marah-launcher-rpm set -eux; \
    dnf5 -y install --setopt=install_weak_deps=False /tmp/marah-launcher-rpm/marah-launcher-*.x86_64.rpm; \
    dnf5 clean all

COPY files/ /

# pipefail: `marah-launcher --version | tee …` fails the step when marah-launcher fails (podman's default image
# format ignores SHELL).
RUN set -euxo pipefail; \
    chmod 0755 /usr/libexec/marah-os/update; \
    # The system calls itself Marah OS (boot menu, Settings); the rest of os-release stays
    # Fedora's, which tools like dnf and bootc read.
    sed -i -e 's/^NAME=.*/NAME="Marah OS"/' -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Marah OS $OS_VERSION ($BUILD_DATE)\"/" \
        -e 's/^DEFAULT_HOSTNAME=.*/DEFAULT_HOSTNAME="marah-os"/' -e "s|^HOME_URL=.*|HOME_URL=\"https://github.com/$REPO\"|" \
        -e "s|^SUPPORT_URL=.*|SUPPORT_URL=\"https://github.com/$REPO/issues\"|" \
        -e "s|^BUG_REPORT_URL=.*|BUG_REPORT_URL=\"https://github.com/$REPO/issues\"|" -e '/^LOGO=/d' /usr/lib/os-release; \
    # The boot screen, in the initramfs too so it shows from the start.
    cp -n /usr/share/plymouth/themes/spinner/*.png /usr/share/plymouth/themes/marah-os/; \
    plymouth-set-default-theme marah-os; \
    kver=$(cd /usr/lib/modules && echo *); \
    # /root links to /var/roothome, which only exists on an installed system (dracut follows it,
    # and fails without it).
    mkdir -p /var/roothome; \
    dracut --force --kver "$kver" "/usr/lib/modules/$kver/initramfs.img"; \
    rm -rf /var/roothome; \
    # The Marah OS marker: Marah Launcher reads it to know it's the whole system. It holds the bundled
    # Marah Launcher's version. /usr/lib/marah-os/image is where the PC updates from.
    mkdir -p /usr/lib/marah-os; \
    marah-launcher --version | tee /usr/lib/marah-os/release; \
    test -s /usr/lib/marah-os/release; \
    echo "$IMAGE" > /usr/lib/marah-os/image; \
    systemctl enable greetd.service NetworkManager.service bluetooth.service chronyd.service marah-os-update.timer; \
    systemctl set-default graphical.target; \
    # Anaconda (and others) set text mode (multi-user.target) as the default: the console's
    # session must start there too.
    systemctl add-wants multi-user.target greetd.service; \
    # Fedora's update timer restarts the PC by itself; ours only downloads (Settings shows "Restart").
    systemctl mask bootc-fetch-apply-updates.timer; \
    rm -rf /var/cache/* /var/log/* /tmp/*; \
    bootc container lint

LABEL org.opencontainers.image.version="${OS_VERSION}" \
      org.opencontainers.image.title="Marah OS (minimal)" \
      org.opencontainers.image.description="A PC that starts straight into Marah Launcher: Fedora bootc, gamescope, no desktop" \
      org.opencontainers.image.source="https://github.com/${REPO}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
LABEL containers.bootc=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
