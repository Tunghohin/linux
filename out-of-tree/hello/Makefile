MODULE_NAME := hello
MODULE_KO := $(MODULE_NAME).ko
REPO_ROOT := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

ifneq ($(KERNELRELEASE),)
obj-m := $(MODULE_NAME).o
else
KDIR ?= $(REPO_ROOT)
DEBUGFS ?= $(shell command -v debugfs 2>/dev/null || printf '%s' debugfs)
E2FSCK ?= $(shell command -v e2fsck 2>/dev/null || printf '%s' e2fsck)
FUSER ?= $(shell command -v fuser 2>/dev/null || printf '%s' fuser)
CCACHE_DISABLE ?= 1
INITRAMFS_IMAGE ?= $(REPO_ROOT)/.initramfs/rootfs-debian.ext4
INITRAMFS_HOME ?= /root
INITRAMFS_MODULE_PATH ?= $(INITRAMFS_HOME)/$(MODULE_KO)

.PHONY: all clean launch copy-to-initramfs

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) CCACHE_DISABLE=$(CCACHE_DISABLE)

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) CCACHE_DISABLE=$(CCACHE_DISABLE) clean

launch: all
	@test -f "$(INITRAMFS_IMAGE)" || { echo "missing initramfs image: $(INITRAMFS_IMAGE)"; exit 1; }
	@command -v "$(DEBUGFS)" >/dev/null 2>&1 || { echo "missing debugfs: $(DEBUGFS)"; exit 1; }
	@command -v "$(E2FSCK)" >/dev/null 2>&1 || { echo "missing e2fsck: $(E2FSCK)"; exit 1; }
	@command -v "$(FUSER)" >/dev/null 2>&1 || { echo "missing fuser: $(FUSER)"; exit 1; }
	@$(FUSER) "$(INITRAMFS_IMAGE)" >/dev/null 2>&1 && { \
		echo "$(INITRAMFS_IMAGE) is in use; stop QEMU or unmount it before copying"; \
		exit 1; \
	} || true
	@set -eu; \
	run_fsck() { \
		status=0; \
		"$(E2FSCK)" -fy "$(INITRAMFS_IMAGE)" || status=$$?; \
		if [ "$$status" -gt 3 ]; then \
			echo "e2fsck failed for $(INITRAMFS_IMAGE) with exit code $$status" >&2; \
			exit "$$status"; \
		fi; \
	}; \
	run_fsck; \
	"$(DEBUGFS)" -w -R "mkdir $(INITRAMFS_HOME)" "$(INITRAMFS_IMAGE)" >/dev/null 2>&1 || true; \
	"$(DEBUGFS)" -w -R "rm $(INITRAMFS_MODULE_PATH)" "$(INITRAMFS_IMAGE)" >/dev/null 2>&1 || true; \
	"$(DEBUGFS)" -w -R "write $(CURDIR)/$(MODULE_KO) $(INITRAMFS_MODULE_PATH)" "$(INITRAMFS_IMAGE)"; \
	"$(DEBUGFS)" -w -R "sif $(INITRAMFS_MODULE_PATH) mode 0100777" "$(INITRAMFS_IMAGE)" >/dev/null; \
	run_fsck; \
	echo "copied $(MODULE_KO) to $(INITRAMFS_MODULE_PATH) in $(INITRAMFS_IMAGE)"

copy-to-initramfs: launch
endif
