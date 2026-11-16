#!/bin/bash
# YS-A99 / ZM-A399SE - USB disk late-enumeration helper.
#
# 1) Stop fnOS diskpowerd from spinning the disk down through the flaky
#    JMicron JMS578 bridge (hdparm -S 0 -B 254).
# 2) Re-trigger udev so fnOS re-scans a disk that appeared late.
# 3) Mount fnOS storage-pool volumes (/volN) whose backing USB disk appeared
#    after boot. fnOS only mounts /volN during startup; on late arrival it
#    merely tries to mount /dev/sda1 as a plain external disk, which fails
#    with "unknown filesystem type 'linux_raid_member'".
#
# The LV -> /volN mapping is learned from /proc/mounts while the system is
# healthy and merged into a state file, so no volume UUIDs are hard-coded and
# the mount options stay exactly the ones fnOS uses
# (rw,relatime,trimacl,prjquota). Entries accumulate (a volume that is
# currently unmounted must not be forgotten). On a freshly flashed image the
# state file does not exist yet, so unseen volumes are paired on the fly.
#
# YS_A99_VOL_MAP / YS_A99_USB_LOG are overridable for offline testing.
# YS_A99_DRY_RUN=1 learns the map but does not mount anything.

LOG=${YS_A99_USB_LOG:-/var/log/ys-a99-usb-disk.log}
MAP=${YS_A99_VOL_MAP:-/var/lib/ys-a99-vol-map}
exec >>"$LOG" 2>&1
echo "=== $(date -Is) rescan triggered ==="

sleep 10
udevadm trigger --subsystem-match=block --action=change 2>/dev/null

# Assemble RAID/LVM before learning the map: on a late-arriving USB disk the
# LV may not exist until mdadm/vgchange have run. Both commands are idempotent
# and no-ops when the volumes are already active.
command -v mdadm    >/dev/null 2>&1 && mdadm --assemble --scan >/dev/null 2>&1 || true
command -v vgchange >/dev/null 2>&1 && vgchange -ay            >/dev/null 2>&1 || true
sleep 2

for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    if readlink -f "$d/device" 2>/dev/null | grep -q usb; then
        dev="/dev/$(basename "$d")"
        # -S 0: never enter standby on idle; -B 254: disable APM.
        # Covers fnOS diskpowerd, which otherwise sends STANDBY/CHECK POWER
        # MODE through the JMS578 bridge and can leave the link wedged.
        timeout 5 /usr/sbin/hdparm -S 0 -B 254 "$dev" >/dev/null 2>&1
        echo "apm/standby disabled on $dev (rc=$?)"
    fi
done

is_mounted() {
    mountpoint -q "$1" 2>/dev/null && return 0
    grep -Fq " $1 " /proc/mounts && return 0
    return 1
}

# --- learn / refresh the LV -> /volN mapping -------------------------------
# Live mounts take precedence; previously learned entries fill the gaps.
{
    while read -r src tgt fstype opts rest; do
        case "$tgt" in /vol[0-9]*) ;; *) continue ;; esac
        case "$src" in /dev/mapper/trim_*) ;; *) continue ;; esac
        echo "$src $tgt $fstype $opts"
    done < /proc/mounts
    [ -f "$MAP" ] && cat "$MAP"
} | awk 'NF && !seen[$2]++' > "${MAP}.tmp.$$"
mv -f "${MAP}.tmp.$$" "$MAP"
echo "vol map: $(wc -l < "$MAP") entries"

# --- discover volumes that were never seen mounted -------------------------
# A freshly flashed image has no state file. Only the unambiguous 1:1 case is
# auto-learned; with several unmounted LVs or /volN directories we log and
# leave it to fnOS rather than risk mounting the wrong volume in the wrong
# place. This also recovers when the state file only knows about some volumes.
# fnOS records the volumes it manages as "watched" targets in
# trim_file_monitor.conf. Prefer that list: /vol00 is an internal placeholder
# (mode 000) and must never be used as a volume mountpoint, and the directory
# of an unmounted /volN may not exist at all after a reboot.
map_targets() {
    if [ -r /usr/trim/etc/trim_file_monitor.conf ]; then
        grep -o '/vol[0-9][0-9]*' /usr/trim/etc/trim_file_monitor.conf \
            | grep -v '^/vol0' | sort -u
    else
        for vd in /vol[1-9]*; do [ -d "$vd" ] && echo "$vd"; done | sort -u
    fi
}

lvs=(); vols=()
for lv in /dev/mapper/trim_*-0; do
    [ -e "$lv" ] || continue
    grep -Fq "$lv " /proc/mounts && continue
    grep -Fq "$lv " "$MAP" 2>/dev/null && continue
    lvs+=("$lv")
done
for vd in $(map_targets); do
    is_mounted "$vd" && continue
    awk '{print $2}' "$MAP" 2>/dev/null | grep -Fxq "$vd" && continue
    vols+=("$vd")
done
if [ ${#lvs[@]} -eq 1 ] && [ ${#vols[@]} -eq 1 ]; then
    echo "${lvs[0]} ${vols[0]} ext4 rw,relatime,trimacl,prjquota" >> "$MAP"
    echo "vol map learned by pairing: ${lvs[0]} -> ${vols[0]}"
elif [ ${#lvs[@]} -gt 0 ] && [ ${#vols[@]} -gt 0 ]; then
    echo "vol map: ambiguous unmounted volumes (lvs=${#lvs[@]} vols=${#vols[@]}), leaving to fnOS"
else
    echo "vol map: no unambiguous new pair (lvs=${#lvs[@]} vols=${#vols[@]})"
fi
echo "vol map final: $(wc -l < "$MAP") entries"
while read -r src tgt fstype opts; do
    echo "  $tgt <- $src [$fstype $opts]"
done < "$MAP"

# --- late-arrival auto-mount ------------------------------------------------
# Skip the boot window: during startup fnOS mounts the volumes itself and we
# must not race with its init sequence.
uptime_s=$(awk '{print int($1)}' /proc/uptime)
if [ "$uptime_s" -lt 120 ]; then
    echo "boot window (uptime=${uptime_s}s), mounting left to fnOS"
elif [ "${YS_A99_DRY_RUN:-0}" = "1" ]; then
    echo "DRY RUN: would check/mount volumes from $MAP"
else
    while read -r src tgt fstype opts; do
        [ -n "$src" ] || continue
        if is_mounted "$tgt"; then
            echo "  $tgt: already mounted"
            continue
        fi
        if [ ! -e "$src" ]; then
            echo "  $tgt: backing device $src absent, skip"
            continue
        fi
        mkdir -p "$tgt"
        if mount -t "$fstype" -o "$opts" "$src" "$tgt"; then
            echo "  AUTO-MOUNTED $src -> $tgt ($fstype $opts)"
        elif mount -t "$fstype" -o rw,relatime "$src" "$tgt"; then
            echo "  AUTO-MOUNTED (fallback opts) $src -> $tgt"
        else
            echo "  AUTO-MOUNT FAILED $src -> $tgt"
        fi
    done < "$MAP"
fi

echo "--- block devices ---"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,TRAN,MODEL 2>&1
echo "--- kernel usb lines (tail) ---"
dmesg | grep -Ei "usb|uas|usb-storage|sd[a-z]" | tail -20
echo "=== done ==="
