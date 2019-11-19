ARCH ?= arm64
FLASH_DEV ?= /dev/mmcblk0

help:
	@echo 'Build a gentoo system to run on a raspberry pi'
	@echo
	@echo Some target of interest:
	@echo '    disk-prepare create the label, paritions and filesystems'
	@echo '    disk-mount     mount the root and boot partitions' 
	@echo '    system-install install stage3 and snapshot'
	@echo '    chroot         chroot into the system'
	@echo '    boot-install   populate /boot'
	@echo 'Some variables of interest:'
	@echo '    ARCH           arch to use, one of {arm,arm64}, currently $(ARCH)'
	@echo '    FLASH_DEV      path to flash device, currently $(FLASH_DEV)'
	@echo 'For a first you would start with:'
	@echo '    $(MAKE) disk-prepare disk-mount system-install'
	@echo 'You can them chroot using "$(MAKE) chroot" to setup the system:'
	@echo 'Refer to the handbook to sync and choose a profile'
	@echo 'and choose a profile among:'
	@echo 'eselect profile list'
	@echo 'Finally you can freshen the system using:'
	@echo 'emerge --ask --verbose --emptytree --complete-graph=y @world'
	@echo 'Once done, unchroot and install the boot'
	@echo 'such as sys-boot/raspberrypi-firmware'
	@echo 'When finished you can umount using:'
	@echo '    $(MAKE) disk-umount'
	@echo 'And chroot again another time with:'
	@echo '    $(MAKE) disk-mount chroot'

ifeq ($(findstring $(ARCH), arm arm64),)
$(error unknow arch, available architectures are arm and arm64)
endif

progress_dir ?= .progress
progress_tmp_dir ?= /tmp/rastoo
dist_dir ?= distdir
root_dir ?= root


### DISK PREPARATION ###

.PHONY: disk-prepare
disk-prepare: $(progress_dir)/partitioned_disk $(progress_dir)/fs_installed

$(progress_dir)/partitioned_disk: | $(progress_dir)
	parted -s $(FLASH_DEV) -- \
		mklabel gpt \
		mkpart boot 0% 512MiB \
		set 1 esp on \
		mkpart root 512Mib 100%
	touch $@

$(progress_dir) $(progress_tmp_dir) $(root_dir) $(dist_dir):
	mkdir -p $@

/usr/sbin/mkfs.f2fs:
	emerge sys-fs/f2fs-tools

partition_1 = $$(lsblk -nl -o PATH $(FLASH_DEV) | sed '2q;d')
partition_2 = $$(lsblk -nl -o PATH $(FLASH_DEV) | sed '3q;d')

$(progress_dir)/fs_installed: /usr/sbin/mkfs.f2fs | $(progress_dir)/partitioned_disk
	$< -f $(partition_1) 
	$< -f $(partition_2) 
	touch $@


## MOUNT / UMOUNT ##

.PHONY: disk-mount
disk-mount: $(progress_tmp_dir)/root_mounted $(progress_tmp_dir)/boot_mounted

$(progress_tmp_dir)/root_mounted: | $(progress_tmp_dir) $(root_dir)
	mount $(partition_2) $(root_dir)
	touch $@

$(progress_tmp_dir)/boot_mounted: $(progress_tmp_dir)/root_mounted | $(progress_tmp_dir)
	mkdir -p $(root_dir)/boot
	mount $(partition_1) $(root_dir)/boot
	touch $@

.PHONY: disk-umount
disk-umount: $(progress_tmp_dir)/root_mounted $(progress_tmp_dir)/boot_mounted
	umount -Rq $(root_dir)
	rm -f $^

## SYSTEM INSTALL ##

distfiles := http://distfiles.gentoo.org
ifeq ($(ARCH), arm)
	stage3_arch := armv6j
	qemu_arch := arm
	distfiles_stage3 := $(distfiles)/releases/arm/autobuilds
	stage3_subdir := $(firstword $(shell curl -s "$(distfiles_stage3)/latest-stage3-$(stage3_arch)_hardfp.txt" | tail -n1))
endif
ifeq ($(ARCH), arm64)
	stage3_arch := arm64
	qemu_arch := aarch64
	distfiles_stage3 := $(distfiles)/experimental/arm64
	stage3_subdir := stage3-arm64-20190613.tar.bz2
endif
stage3_name := $(notdir $(stage3_subdir))

.PHONY: system-install
system-install: stage3_extracted snapshot_extracted

.PHONY: stage3_extracted
stage3_extracted: | $(root_dir)/usr/bin/emerge-webrsync #among others...

$(root_dir)/usr/bin/emerge-webrsync: | $(dist_dir)/$(stage3_name) $(root_dir)
	tar xpjf $(dist_dir)/$(stage3_name) --xattrs-include='*.*' --numeric-owner -C $(root_dir)

$(dist_dir)/$(stage3_name): | $(dist_dir)
	curl $(distfiles_stage3)/$(stage3_subdir) -o $@

.PHONY: snapshot_extracted
snapshot_extracted: | $(root_dir)/var/db/repos/gentoo

$(root_dir)/var/db/repos/gentoo: chroot-ready | $(root_dir)/usr/bin/emerge-webrsync
	chroot $(root_dir) /usr/bin/emerge-webrsync
	echo '\n# Bypass bugs in qemu-chrooting\nFEATURES="$${FEATURES} -pid-sandbox"' >> $(root_dir)/etc/portage/make.conf


## BOOT INSTALL ## 

.PHONY: boot-install
boot-install:
	@echo not implemented


### CHROOT ###

qemu_atom := app-emulation/qemu[qemu_user_targets_$(qemu_arch),static-user]

.PHONY: chroot
chroot: chroot-ready 
	chroot $(root_dir) /bin/bash

.PHONY: chroot-ready
chroot-ready: $(root_dir)/etc/resolv.conf $(progress_tmp_dir)/root_subdir_mounted | stage3_extracted $(progress_tmp_dir)/qemu-binfmt_started $(root_dir)/usr/bin/qemu-$(qemu_arch)

$(root_dir)/etc/resolv.conf: /etc/resolv.conf | stage3_extracted
	cp --dereference $< $@

$(progress_tmp_dir)/root_subdir_mounted: | $(progress_tmp_dir) stage3_extracted
	mount -o bind /dev $(root_dir)/dev
	mount -o bind /proc $(root_dir)/proc
	mount -o bind /sys $(root_dir)/sys
	mount -o rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000 devpts $(root_dir)/dev/pts -t devpts
	touch $@

$(progress_tmp_dir)/qemu-binfmt_started: | $(progress_tmp_dir) /proc/sys/fs/binfmt_misc
	rc-service qemu-binfmt start
	touch $@

/proc/sys/fs/binfmt_misc:
	$(error need a kernel with CONFIG_BINFMT_MISC=y)

$(root_dir)/usr/bin/qemu-$(qemu_arch): | /usr/bin/qemu-$(qemu_arch)
	quickpkg $(qemu_atom)
	ROOT=$(root_dir) emerge --usepkgonly --oneshot --nodeps $(qemu_atom)

/usr/bin/qemu-$(qemu_arch):
	emerge $(qemu_atom)


## CLEAN ##

.PHONY: clean
clean: disk-umount 
	rm -rf $(progress_dir)
	rm -rf $(progress_tmp_dir)
	rm -rf $(dist_dir)
	rm -rf $(root_dir)

