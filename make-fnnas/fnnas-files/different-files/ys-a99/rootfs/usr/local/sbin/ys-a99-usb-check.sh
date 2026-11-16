#!/bin/bash
# YS-A99 USB disk health check. Read-only except for writing this report.
echo "========== YS-A99 USB disk check  $(date -Is) =========="
echo
echo "[1] boot parameters"
grep -E "^(usbstoragequirks|extraargs|extraboardargs)=" /boot/armbianEnv.txt 2>/dev/null
echo -n "live cmdline quirk: "; grep -o "usb-storage.quirks=[^ ]*" /proc/cmdline
echo -n "usbcore.autosuspend (module) = "; cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null
echo
echo "[2] USB devices"
lsusb -t 2>&1
echo
echo "[3] block devices"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,TRAN,MODEL,SERIAL 2>&1
echo
echo "[4] storage driver in use (want usb-storage, NOT uas)"
dmesg | grep -Ei "scsi host[0-9]+: (uas|usb-storage)|UAS is ignored|Quirks match|USB disconnect|reset SuperSpeed|device descriptor" | tail -25
echo
echo "[5] USB runtime PM of all USB devices (want control=on, autosuspend=-1)"
for c in /sys/bus/usb/devices/*/power/control; do
    [ -f "$c" ] || continue
    pd=$(dirname "$c")
    n=$(basename "$(dirname "$pd")")
    printf "  %-12s control=%-6s autosuspend=%s\n" "$n" "$(cat "$c" 2>/dev/null)" "$(cat "$pd/autosuspend" 2>/dev/null)"
done
echo
echo "[6] disk power management"
for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    dev="/dev/$(basename "$d")"
    echo "  --- $dev"
    timeout 5 /usr/sbin/hdparm -B "$dev" 2>&1 | grep -Ei "APM_level|HDIO|bad|failed" | head -3
    timeout 5 /usr/sbin/hdparm -C "$dev" 2>&1 | grep -Ei "drive state|HDIO|bad|failed" | head -3
done
echo
echo "[7] error counters in /var/log/syslog (all history)"
for k in "USB disconnect" "reset SuperSpeed" "lost sync" "Can't open blockdev" "I/O error"; do
    printf "  %-24s %s\n" "$k" "$(grep -c "$k" /var/log/syslog 2>/dev/null)"
done
printf "  %-24s %s\n" "(this boot, dmesg)" "$(dmesg | grep -cE 'reset SuperSpeed|USB disconnect, device number [2-9]|lost sync|uas_eh')"
echo
echo "[8] fnOS external disk info"
cat /usr/trim/var/share_service/ext_disk_info.json 2>/dev/null; echo
echo
echo "[9] recent rescan log (auto-mount lines)"
grep -E "rescan triggered|vol map|AUTO-MOUNT|already mounted|absent|boot window|apm/standby" /var/log/ys-a99-usb-disk.log 2>/dev/null | tail -14 || echo "(none yet)"
echo
echo "[10] fnOS storage volumes / late-arrival automount"
if [ -f /var/lib/ys-a99-vol-map ]; then
    echo "  learned LV -> mountpoint map:"
    sed 's/^/    /' /var/lib/ys-a99-vol-map
else
    echo "  (no vol map learned yet)"
fi
echo "  live /volN mounts:"
findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | awk '$1 ~ /^\/vol[0-9]+$/ {print}' | sed 's/^/    /' || echo "    (none)"
echo "========== end =========="
