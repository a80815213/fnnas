#!/bin/sh
# YS-A99: keep the USB link of JMicron JMS578 bridges awake.
# Called from udev with %p (sysfs devpath, e.g. /devices/platform/.../usb2/2-1).
p="/sys$1"
[ -d "$p/power" ] || exit 0
echo -1 > "$p/power/autosuspend" 2>/dev/null
echo on  > "$p/power/control" 2>/dev/null
exit 0
