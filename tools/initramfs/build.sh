#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
initramfs_dir="${INITRAMFS_DIR:-$repo_root/.initramfs}"
rootfs_root="$initramfs_dir/rootfs"
busybox_root="$rootfs_root/busybox"
debian_root="$rootfs_root/debian"
debian_initramfs_root="$rootfs_root/debian-initramfs"
debootstrap_meta="$rootfs_root/debootstrap"
busybox_cache="$initramfs_dir/bin/busybox"
fallback_busybox="/tmp/codex-initramfs-fetch/unpack/usr/bin/busybox"
debian_disk_image="$initramfs_dir/rootfs-debian.ext4"
debian_disk_size_mb="${DEBIAN_ROOTFS_SIZE_MB:-2048}"

host_uid="$(id -u)"
host_gid="$(id -g)"
default_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

debian_arch="${DEBIAN_ARCH:-$default_arch}"
debian_suite="${DEBIAN_SUITE:-bookworm}"
debian_variant="${DEBIAN_VARIANT:-minbase}"
debian_mirror="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
debian_include="${DEBIAN_INCLUDE:-bash,iproute2,iputils-ping,procps,kmod,less,systemd-sysv,dbus,ca-certificates,debian-archive-keyring}"
force_prepare="${INITRAMFS_FORCE:-0}"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") busybox
  $(basename "$0") debian

Examples:
  $(basename "$0") busybox
  $(basename "$0") debian

Environment:
  INITRAMFS_DIR             Output directory, defaults to .initramfs
  INITRAMFS_FORCE=1         Recreate an existing rootfs
  BUSYBOX_STATIC            Path to a static busybox binary
  DEBIAN_ROOTFS_SIZE_MB     Debian ext4 rootfs image size in MiB, defaults to 2048
  DEBIAN_ARCH               Debian architecture, defaults to host arch
  DEBIAN_SUITE              Debian suite, defaults to bookworm
  DEBIAN_VARIANT            debootstrap variant, defaults to minbase
  DEBIAN_MIRROR             Debian mirror URL
  DEBIAN_INCLUDE            Extra packages for Debian rootfs
EOF
}

log() {
    printf '[initramfs] %s\n' "$*"
}

die() {
    printf '[initramfs] %s\n' "$*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

busybox_binary() {
    local busybox_src="${BUSYBOX_STATIC:-$busybox_cache}"

    mkdir -p "$(dirname "$busybox_cache")"

    if [[ ! -x "$busybox_src" && "$busybox_src" == "$busybox_cache" && -x "$fallback_busybox" ]]; then
        install -m 0755 "$fallback_busybox" "$busybox_cache"
    fi

    [[ -x "$busybox_src" ]] || die "missing static busybox: $busybox_src"
    printf '%s\n' "$busybox_src"
}

install_common_init() {
    local rootfs_dir="$1"
    local variant="$2"

    install -D -m 0755 "$repo_root/tools/initramfs/init" "$rootfs_dir/init"
    mkdir -p "$rootfs_dir/etc"
    ln -sfn /proc/self/mounts "$rootfs_dir/etc/mtab"
    printf '%s\n' "$variant" > "$rootfs_dir/etc/initramfs-variant"
}

install_busybox_applets() {
    local rootfs_dir="$1"
    local busybox_src="$2"
    local applet
    local applet_path

    while read -r applet; do
        [[ -n "$applet" ]] || continue
        applet_path="$rootfs_dir/$applet"
        mkdir -p "$(dirname "$applet_path")"

        if [[ "$applet" == "bin/busybox" ]]; then
            continue
        fi

        ln -sfn /bin/busybox "$applet_path"
    done < <("$busybox_src" --list-full)
}

remove_host_absolute_symlinks() {
    local rootfs_dir="$1"
    local path
    local target

    while IFS= read -r -d '' path; do
        target="$(readlink "$path")"
        case "$target" in
            "$rootfs_dir"/*|"$repo_root"/*)
                rm -f "$path"
                ;;
        esac
    done < <(find "$rootfs_dir" -type l -print0)
}

debian_rootfs_has_init() {
    local rootfs_dir="$1"
    local status_file="$rootfs_dir/var/lib/dpkg/status"

    if [[ -x "$rootfs_dir/lib/systemd/systemd" || -x "$rootfs_dir/usr/lib/systemd/systemd" ]]; then
        return 0
    fi

    if [[ -r "$status_file" ]] && grep -Eq '^Package: (systemd-sysv|sysvinit-core)$' "$status_file"; then
        return 0
    fi

    return 1
}

merge_directory_contents() {
    local src_dir="$1"
    local dst_dir="$2"
    local entry
    local name

    [[ -d "$src_dir" && ! -L "$src_dir" ]] || return 0

    mkdir -p "$dst_dir"

    while IFS= read -r -d '' entry; do
        name="${entry##*/}"

        if [[ -d "$entry" && ! -L "$entry" && -d "$dst_dir/$name" && ! -L "$dst_dir/$name" ]]; then
            merge_directory_contents "$entry" "$dst_dir/$name"
            rmdir "$entry" 2>/dev/null || true
            continue
        fi

        if [[ -e "$dst_dir/$name" || -L "$dst_dir/$name" ]]; then
            die "cannot merge $src_dir into $dst_dir: $name already exists"
        fi

        mv "$entry" "$dst_dir/$name"
    done < <(find "$src_dir" -mindepth 1 -maxdepth 1 -print0)
}

