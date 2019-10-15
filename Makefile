ARCH ?= arm64
FLASH_DEV ?= /dev/mmcblk0

help:
	@echo build a gentoo system to run on a raspberry pi
	@echo
	@echo some target of interest:
	@echo '    chroot         build the system and chroot into'
	@echo '    flash-init     create the layout and filesystems'
	@echo '    flash-mount    mount the device to the root directory'
	@echo some variables of interest:
	@echo '    ARCH           arch to use, one of {arm,arm64}, currently $(ARCH)'
	@echo '    FLASH_DEV      path to flash device, currently $(FLASH_DEV)'
	@echo
	@echo the first steps for a first use would be
	@echo '    $(MAKE) flash-init flash-mount chroot'
	@echo you probably now want to configure around, setup make.conf, start to emerge stuff,
	@echo such as sys-boot/raspberrypi-firmware
	@echo then, when happy with it, umount it and go use it
	@echo '    $(MAKE) flash-umount'
	@echo if after some testing, you want to change something, use
	@echo '    $(MAKE) flash-mount chroot'


progress_dir ?= .progress
progress_tmp_dir ?= /tmp/rastoo
dist_dir ?= distdir
root_dir ?= root

ifeq ($(findstring $(ARCH),arm arm64),)
$(error unknow arch)
endif
ifeq ($(ARCH),arm)
stage3_arch := armv6j
qemu_arch := arm
endif
ifeq ($(ARCH),arm64)
stage3_arch := armv7a
qemu_arch := aarch64

$(progress_dir)/arm64_rebuild: chroot-ready
	@echo because there is no pre built stage3 for arm64, we rebuild most of it
	chroot $(root_dir) emerge -e @system
	touch $@

chroot: $(progress_dir)/arm64_rebuild
endif

distfiles := http://distfiles.gentoo.org/
distfiles_stage3 := $(distfiles)/releases/arm/autobuilds
stage3_subdir := $(firstword $(shell curl -s "$(distfiles_stage3)/latest-stage3-$(stage3_arch)_hardfp.txt" | tail -n1))
stage3_name := $(notdir $(stage3_subdir))
portage_name := portage-latest.tar.bz2

$(dist_dir) $(progress_dir) $(progress_tmp_dir) $(root_dir):
	mkdir -p $@
$(dist_dir)/$(stage3_name): | $(dist_dir)
	curl $(distfiles_stage3)/$(stage3_subdir) -o $@
$(dist_dir)/$(portage_name): | $(dist_dir)
	curl $(distfiles)/snapshots/$(portage_name) -o $@

$(progress_dir)/stage3_extracted: $(dist_dir)/$(stage3_name) | $(progress_dir) $(root_dir)
	tar xpjf $< -C $(root_dir)
	touch $@
$(progress_dir)/portage_extracted: $(dist_dir)/$(portage_name) | $(progress_dir)/stage3_extracted
	tar xpjf $< -C $(root_dir)/usr
	touch $@

qemu_atom := app-emulation/qemu[qemu_user_targets_$(qemu_arch),static-user]
/usr/bin/qemu-$(qemu_arch):
	emerge $(qemu_atom)
$(root_dir)/usr/bin/qemu-$(qemu_arch): | /usr/bin/qemu-$(qemu_arch) $(progress_dir)/portage_extracted
	quickpkg $(qemu_atom)
	ROOT=$(root_dir) emerge --usepkgonly --oneshot --nodeps $(qemu_atom)

/proc/sys/fs/binfmt_misc:
	$(error need a kernel with CONFIG_BINFMT_MISC=y)
$(progress_tmp_dir)/qemu-binfmt_started: | $(progress_tmp_dir) $(root_dir)/usr/bin/qemu-$(qemu_arch) /proc/sys/fs/binfmt_misc
	rc-service qemu-binfmt start
	touch $@
$(progress_tmp_dir)/root_subdir_mounted: | $(progress_tmp_dir) $(progress_dir)/stage3_extracted
	mount -o bind /dev $(root_dir)/dev
	mount -o bind /proc $(root_dir)/proc
	mount -o bind /sys $(root_dir)/sys
	mount -o rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000 devpts $(root_dir)/dev/pts -t devpts
	touch $@
$(root_dir)/etc/resolv.conf: /etc/resolv.conf | $(progress_dir)/stage3_extracted
	cp $< $@

.PHONY: chroot-ready
chroot-ready: $(root_dir)/etc/resolv.conf $(progress_tmp_dir)/root_subdir_mounted | $(progress_tmp_dir)/qemu-binfmt_started

.PHONY: chroot
chroot: chroot-ready
	chroot $(root_dir) /bin/bash


.PHONY: flash-init
flash-init: $(progress_dir)/flash_parted

$(progress_dir)/flash_layouted: | $(progress_dir)
	echo g  n 1 '' +512M  t 1  n 2 '' ''  t 2 23  w | \
		tr ' ' '\n' | fdisk $(FLASH_DEV)
	touch $@
/usr/sbin/mkfs.f2fs:
	emerge sys-fs/f2fs-tools
$(progress_dir)/flash_parted: /usr/sbin/mkfs.f2fs | $(progress_dir)/flash_layouted
	$< $(FLASH_DEV)p1
	$< $(FLASH_DEV)p2
	touch $@


.PHONY: flash-mount
flash-mount: $(progress_tmp_dir)/flash_mounted
$(progress_tmp_dir)/flash_mounted: | $(progress_tmp_dir)
	mount $(FLASH_DEV)p2 $(root_dir)
	mount $(FLASH_DEV)p1 $(root_dir)/boot
	touch $@
.PHONY: flash-umount
flash-umount: $(progress_tmp_dir)/flash_mounted
	mount $(root_dir)
	mount $(root_dir)/boot
	rm $<
