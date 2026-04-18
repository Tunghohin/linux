#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
initramfs_dir="$repo_root/.initramfs"
work_dir="$initramfs_dir/rootfs"
busybox_dst="$initramfs_dir/bin/busybox"
busybox_src="${BUSYBOX_STATIC:-$busybox_dst}"
fallback_busybox="/tmp/codex-initramfs-fetch/unpack/usr/bin/busybox"
output_cpio="$initramfs_dir/initramfs.cpio"
output_gz="$initramfs_dir/initramfs.cpio.gz"

mkdir -p "$initramfs_dir/bin"

if [[ ! -x "$busybox_src" && "$busybox_src" == "$busybox_dst" && -x "$fallback_busybox" ]]; then
    install -m 0755 "$fallback_busybox" "$busybox_dst"
fi

if [[ ! -x "$busybox_src" ]]; then
    echo "missing static busybox: $busybox_src" >&2
    exit 1
fi

rm -rf "$work_dir"
mkdir -p \
    "$work_dir/bin" \
    "$work_dir/dev" \
    "$work_dir/proc" \
    "$work_dir/sys" \
    "$work_dir/tmp" \
    "$work_dir/root" \
    "$work_dir/sbin" \
    "$work_dir/usr/bin" \
    "$work_dir/usr/sbin"

install -m 0755 "$busybox_src" "$work_dir/bin/busybox"
install -m 0755 "$repo_root/tools/initramfs/init" "$work_dir/init"

for applet in sh mount mkdir mknod cat echo uname dmesg ls; do
    ln -sf /bin/busybox "$work_dir/bin/$applet"
done

list_file="$(mktemp)"
trap 'rm -f "$list_file"' EXIT

{
    echo "dir /dev 0755 0 0"
    echo "dir /proc 0555 0 0"
    echo "dir /sys 0555 0 0"
    echo "dir /tmp 1777 0 0"
    echo "dir /root 0700 0 0"
    echo "dir /bin 0755 0 0"
    echo "dir /sbin 0755 0 0"
    echo "dir /usr 0755 0 0"
    echo "dir /usr/bin 0755 0 0"
    echo "dir /usr/sbin 0755 0 0"
    echo "nod /dev/console 0600 0 0 c 5 1"
    echo "nod /dev/null 0666 0 0 c 1 3"
    find "$work_dir" -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort | while read -r path; do
        archive_path="${path#$work_dir}"
        if [[ -L "$path" ]]; then
            target="$(readlink "$path")"
            printf 'slink %s %s 0777 0 0\n' "$archive_path" "$target"
        else
            mode="$(stat -c '%a' "$path")"
            printf 'file %s %s %s 0 0\n' "$archive_path" "$path" "$mode"
        fi
    done
} > "$list_file"

"$repo_root/usr/gen_init_cpio" -o "$output_cpio" "$list_file"
gzip -n -f -9 "$output_cpio"

echo "wrote $output_gz"