write_package_file_list() {
    local deb_path="$1"
    local list_path="$2"

    dpkg-deb --fsys-tarfile "$deb_path" \
        | tar -tf - \
        | awk '
            {
                sub(/^\.\//, "", $0)
                sub(/\/$/, "", $0)
                if ($0 == "")
                    next
                print "/" $0
            }
        ' > "$list_path"
}

ensure_root_usr_symlink() {
    local rootfs_dir="$1"
    local root_name="$2"
    local usr_name="$3"
    local src_dir="$rootfs_dir/$root_name"
    local dst_dir="$rootfs_dir/usr/$usr_name"

    if [[ -L "$src_dir" ]]; then
        return 0
    fi

    if [[ -d "$src_dir" ]]; then
        merge_directory_contents "$src_dir" "$dst_dir"
        rmdir "$src_dir" 2>/dev/null || die "failed to replace non-empty $src_dir with symlink"
    fi

    mkdir -p "$(dirname "$src_dir")" "$dst_dir"
    ln -sfn "usr/$usr_name" "$src_dir"
}

ensure_lib64_runtime_layout() {
    local rootfs_dir="$1"
    local compat_dir="$rootfs_dir/lib64"
    local merged_dir="$rootfs_dir/usr/lib64"

    if [[ -L "$compat_dir" ]]; then
        rm -f "$compat_dir"
        mkdir -p "$compat_dir"
        if [[ -d "$merged_dir" ]]; then
            merge_directory_contents "$merged_dir" "$compat_dir"
            rmdir "$merged_dir" 2>/dev/null || true
        fi
    elif [[ ! -e "$compat_dir" ]]; then
        mkdir -p "$compat_dir"
    fi
}

ensure_merged_usr_layout() {
    local rootfs_dir="$1"

    need_tool find
    need_tool ln
    need_tool mkdir
    need_tool mv
    need_tool rmdir

    ensure_root_usr_symlink "$rootfs_dir" bin bin
    ensure_root_usr_symlink "$rootfs_dir" sbin sbin
    ensure_root_usr_symlink "$rootfs_dir" lib lib
    ensure_lib64_runtime_layout "$rootfs_dir"
}

prepare_bootstrap_rootfs() {
    local rootfs_dir="$1"
    local variant="$2"
    local busybox_src

    need_tool install
    need_tool ln
    busybox_src="$(busybox_binary)"

    rm -rf "$rootfs_dir"
    mkdir -p \
        "$rootfs_dir/bin" \
        "$rootfs_dir/dev" \
        "$rootfs_dir/dev/pts" \
        "$rootfs_dir/etc" \
        "$rootfs_dir/mnt/rootfs" \
        "$rootfs_dir/proc" \
        "$rootfs_dir/root" \
        "$rootfs_dir/run" \
        "$rootfs_dir/sbin" \
        "$rootfs_dir/sys" \
        "$rootfs_dir/sys/fs/cgroup" \
        "$rootfs_dir/tmp" \
        "$rootfs_dir/usr/bin" \
        "$rootfs_dir/usr/sbin"

    install -m 0755 "$busybox_src" "$rootfs_dir/bin/busybox"
    remove_host_absolute_symlinks "$rootfs_dir"
    install_busybox_applets "$rootfs_dir" "$busybox_src"
    install_common_init "$rootfs_dir" "$variant"
    chmod 1777 "$rootfs_dir/tmp"
}

prepare_busybox_rootfs() {
    local rootfs_dir="$busybox_root"
    local busybox_src

    need_tool install
    need_tool ln
    busybox_src="$(busybox_binary)"

    if [[ -x "$rootfs_dir/init" && "$force_prepare" != "1" ]]; then
        log "reusing existing BusyBox rootfs: $rootfs_dir"
    else
        log "preparing BusyBox rootfs: $rootfs_dir"
        rm -rf "$rootfs_dir"
        mkdir -p \
            "$rootfs_dir/bin" \
            "$rootfs_dir/dev" \
            "$rootfs_dir/dev/pts" \
            "$rootfs_dir/etc" \
            "$rootfs_dir/home" \
            "$rootfs_dir/mnt" \
            "$rootfs_dir/proc" \
            "$rootfs_dir/root" \
            "$rootfs_dir/run" \
            "$rootfs_dir/sbin" \
            "$rootfs_dir/sys" \
            "$rootfs_dir/sys/fs/cgroup" \
            "$rootfs_dir/tmp" \
            "$rootfs_dir/usr/bin" \
            "$rootfs_dir/usr/sbin" \
            "$rootfs_dir/var/log"

        install -m 0755 "$busybox_src" "$rootfs_dir/bin/busybox"

        cat > "$rootfs_dir/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
        cat > "$rootfs_dir/etc/group" <<'EOF'
root:x:0:
tty:x:5:
EOF
        cat > "$rootfs_dir/etc/hostname" <<'EOF'
busybox-initramfs
EOF
        cat > "$rootfs_dir/etc/profile" <<'EOF'
export HOME=/root
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='(busybox-initramfs) \w # '
alias ll='ls -alF'
EOF
        cat > "$rootfs_dir/etc/motd" <<'EOF'
BusyBox initramfs rootfs
EOF
        chmod 1777 "$rootfs_dir/tmp"
    fi

    install -m 0755 "$busybox_src" "$rootfs_dir/bin/busybox"
    remove_host_absolute_symlinks "$rootfs_dir"
    install_busybox_applets "$rootfs_dir" "$busybox_src"
    install_common_init "$rootfs_dir" busybox
}

prepare_debian_rootfs() {
    local rootfs_dir="$debian_root"
    local cache_dir="$debootstrap_meta/cache"
    local work_dir="$debootstrap_meta/work"
    local control_dir="$debootstrap_meta/control"
    local debpaths_file="$debootstrap_meta/debpaths"
    local status_file
    local pkg_name
    local pkg_control_dir
    local control_file
    local info_file
    local debootstrap_cmd=()
    local ext4_blocks

    need_tool debootstrap
    need_tool dpkg-deb
    need_tool find
    need_tool awk
    need_tool cp
    need_tool fakeroot
    need_tool mkfs.ext4
    need_tool tar
    need_tool truncate

    if [[ -r "$rootfs_dir/etc/debian_version" && "$force_prepare" != "1" ]] && debian_rootfs_has_init "$rootfs_dir"; then
        log "reusing existing Debian rootfs: $rootfs_dir"
    else
        if [[ -r "$rootfs_dir/etc/debian_version" && "$force_prepare" != "1" ]]; then
            log "existing Debian rootfs has no usable init, rebuilding: $rootfs_dir"
        else
            log "preparing Debian rootfs: $rootfs_dir"
        fi
        rm -rf "$work_dir"
        rm -rf "$control_dir"
        rm -rf "$rootfs_dir"
        mkdir -p "$cache_dir"
        mkdir -p "$work_dir"
        mkdir -p "$control_dir"
        mkdir -p "$rootfs_dir"

        debootstrap_cmd=(
            debootstrap
            "--download-only"
            "--arch=$debian_arch"
            "--variant=$debian_variant"
            "--cache-dir=$cache_dir"
        )

        if [[ ! -r /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
            debootstrap_cmd+=("--no-check-gpg")
        fi

        if [[ -n "$debian_include" ]]; then
            debootstrap_cmd+=("--include=$debian_include")
        fi

        debootstrap_cmd+=("$debian_suite" "$work_dir" "$debian_mirror")

        "${debootstrap_cmd[@]}"

        find "$cache_dir" -type f -name '*.deb' | LC_ALL=C sort > "$debpaths_file"
        [[ -s "$debpaths_file" ]] || die "no Debian packages were downloaded into $cache_dir"

        while read -r deb_path; do
            [[ -n "$deb_path" ]] || continue
            dpkg-deb -x "$deb_path" "$rootfs_dir"
        done < "$debpaths_file"

        mkdir -p \
            "$rootfs_dir/var/lib/dpkg/info" \
            "$rootfs_dir/var/lib/dpkg/updates" \
            "$rootfs_dir/var/lib/dpkg/parts" \
            "$rootfs_dir/var/lib/dpkg/triggers" \
            "$rootfs_dir/var/lib/apt/lists/partial" \
            "$rootfs_dir/var/cache/apt/archives/partial"
        printf '%s\n' "$debian_arch" > "$rootfs_dir/var/lib/dpkg/arch"
        : > "$rootfs_dir/var/lib/dpkg/available"
        : > "$rootfs_dir/var/lib/dpkg/status"
        status_file="$rootfs_dir/var/lib/dpkg/status"

        while read -r deb_path; do
            [[ -n "$deb_path" ]] || continue
            pkg_name="$(dpkg-deb -f "$deb_path" Package 2>/dev/null || true)"
            [[ -n "$pkg_name" ]] || continue

            pkg_control_dir="$control_dir/$pkg_name"
            rm -rf "$pkg_control_dir"
            mkdir -p "$pkg_control_dir"
            dpkg-deb -e "$deb_path" "$pkg_control_dir"

            control_file="$pkg_control_dir/control"
            if [[ -f "$control_file" ]]; then
                awk '
                    BEGIN { inserted = 0 }
                    /^Package:/ && !inserted {
                        print
                        print "Status: install ok unpacked"
                        inserted = 1
                        next
                    }
                    { print }
                    END {
                        if (!inserted)
                            print "Status: install ok unpacked"
                    }
                ' "$control_file" >> "$status_file"
                printf '\n' >> "$status_file"
            fi

            for info_file in "$pkg_control_dir"/*; do
                [[ -f "$info_file" ]] || continue
                cp "$info_file" "$rootfs_dir/var/lib/dpkg/info/${pkg_name}.$(basename "$info_file")"
            done

            write_package_file_list "$deb_path" "$rootfs_dir/var/lib/dpkg/info/${pkg_name}.list"
        done < "$debpaths_file"
    fi

    ensure_merged_usr_layout "$rootfs_dir"

    mkdir -p \
        "$rootfs_dir/dev/hugepages" \
        "$rootfs_dir/dev/mqueue" \
        "$rootfs_dir/dev/pts" \
        "$rootfs_dir/proc" \
        "$rootfs_dir/root" \
        "$rootfs_dir/run" \
        "$rootfs_dir/sys/kernel/debug" \
        "$rootfs_dir/sys/kernel/tracing" \
        "$rootfs_dir/sys/fs/cgroup" \
        "$rootfs_dir/mnt/rootfs" \
        "$rootfs_dir/tmp"
    chmod 1777 "$rootfs_dir/tmp"

    mkdir -p "$rootfs_dir/etc/apt"
    cat > "$rootfs_dir/etc/hostname" <<'EOF'
debian-rootfs
EOF
    cat > "$rootfs_dir/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 debian-rootfs
EOF
    cat > "$rootfs_dir/etc/resolv.conf" <<'EOF'
nameserver 10.0.2.3
nameserver 8.8.8.8
EOF
    mkdir -p "$rootfs_dir/usr/share/keyrings" "$rootfs_dir/etc/ssl/certs"
    if [[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
        install -m 0644 /usr/share/keyrings/debian-archive-keyring.gpg \
            "$rootfs_dir/usr/share/keyrings/debian-archive-keyring.gpg"
    fi
    if [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
        install -m 0644 /etc/ssl/certs/ca-certificates.crt \
            "$rootfs_dir/etc/ssl/certs/ca-certificates.crt"
    fi
    cat > "$rootfs_dir/etc/apt/sources.list" <<'EOF'
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm-updates main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://security.debian.org/debian-security bookworm-security main
EOF
    install -D -m 0755 /dev/null "$rootfs_dir/usr/local/sbin/configure-eth0"
    cat > "$rootfs_dir/usr/local/sbin/configure-eth0" <<'EOF'
#!/bin/sh

set -eu

for _ in $(seq 1 30); do
    if [ -d /sys/class/net/eth0 ]; then
        break
    fi
    sleep 1
done

[ -d /sys/class/net/eth0 ] || exit 1

ip link set dev eth0 up
ip addr replace 10.0.2.15/24 dev eth0
ip route replace default via 10.0.2.2 dev eth0
EOF
    if [[ ! -e "$rootfs_dir/etc/passwd" ]]; then
        cat > "$rootfs_dir/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF
    fi
    if [[ ! -e "$rootfs_dir/etc/group" ]]; then
        cat > "$rootfs_dir/etc/group" <<'EOF'
root:x:0:
tty:x:5:
EOF
    fi
    if [[ ! -e "$rootfs_dir/etc/gshadow" ]]; then
        cat > "$rootfs_dir/etc/gshadow" <<'EOF'
root:*::
tty:*::
EOF
        chmod 0600 "$rootfs_dir/etc/gshadow"
    fi
    if [[ ! -e "$rootfs_dir/etc/shadow" ]]; then
        cat > "$rootfs_dir/etc/shadow" <<'EOF'
root:*:19793:0:99999:7:::
EOF
        chmod 0600 "$rootfs_dir/etc/shadow"
    fi
    mkdir -p "$rootfs_dir/root"
    cat > "$rootfs_dir/root/.profile" <<'EOF'
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='root@debian-rootfs:\w# '
EOF

    : > "$rootfs_dir/etc/machine-id"

    rm -rf "$rootfs_dir/etc/systemd/system/serial-getty@ttyS0.service.d"
    rm -f \
        "$rootfs_dir/etc/systemd/system/multi-user.target.wants/eth0-static.service" \
        "$rootfs_dir/etc/systemd/system/getty.target.wants/ttyS0-autologin.service" \
        "$rootfs_dir/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" \
        "$rootfs_dir/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
        "$rootfs_dir/etc/systemd/system/ttyS0-root-shell.service" \
        "$rootfs_dir/etc/systemd/system/serial-getty@ttyS0.service"
    mkdir -p \
        "$rootfs_dir/etc/systemd/system" \
        "$rootfs_dir/etc/systemd/system/getty.target.wants" \
        "$rootfs_dir/etc/systemd/system/multi-user.target.wants"
    cat > "$rootfs_dir/etc/systemd/system/eth0-static.service" <<'EOF'
[Unit]
Description=Configure eth0 static network
After=systemd-modules-load.service
After=local-fs.target
ConditionPathExists=/sys/class/net/eth0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/configure-eth0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    cat > "$rootfs_dir/etc/systemd/system/ttyS0-root-shell.service" <<'EOF'
[Unit]
Description=Root shell on ttyS0
After=systemd-user-sessions.service
After=systemd-logind.service
IgnoreOnIsolate=yes

[Service]
Type=simple
Environment=HOME=/root
Environment=USER=root
Environment=LOGNAME=root
Environment=SHELL=/bin/bash
Environment=TERM=vt220
WorkingDirectory=/root
ExecStart=-/bin/bash -l
Restart=always
RestartSec=0
TTYPath=/dev/ttyS0
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=no
StandardInput=tty-force
StandardOutput=tty
StandardError=tty

[Install]
WantedBy=getty.target
EOF
    ln -sfn ../eth0-static.service "$rootfs_dir/etc/systemd/system/multi-user.target.wants/eth0-static.service"
    ln -sfn ../ttyS0-root-shell.service "$rootfs_dir/etc/systemd/system/getty.target.wants/ttyS0-root-shell.service"
    ln -sfn /dev/null "$rootfs_dir/etc/systemd/system/serial-getty@ttyS0.service"

    install_common_init "$rootfs_dir" debian-rootfs

    mkdir -p "$debootstrap_meta"
    find "$cache_dir" -type f -name '*.deb' | LC_ALL=C sort > "$debpaths_file"

    while read -r deb_path; do
        [[ -n "$deb_path" ]] || continue
        pkg_name="$(dpkg-deb -f "$deb_path" Package 2>/dev/null || true)"
        [[ -n "$pkg_name" ]] || continue
        write_package_file_list "$deb_path" "$rootfs_dir/var/lib/dpkg/info/${pkg_name}.list"
    done < "$debpaths_file"

    # Carry the package index cache into the rootfs so apt can resolve packages
    # immediately even before the first "apt update" in the guest.
    if [[ -d "$work_dir/var/lib/apt/lists" ]]; then
        mkdir -p "$rootfs_dir/var/lib/apt"
        rm -rf "$rootfs_dir/var/lib/apt/lists"
        cp -a "$work_dir/var/lib/apt/lists" "$rootfs_dir/var/lib/apt/"
    fi
    if [[ -d "$work_dir/var/cache/apt/archives" ]]; then
        mkdir -p "$rootfs_dir/var/cache/apt"
        rm -rf "$rootfs_dir/var/cache/apt/archives"
        cp -a "$work_dir/var/cache/apt/archives" "$rootfs_dir/var/cache/apt/"
    fi

    truncate -s "${debian_disk_size_mb}M" "$debian_disk_image"
    ext4_blocks=$((debian_disk_size_mb * 1024))
    fakeroot -- \
        mkfs.ext4 -F -d "$rootfs_dir" -L debian-rootfs "$debian_disk_image" "$ext4_blocks" >/dev/null
    log "wrote $debian_disk_image"

    prepare_bootstrap_rootfs "$debian_initramfs_root" debian
}

variant_rootfs_dir() {
    case "$1" in
        busybox) printf '%s\n' "$busybox_root" ;;
        debian) printf '%s\n' "$debian_initramfs_root" ;;
        *) die "unsupported variant: $1" ;;
    esac
}

pack_variant() {
    local variant="$1"
    local rootfs_dir
    local list_file
    local output_cpio
    local output_gz

    need_tool gzip

    rootfs_dir="$(variant_rootfs_dir "$variant")"
    [[ -x "$rootfs_dir/init" ]] || die "rootfs is not prepared: $rootfs_dir"

    install_common_init "$rootfs_dir" "$variant"

    mkdir -p "$initramfs_dir"
    list_file="$(mktemp "$initramfs_dir/.${variant}.cpio.list.XXXXXX")"
    output_cpio="$initramfs_dir/initramfs.cpio"
    output_gz="$initramfs_dir/initramfs.cpio.gz"

    cat > "$list_file" <<'EOF'
dir /dev 0755 0 0
dir /dev/pts 0755 0 0
dir /proc 0555 0 0
dir /run 0755 0 0
dir /sys 0555 0 0
dir /sys/fs 0755 0 0
dir /sys/fs/cgroup 0755 0 0
dir /tmp 1777 0 0
dir /root 0700 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/ptmx 0666 0 0 c 5 2
nod /dev/tty 0666 0 0 c 5 0
nod /dev/ttyS0 0600 0 0 c 4 64
EOF

    "$repo_root/usr/gen_initramfs.sh" \
        -o "$output_cpio" \
        -u "$host_uid" \
        -g "$host_gid" \
        "$list_file" \
        "$rootfs_dir"

    gzip -n -9 -c "$output_cpio" > "$output_gz"
    rm -f "$list_file"

    log "wrote $output_gz"
}

prepare_variant() {
    case "$1" in
        busybox) prepare_busybox_rootfs ;;
        debian) prepare_debian_rootfs ;;
        *) die "unsupported variant: $1" ;;
    esac
}

main() {
    local variant="${1:-}"

    case "$variant" in
        -h|--help|'')
            usage
            exit 0
            ;;
        busybox|debian)
            ;;
        *)
            usage >&2
            die "unsupported variant: $variant"
            ;;
    esac

    mkdir -p "$initramfs_dir" "$rootfs_root" "$debootstrap_meta"
    prepare_variant "$variant"
    pack_variant "$variant"
}

main "$@"
