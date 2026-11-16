# Marah OS

Marah OS turns a PC into a console. It starts straight into
[Marah Launcher](https://github.com/MarahHQ/marah-launcher), with no desktop.

<!-- x-release-please-start-version -->
The current version is Marah OS 0.2.0:
[its release](https://github.com/MarahHQ/marah-os/releases/tag/v0.2.0). Every release is on the
[releases page](https://github.com/MarahHQ/marah-os/releases).

The release has one ISO file for a USB stick, `marah-os-x86_64-0.2.0.iso`. An ISO over 2 GiB
comes in parts (`marah-os-x86_64-0.2.0.iso.part-aa`, `-ab`, …). Download every part, then join
them into the ISO:

- Linux and macOS:

  ```sh
  v=0.2.0
  cat marah-os-x86_64-$v.iso.part-* > marah-os-x86_64-$v.iso
  ```

- Windows (Command Prompt). Name every part, in order:

  ```bat
  set v=0.2.0
  copy /b marah-os-x86_64-%v%.iso.part-aa + marah-os-x86_64-%v%.iso.part-ab marah-os-x86_64-%v%.iso
  ```

Check the ISO against `marah-os-x86_64-0.2.0.iso.sha256`. Each part also has its own `.sha256`.

- Linux: `sha256sum -c marah-os-x86_64-0.2.0.iso.sha256`
- macOS: `shasum -a 256 -c marah-os-x86_64-0.2.0.iso.sha256`
<!-- x-release-please-end -->

Write the ISO to a USB stick and start the PC from it. Marah OS starts from the stick. Then
choose:

- **Try it**: play from the USB stick.
- **Install on this PC**: pick a disk of 40 GB or more. The install erases that whole disk.
- **Choose partitions instead**: Fedora's installer, to keep another system or use free space.
  The boot menu of the stick has the same entry, "Install Marah OS (choose partitions)".

## How it's built

The rest of this page is for people working on Marah OS. What Marah Launcher and the OS
expect from each other (the marker, the installer's protocol, the polkit rules,
`marah-launcher --supports`) is in
[docs/marah-os.md](https://github.com/MarahHQ/marah-launcher/blob/main/docs/marah-os.md).
`check-brand.sh` checks the paths the launcher looks for.

There are two images and one USB stick:

| | What | Published as |
|---|---|---|
| Minimal edition ([Containerfile](Containerfile), [files/](files/)) | Fedora's smallest bootable system, gamescope and Marah Launcher: no desktop | `ghcr.io/<owner>/marah-os:minimal` |
| NVIDIA edition ([nvidia/](nvidia/)) | The minimal edition plus NVIDIA's driver, as layers on top | `:minimal-nvidia` (only for NVIDIA PCs) |
| USB stick ([live/](live/), [build-iso.sh](build-iso.sh)) | Marah OS started from the stick: try it, or install it by erasing a disk or with your own partitions | `marah-os-x86_64-<version>.iso` in each release |

Each image also gets a dated tag (`minimal-20261024`) and, from an OS release, a version tag
(`minimal-0.2.0`).

## Minimal edition

| File | What it does |
|---|---|
| `Containerfile` | Fedora's minimal bootc set (`bootc-base-imagectl build-rootfs --manifest=minimal`: bootc, systemd, the kernel, dnf), then drivers and firmware, gamescope, cage, greetd, NetworkManager, BlueZ, PipeWire, the boot screen, and what Marah Launcher and the emulators load. Then the marah-launcher rpm from `marah-launcher-rpm/`. Universal Blue's kernel-module key is stored for the NVIDIA edition. os-release says Marah OS. |
| `fetch-marah-launcher.sh` | Downloads the marah-launcher rpm from the latest Marah Launcher release (or a given tag) into `marah-launcher-rpm/`, checked against its `.sha256`. |
| `marah-launcher.txt` | The latest Marah Launcher release, which the image bundles. Marah Launcher's `package.yml` writes it after each Marah Launcher release, which opens the OS release pull request ([Releases](#releases)). |
| `files/etc/greetd/config.toml` | Logs `player` in at boot and runs `/usr/bin/marah-session`, the session from the marah-launcher package (`packaging/linux/marah-session`). |
| `files/usr/lib/marah-os/` (made at build time) | `release`, the marker, holds `marah-launcher --version`. `image` holds where the PC updates from. |
| `files/usr/share/plymouth/themes/marah-os/` | The boot screen: the Marah Launcher logo, with Fedora's spinner images copied in at build time. |
| `files/usr/share/polkit-1/rules.d/50-marah-os.rules` | `player`, at the PC, manages the network and may start the update service ("check now"). |
| `files/usr/lib/sysusers.d/`, `tmpfiles.d/` | The `player` user (uid 1000, no password), in GameMode's `gamemode` group, and its home. |
| `files/usr/libexec/marah-os/update`, `files/usr/lib/systemd/system/marah-os-update.*` | Daily, from 3 minutes after start (and every 15 minutes while offline): stage the next image, and the right one for the graphics card (an NVIDIA PC switches to `:minimal-nvidia`; with Secure Boot on, only once Universal Blue's key is enrolled, which it queues). Downloads only: Fedora's own timer, which restarts the PC, is masked. |
| `files/usr/lib/bootc/{install,kargs.d}/` | XFS root, a quiet boot with the splash, and `systemd.gpt_auto=0` (otherwise the EFI partition is mounted over `/boot` and updates fail to finish). |
| `files/usr/lib/bootupd/grub2-static/configs.d/` | The boot menu stays hidden unless Esc or Shift is held. |
| `grub-theme/` | The USB stick's boot menu theme: `make.sh` draws it from the logo and Inter into `marah-os/`, and writes `theme.cfg`, the GRUB lines that turn it on. `add-to-iso.sh` puts both on the finished stick (build-iso.sh runs it). With Secure Boot, GRUB loads no font file, so the entries use GRUB's own font. The BIOS menu has no theme. |

The build is a `FROM scratch` image, so the workflow splits it into one layer per package
(`bootc-base-imagectl rechunk`, timestamps zeroed): a daily rebuild only changes the layers whose
packages changed, and that's all a PC downloads.

Marah Launcher updates with the system: the image is rebuilt after every Marah Launcher release, and installed PCs
stage it with their next update.

## NVIDIA edition

NVIDIA's 580 driver series (today's cards and the GTX 900/1000 ones newer series dropped) from
Universal Blue's `akmods-nvidia-lts`, built for the minimal edition's exact kernel and signed
with their key. The workflow builds it right after `:minimal`, for that image's kernel; until
Universal Blue has modules for a new kernel (usually within a day) it keeps the previous one.
No CUDA tools, settings app or 32-bit libraries; nouveau off, kernel modesetting on.

Nobody picks it: the erase-disk installer installs it on an NVIDIA PC with internet (downloading
only the driver layers), and otherwise the installed PC switches to it by itself
(`marah-os/update`).

## USB stick

`live/Containerfile` is the minimal edition plus dracut's live module, Anaconda, and the boot
files. It's never pushed. `build-iso.sh` turns it into one ISO, with the minimal image stored
inside it for offline installs.

Boot menu (`live/files/usr/lib/image-builder/bootc/iso.yaml`):

| Entry | What starts |
|---|---|
| Marah OS (the default) | Marah OS from the stick, changes kept in memory. Marah Launcher shows "Welcome to Marah OS": try it, or install it. |
| Install Marah OS (choose partitions) | The same live system, with `systemd.unit=marah-os-anaconda.target`: Anaconda full screen in cage instead of Marah Launcher. |
| Marah OS (basic graphics) | The first entry with `nomodeset`. |

- The minimal image is stored as a read-only container store in the stick's root filesystem
  (`/var/lib/containers/storage` there). The live system sees it at
  `/run/rootfsbase/var/lib/containers/storage` (`live/files/etc/containers/storage.conf`).
  Podman's own storage and `/var/tmp` are in memory on the stick.
- **Erase a disk:** `live/files/usr/libexec/marah-os/install` (run by Marah Launcher as `marah-os-install`, a link in `/usr/bin`) lists the disks and installs
  (`bootc install to-disk` from the stored image), with NVIDIA's driver when it applies, and
  copies saved Wi-Fi to the installed system. A polkit rule lets `player` run it, on the stick
  only.
- **Choose partitions:** `live/files/usr/share/anaconda/interactive-defaults.ks` is Anaconda's
  kickstart. It has no partitioning, so the disk screen decides. It installs the stored image
  (`ostreecontainer --transport=containers-storage`), sets English and UTC as defaults, and
  locks root; `live/files/etc/anaconda/conf.d/90-marah-os.conf` hides the user, root password
  and network screens. Its `%post` makes the installed PC follow `ghcr.io/<owner>/marah-os:minimal`,
  drops the `/` line Anaconda writes in `/etc/fstab` (it makes `systemd-remount-fs` fail on a
  bootc system), and queues Universal Blue's key on an NVIDIA PC with Secure Boot.
  `marah-os-install --choose-partitions` switches a running stick to Anaconda (`systemctl isolate marah-os-anaconda.target`),
  for Marah Launcher's "Choose partitions instead".
- `build-iso.sh` refuses a Marah Launcher without the install screens (`marah-launcher --supports os-install`),
  so release Marah Launcher before an OS change that needs it.
- In a test build the stored image is the `-test` one, but it's still called `:minimal` on the
  stick, so the installers find it. A PC installed from it moves to the real `:minimal` with
  its first update.

### Two ways to make the ISO

`build-iso.sh` makes the ISO with osbuild's
[image-builder](https://osbuild.org/docs/developer-guide/projects/image-builder/advanced/bootc/isos/)
and its `bootc-generic-iso` type by default: the live container becomes the squashfs, GRUB's
menu comes from `iso.yaml`, and `--bootc-installer-payload-ref` copies the minimal image into it.

If image-builder can't make a stick that starts live (or isn't available), `METHOD=xorriso`
makes the same ISO by hand: the live container's files in a squashfs, the
minimal image pushed into its `/var/lib/containers/storage`, Fedora's shim and GRUB on an EFI
partition, and xorriso. Its GRUB menu is made from the same `iso.yaml`, hidden unless Esc or
Shift is held. Both make one ISO with the same entries.

image-builder's `iso.yaml` has no hidden-menu setting, so its menu shows for 5 seconds.

## Releases

Release Please keeps a release pull request open on main: it bumps `version.txt`, the versions
in "Download" above and `CHANGELOG.md`, and its tags are `v<version>`. The OS bundles Marah
Launcher, so each Marah Launcher release is a change to the OS too: once it's published,
Marah Launcher's `package.yml` writes its tag to `marah-launcher.txt` on main here, with the
Marah Bot's token, as `feat: bundle Marah Launcher v<version>` for a new major or minor Marah
Launcher and `fix` for a patch, and the release pull request opens. Merging it makes a draft
release and its tag (`.github/workflows/release.yml`), which starts `.github/workflows/os.yml` on
the tag, in a run of its own, which:

1. builds, checks and pushes both images from the tag, tagged with the version too;
2. builds the ISO from the minimal image just pushed;
3. splits it into 1500 MB parts when it's over 2 GiB, with a `.sha256` for the whole ISO and for
   each part;
4. attaches them to the draft and publishes it.

The images bundle the latest published Marah Launcher release, so the first OS release needs one.
When no Marah Launcher release is published, the run stops at its start with "release Marah
Launcher first". If a run fails, its draft and tag stay: run the failed jobs again (or Actions →
Marah OS → Run workflow, with the tag under "Use workflow from") rather than making a new
release.

`os.yml` also runs daily, and after each Marah Launcher release (its `package.yml` starts it), for the images
only. By hand (Actions → Marah OS → Run workflow) it runs in test mode by default: images under `-test` tags no PC
follows, and the ISO kept as the run's `marah-os-iso` artifact for 3 days.

The images must be public packages: the installers and installed PCs pull without logging in.
`os.yml` checks this; GitHub creates packages private, so change it once in the package's
settings.

## Build and test locally

The images and the stick need podman as root (bootc-base-imagectl, rechunking and image-builder
need real privileges, loop devices included); the scripts run it with sudo. `os.yml` runs the same
scripts. From the repository root:

```bash
fetch-marah-launcher.sh          # the latest release's rpm into marah-launcher-rpm/ (or copy a local one there)
build-image.sh          # localhost/marah-os:minimal
make-iso.sh             # marah-os-x86_64-<version>.iso from it (version.txt)
run-vm.sh               # starts it in QEMU (below)
```

`make os-image`, `make os-iso` and `make os-vm` run them; `make os-image RPM=<file>` bundles a
local rpm, such as `make test-rpm`'s.

`METHOD=xorriso make-iso.sh` makes the hand-made ISO.

`run-vm.sh` boots the ISO in a UEFI VM as a USB stick, with Secure Boot, 6 GB of memory, and
a 64 GB disk to install on (`os-vm.qcow2`, kept between starts; delete it to start over). It
needs three Fedora packages:

```bash
sudo dnf install qemu-kvm qemu-img edk2-ovmf
```

The ISO from a test run of `os.yml` works too: its `marah-os-iso` artifact, with `-test` after
the version (`marah-os-x86_64-0.2.0-test.iso`). Over 2 GiB it comes in parts, as on a release;
join them and check the ISO first:

```bash
iso=marah-os-x86_64-0.2.0-test.iso
cat "$iso".part-* > "$iso"
sha256sum -c "$iso.sha256"
run-vm.sh "$iso"
```

To check the partitioning install, give that disk an NTFS partition first and keep it in
Anaconda's disk screen. A VM has no GPU Vulkan, so Marah Launcher shows in cage there, and draws slowly; nor has it Wi-Fi
or Bluetooth. Those controls are tested on a PC from the stick, or on a desktop with
`MARAH_SESSION=1` ([development.md](https://github.com/MarahHQ/marah-launcher/blob/main/docs/development.md)).

What to check before a release:

- the live start, and Marah Launcher's welcome;
- an erase-disk install to an empty disk, then its first start;
- an Anaconda install that keeps an existing partition, then its first start:
  `systemctl status systemd-remount-fs` is fine, and `bootc status` shows
  `ghcr.io/<owner>/marah-os:minimal`;
- "Choose partitions instead" from the running stick reaches Anaconda.
