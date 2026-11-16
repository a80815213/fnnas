# YS-A99 / ZM-A399SE —— USB 硬盘掉盘与自动挂载修复说明

本镜像已内置该修复，**刷完开机即生效**，不需要再手工改 `/boot/armbianEnv.txt`、装 udev 规则或手动挂载。

## 问题与根因

YS-A99 只有一个 USB3.0 口，常见搭配是 JMicron JMS578（`152d:0578`）硬盘盒。该桥片的 UAS 固件不稳定：运行一段时间后会 `uas_eh_device_reset_handler` → `reset SuperSpeed USB device` → `USB disconnect`，并伴随 `lost sync page write`（写入丢失）。飞牛的 `trim_diskpowerd` 还会通过桥片发 STANDBY / CHECK POWER MODE，进一步加剧问题。

第二个现象是「认到盘但不自动挂载」：这类盘往往是飞牛的存储池卷（`/dev/sda1` → `mdadm` 单盘 RAID → LVM → ext4 → `/volN`），盘晚到时 `extdev_service` 把它当普通外接盘试挂，报 `unknown filesystem type 'linux_raid_member'`，而 fnOS 只在开机阶段挂载 `/volN`。

## 镜像里有什么

| 路径 | 作用 |
| ---- | ---- |
| `/boot/armbianEnv.txt` | `usbstoragequirks=...,0x152d:0x0578:u` 禁用 JMS578 的 UAS（改走 `usb-storage` BOT）；`extraargs` 增加 `usbcore.autosuspend=-1` 关闭 USB 自动挂起。两者经 `boot.cmd` 进入内核 cmdline。 |
| `/etc/udev/rules.d/98-ys-a99-usb-disk.rules` | 对该桥片关闭 runtime PM；`sd*` 盘出现时触发 rescan 服务。 |
| `/usr/local/lib/ys-a99/usb-keepawake.sh` | udev 调用，把 USB 设备 `power/control` 置 `on`、`autosuspend` 置 `-1`。 |
| `/etc/systemd/system/ys-a99-usb-rescan.service` | oneshot 单元，由 udev 规则按需触发（`After=trim_init.service`）。 |
| `/usr/local/sbin/ys-a99-usb-rescan.sh` | 重发 udev block change、对 USB 盘执行 `hdparm -S 0 -B 254` 阻止休眠、组装 mdadm/LVM，并在盘晚到时按 fnOS 原挂载选项自动挂载 `/volN`。 |
| `/usr/local/sbin/ys-a99-usb-check.sh` | 只读自检脚本。 |

`ys-a99-usb-rescan.sh` 的工作方式：

1. 从 `/proc/mounts` 学习 `LV -> /volN` 及原始挂载选项（`rw,relatime,trimacl,prjquota`），累积写入 `/var/lib/ys-a99-vol-map`；不硬编码任何卷 UUID。
2. 新刷的镜像没有这个状态文件，因此会用飞牛 `/usr/trim/etc/trim_file_monitor.conf` 里的卷清单，把「唯一未挂载的 LV」与「唯一未挂载的 `/volN`」配对；`/vol00` 是飞牛占位目录，不会被误用。多卷无法唯一配对时只记日志、交给 fnOS，避免挂错。
3. 开机 120 秒内不抢挂载，交给 fnOS；运行期盘晚到才执行 `mdadm --assemble --scan` + `vgchange -ay` + `mount`。
4. `YS_A99_DRY_RUN=1`、`YS_A99_VOL_MAP=...`、`YS_A99_USB_LOG=...` 可用于离线验证。

## 刷机后自检

```bash
sudo ys-a99-usb-check.sh

# 关键输出
grep -o "usb-storage.quirks=[^ ]*" /proc/cmdline     # 应含 152d:0578:u 和 usbcore.autosuspend=-1
dmesg | grep -E "UAS is ignored|Quirks match|scsi host[0-9]+: usb-storage"
cat /var/lib/ys-a99-vol-map                          # LV -> /volN
findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS | grep '/vol'
tail -40 /var/log/ys-a99-usb-disk.log
```

期望：`lsusb -t` 里硬盘是 `Driver=usb-storage, 5000M`（不是 `uas`）；本次开机 `reset SuperSpeed / USB disconnect / lost sync / uas_eh` 计数为 0；所有 `/volN` 正常挂载。

## 手动干预 / 回退

```bash
# 只检查不挂载
sudo YS_A99_DRY_RUN=1 /usr/local/sbin/ys-a99-usb-rescan.sh

# 临时恢复 UAS（不推荐，仅用于排查）：编辑 /boot/armbianEnv.txt，
# 从 usbstoragequirks 去掉 0x152d:0x0578:u，然后重启
sudo nano /boot/armbianEnv.txt && sudo reboot
```

## 适用范围

UAS quirk 只针对 `152d:0578`。若换用其他桥片又出现类似掉盘，把该设备的 `vid:pid:u` 追加到 `/boot/armbianEnv.txt` 的 `usbstoragequirks` 即可；runtime PM、休眠禁用和 `/volN` 自动挂载逻辑对所有 USB 盘通用。

真机验证：2026-11-09 ~ 11-16 连续运行近 7 天无掉盘、无复位；热插拔后 `scsi host0: usb-storage`，插入 11 分钟内错误计数 0；用 loop 设备模拟晚到卷，自动挂载分支通过。
