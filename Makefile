# Marah OS: the image, the USB stick and a VM to try it. `make` lists the targets.
.DEFAULT_GOAL := help
.PHONY: help image iso vm check

IMAGE ?= localhost/marah-os:minimal
BASE ?= quay.io/fedora/fedora-bootc:45
ISO ?= marah-os-x86_64-$(shell cat version.txt).iso

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

image: ## The image as IMAGE (build-image.sh, sudo); RPM=<file> bundles that rpm, not the latest release's
	@if [ -n "$(RPM)" ]; then rm -rf marah-launcher-rpm && mkdir -p marah-launcher-rpm && cp "$(RPM)" marah-launcher-rpm/; \
	else ./fetch-marah-launcher.sh; fi
	BASE=$(BASE) ./build-image.sh $(IMAGE)

iso: ## The USB stick, ISO, from IMAGE (make-iso.sh; make image first)
	BASE=$(BASE) ./make-iso.sh $(IMAGE) $(ISO)

vm: ## Start ISO in QEMU as a USB stick, with Secure Boot and a 64 GB disk (run-vm.sh)
	./run-vm.sh $(ISO)

check: ## The shell scripts parse, the paths the launcher expects are the ones made (check-brand.sh), and the tests pass (tests/)
	for f in *.sh tests/*.sh live/files/usr/libexec/marah-os/* files/usr/libexec/marah-os/*; do bash -n "$$f" || exit; done
	./check-brand.sh
	for t in tests/*.sh; do "$$t" || exit; done
