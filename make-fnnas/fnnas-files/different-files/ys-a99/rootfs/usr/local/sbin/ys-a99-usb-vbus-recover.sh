#!/bin/bash
# YS-A99 / ZM-A399SE - software VBUS power-cycle for a wedged JMS578 bridge.
#
# Symptom this fixes
# ------------------
# After a SOFT reboot (fnOS/system upgrade, `reboot`, ...), the external USB
# disk sometimes does not enumerate at all: `lsusb` shows only root hubs, there
# is no 152d:0578, no /dev/sda, and no /vol2. dmesg contains no reset/disconnect
# errors - the JMicron JMS578 bridge never came up. The bridge is powered from
# vcc5v0_host, which stays high across a soft reboot, so its firmware stays
# wedged. A physical power-off / unplug fixes it; so does cycling VBUS.
#
# What this does
# --------------
# vcc5v0_host is a regulator-fixed device driven by GPIO4_D2 (global GPIO 154)
# on RK3399. We unbind the regulator to release the GPIO, drive it low for 3s,
# drive it high again, then rebind. The freshly enumerated disk raises a udev
# add event, which triggers 98-ys-a99-usb-disk.rules ->
# ys-a99-usb-rescan.service, which reassembles mdadm/LVM and mounts /volN.
#
# Safety guards
# -------------
#   * no-op when the JMS578 is already enumerated
#   * no-op when fnOS has no external storage pool configured
#   * runs once per boot, after fnOS storage init has settled (uptime >= 180s)
#     so it never races the 120s boot window in ys-a99-usb-rescan.sh
#   * always leaves the regulator bound and VBUS high, even on error
#   * YS_A99_NO_WAIT=1 skips the boot wait (for manual runs/tests)
#   * YS_A99_VBUS_SIMULATE=1 stops just before touching hardware (diagnostics)
#   * YS_A99_USB_VID / YS_A99_USB_PID override the bridge ID (tests)
#   * YS_A99_VBUS_LOG overrides the log path
#
# Note: rebinding the regulator after boot makes the kernel log
# "Failed to create device link with supplier vcc5v0-host-regulator" for the
# two usb2phy host ports. This is a device-link bookkeeping warning; VBUS stays
# enabled and USB works normally (verified on hardware 2026-11-16).
# ---------------------------------------------------------------------------

LOG=${YS_A99_VBUS_LOG:-/var/log/ys-a99-usb-vbus.log}
exec >>"$LOG" 2>&1
echo "=== $(date -Is) vbus-recovery check ==="

VBUS_DEV=vcc5v0-host-regulator
VBUS_DRV=/sys/bus/platform/drivers/reg-fixed-voltage
GPIO=154
VID=${YS_A99_USB_VID:-152d}
PID=${YS_A99_USB_PID:-0578}
MIN_UPTIME=180
HOLD_S=3

# Do not block the boot target: this service is Type=simple, so systemd only
# waits for the process to start, not for this sleep to finish.
if [ "${YS_A99_NO_WAIT:-0}" != "1" ]; then
    up=$(awk '{print int($1)}' /proc/uptime)
    if [ "$up" -lt "$MIN_UPTIME" ]; then
        echo "waiting $((MIN_UPTIME-up))s for fnOS storage init (uptime=${up}s)"
        sleep $((MIN_UPTIME-up))
    fi
fi
echo "uptime=$(awk '{print int($1)}' /proc/uptime)s"

bridge_present() {
    for d in /sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "$VID" ] || continue
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$PID" ] || continue
        return 0
    done
    return 1
}

# fnOS lists every storage pool it manages as a "watched" /volN target.
# More than one volume means an external pool was configured. /vol00 is an
# internal placeholder and is excluded.
external_volume_expected() {
    if [ -r /usr/trim/etc/trim_file_monitor.conf ]; then
        n=$(grep -o '/vol[0-9][0-9]*' /usr/trim/etc/trim_file_monitor.conf \
            | grep -v '^/vol00' | sort -u | wc -l)
        [ "$n" -gt 1 ] && return 0
    fi
    [ -r /var/lib/ys-a99-vol-map ] && [ "$(wc -l < /var/lib/ys-a99-vol-map)" -gt 1 ] && return 0
    return 1
}

if bridge_present; then
    echo "JMS578 already enumerated, nothing to do"
    echo "=== done ==="
    exit 0
fi
if ! external_volume_expected; then
    echo "no external storage pool configured, skipping power cycle"
    echo "=== done ==="
    exit 0
fi

echo "JMS578 missing but an external pool is configured -> VBUS power cycle"
if [ "${YS_A99_VBUS_SIMULATE:-0}" = "1" ]; then
    echo "SIMULATE: would unbind $VBUS_DEV, hold GPIO $GPIO low ${HOLD_S}s, rebind; no hardware touched"
    echo "=== done ==="
    exit 0
fi

# Validate the platform layout before touching anything.
if [ ! -d "$VBUS_DRV" ] || [ ! -e "$VBUS_DRV/$VBUS_DEV" ]; then
    echo "ERROR: $VBUS_DRV/$VBUS_DEV not found, aborting"
    echo "=== done ==="
    exit 1
fi
rname=""
for r in /sys/class/regulator/regulator.*; do
    [ "$(cat "$r/name" 2>/dev/null)" = "vcc5v0_host" ] && rname=$(basename "$r")
done
if [ -z "$rname" ]; then
    echo "ERROR: vcc5v0_host regulator not found, aborting"
    echo "=== done ==="
    exit 1
fi
if [ ! -e /sys/class/gpio/gpiochip128 ]; then
    echo "ERROR: unexpected GPIO chip layout (gpiochip128 missing), aborting"
    echo "=== done ==="
    exit 1
fi
echo "regulator=$rname state=$(cat /sys/class/regulator/$rname/state 2>/dev/null)"

restore() {
    # Always leave VBUS high and the regulator bound.
    if [ -d /sys/class/gpio/gpio$GPIO ]; then
        hi=1
        [ "$(cat /sys/class/gpio/gpio$GPIO/active_low 2>/dev/null)" = "1" ] && hi=0
        echo "$hi" > /sys/class/gpio/gpio$GPIO/value 2>/dev/null || true
        echo "$GPIO" > /sys/class/gpio/unexport 2>/dev/null || true
    fi
    if [ ! -e "$VBUS_DRV/$VBUS_DEV" ]; then
        printf '%s' "$VBUS_DEV" > "$VBUS_DRV/bind" 2>/dev/null || true
        echo "restored regulator binding"
    fi
}
trap restore EXIT

printf '%s' "$VBUS_DEV" > "$VBUS_DRV/unbind" 2>&1
rc=$?
echo "unbind rc=$rc"
if [ "$rc" -ne 0 ]; then
    echo "ERROR: unbind failed, aborting"
    echo "=== done ==="
    exit 1
fi
sleep 1

exported=0
if [ ! -d /sys/class/gpio/gpio$GPIO ]; then
    echo "$GPIO" > /sys/class/gpio/export 2>&1
    [ -d /sys/class/gpio/gpio$GPIO ] && exported=1
fi
if [ -d /sys/class/gpio/gpio$GPIO ]; then
    G=/sys/class/gpio/gpio$GPIO
    low=0; high=1
    if [ "$(cat "$G/active_low" 2>/dev/null)" = "1" ]; then low=1; high=0; fi
    echo "gpio before: direction=$(cat "$G/direction" 2>/dev/null) value=$(cat "$G/value" 2>/dev/null) active_low=$(cat "$G/active_low" 2>/dev/null)"
    echo out > "$G/direction" 2>/dev/null
    echo "$low" > "$G/value" 2>&1
    echo "VBUS LOW for ${HOLD_S}s"
    sleep "$HOLD_S"
    echo "$high" > "$G/value" 2>&1
    echo "VBUS HIGH (value=$(cat "$G/value" 2>/dev/null))"
    if [ "$exported" = "1" ]; then
        echo "$GPIO" > /sys/class/gpio/unexport 2>/dev/null
    fi
else
    echo "GPIO not exportable; unbind/rebind alone toggles VBUS"
    sleep "$HOLD_S"
fi

printf '%s' "$VBUS_DEV" > "$VBUS_DRV/bind" 2>&1
echo "bind rc=$?"
sleep 12
restore
trap - EXIT

if bridge_present; then
    echo "RECOVERED: JMS578 enumerated; udev rescan will mount /volN"
else
    echo "FAILED: JMS578 still absent after power cycle (may need a physical power-off)"
fi
echo "--- lsusb ---"
lsusb 2>/dev/null
echo "=== done ==="
