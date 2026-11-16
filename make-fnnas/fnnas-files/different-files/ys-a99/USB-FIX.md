# YS-A99 / ZM-A399SE —— USB 硬盘掉盘与自动挂载修复说明

本镜像已内置该修复，**刷完开机即生效**，不需要再手工改 `/boot/armbianEnv.txt`、装 udev 规则或手动挂载。

## 问题与根因

YS-A99 只有一个 USB3.0 口，常见搭配是 JMicron JMS578（`152d:0578`）硬盘盒。该桥片的 UAS 固件不稳定：运行一段时间后会 `uas_eh_device_reset_handler` → `reset SuperSpeed USB device` → `USB disconnect`，并伴随 `lost sync page write`（写入丢失）。飞牛的 `trim_diskpowerd` 还会通过桥片发 STANDBY / CHECK POWER MODE，进一步加剧问题。

第二个现象是「认到盘但不自动挂载」：这类盘往往是飞牛的存储池卷（`/dev/sda1` → `mdadm` 单盘 RAID → LVM → ext4 → `/volN`），盘晚到时 `extdev_service` 把它当普通外接盘试挂，报 `unknown filesystem type 'linux_raid_member'`，而 fnOS 只在开机阶段挂载 `/volN`。

第三个现象是「软重启 / 系统升级后整块盘消失」：此时 `lsusb` 只剩 root hub，没有 `152d:0578`，没有 `/dev/sda`，dmesg 里也 **没有** 任何 reset/disconnect 错误——桥片根本没枚举。原因是 USB 口 5V（`vcc5v0_host`）在软重启期间不断电，JMS578 固件卡死在旧状态，必须让 VBUS 掉一次电才能重新上电枚举。物理断电 30 秒或重插 USB 线能解决，本镜像现在用软件自动完成。

## 镜像里有什么

| 路径 | 作用 |
| ---- | ---- |
| `/boot/armbianEnv.txt` | `usbstoragequirks=...,0x152d:0x0578:u` 禁用 JMS578 的 UAS（改走 `usb-storage` BOT）；`extraargs` 增加 `usbcore.autosuspend=-1` 关闭 USB 自动挂起。两者经 `boot.cmd` 进入内核 cmdline。 |
| `/etc/udev/rules.d/98-ys-a99-usb-disk.rules` | 对该桥片关闭 runtime PM；`sd*` 盘出现时触发 rescan 服务。 |
| `/usr/local/lib/ys-a99/usb-keepawake.sh` | udev 调用，把 USB 设备 `power/control` 置 `on`、`autosuspend` 置 `-1`。 |
| `/etc/systemd/system/ys-a99-usb-rescan.service` | oneshot 单元，由 udev 规则按需触发（`After=trim_init.service`）。 |
| `/usr/local/sbin/ys-a99-usb-rescan.sh` | 重发 udev block change、对 USB 盘执行 `hdparm -S 0 -B 254` 阻止休眠、组装 mdadm/LVM，并在盘晚到时按 fnOS 原挂载选项自动挂载 `/volN`。 |
| `/etc/systemd/system/ys-a99-usb-vbus-recover.service` | 开机自愈单元（multi-user.target.wants 启用），开机约 180 秒后检查桥片是否上线。 |
| `/usr/local/sbin/ys-a99-usb-vbus-recover.sh` | 若桥片未上线且 fnOS 配了外置存储池，就对 `vcc5v0_host` 做一次软件 VBUS 断电/上电，让桥片重新枚举。 |
| `/usr/local/sbin/ys-a99-usb-check.sh` | 只读自检脚本。 |

`ys-a99-usb-rescan.sh` 的工作方式：

1. 从 `/proc/mounts` 学习 `LV -> /volN` 及原始挂载选项（`rw,relatime,trimacl,prjquota`），累积写入 `/var/lib/ys-a99-vol-map`；不硬编码任何卷 UUID。
2. 新刷的镜像没有这个状态文件，因此会用飞牛 `/usr/trim/etc/trim_file_monitor.conf` 里的卷清单，把「唯一未挂载的 LV」与「唯一未挂载的 `/volN`」配对；`/vol00` 是飞牛占位目录，不会被误用。多卷无法唯一配对时只记日志、交给 fnOS，避免挂错。
3. 开机 120 秒内不抢挂载，交给 fnOS；运行期盘晚到才执行 `mdadm --assemble --scan` + `vgchange -ay` + `mount`。
4. `YS_A99_DRY_RUN=1`、`YS_A99_VOL_MAP=...`、`YS_A99_USB_LOG=...` 可用于离线验证。

## 开机自愈：软件 VBUS 断电

`vcc5v0_host` 是 RK3399 上由 `GPIO4_D2`（全局 GPIO 154）控制的 fixed regulator。自愈脚本的做法：

1. 等到 `uptime >= 180s`（避开 fnOS 存储初始化和 rescan 的 120 秒保护窗口）。
2. 桥片已枚举 → 直接退出，什么都不做；fnOS 只配了内置 `/vol1` → 也直接退出。
3. 否则 unbind `reg-fixed-voltage` 的 `vcc5v0-host-regulator` 释放 GPIO，把 GPIO 拉低 3 秒再拉高，然后重新 bind。
4. 桥片重新枚举产生 udev add 事件 → `98-ys-a99-usb-disk.rules` → `ys-a99-usb-rescan.service` 自动组装 mdadm/LVM 并挂回 `/volN`。
5. 无论成功失败，都会恢复 regulator 绑定并把 VBUS 置高；日志在 `/var/log/ys-a99-usb-vbus.log`。

安全边界：每开机只跑一次；盘正常时零副作用；只对已配置外置存储池的机器动作。可用 `YS_A99_VBUS_SIMULATE=1 YS_A99_USB_VID=ffff YS_A99_NO_WAIT=1` 做不动硬件的决策演练。

已知无害告警：重新 bind regulator 后内核会打印两条 `rockchip-usb2phy ... Failed to create device link with supplier vcc5v0-host-regulator`。这是开机后重建 device link 的记账告警，VBUS 保持 enabled、USB 正常（真机已验证）。

## 刷机后自检

```bash
sudo ys-a99-usb-check.sh

# 关键输出
grep -o "usb-storage.quirks=[^ ]*" /proc/cmdline     # 应含 152d:0578:u 和 usbcore.autosuspend=-1
dmesg | grep -E "UAS is ignored|Quirks match|scsi host[0-9]+: usb-storage"
cat /var/lib/ys-a99-vol-map                          # LV -> /volN
findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS | grep '/vol'
tail -40 /var/log/ys-a99-usb-disk.log
systemctl is-enabled ys-a99-usb-vbus-recover.service   # 应为 enabled
tail -20 /var/log/ys-a99-usb-vbus.log                 # 开机自愈记录
```

期望：`lsusb -t` 里硬盘是 `Driver=usb-storage, 5000M`（不是 `uas`）；本次开机 `reset SuperSpeed / USB disconnect / lost sync / uas_eh` 计数为 0；所有 `/volN` 正常挂载。

## 手动干预 / 回退

```bash
# 只检查不挂载
sudo YS_A99_DRY_RUN=1 /usr/local/sbin/ys-a99-usb-rescan.sh

# 手动触发一次开机自愈检查（盘在线时会自动跳过）
sudo YS_A99_NO_WAIT=1 /usr/local/sbin/ys-a99-usb-vbus-recover.sh

# 临时恢复 UAS（不推荐，仅用于排查）：编辑 /boot/armbianEnv.txt，
# 从 usbstoragequirks 去掉 0x152d:0x0578:u，然后重启
sudo nano /boot/armbianEnv.txt && sudo reboot
```

若软件 VBUS 断电后桥片仍不上线，说明桥片/硬盘盒需要真正的物理断电：关机后拔掉电源 30 秒，再重插 USB 线开机。这是 JMS578 硬件层的最后兜底。

## 适用范围

UAS quirk 只针对 `152d:0578`。若换用其他桥片又出现类似掉盘，把该设备的 `vid:pid:u` 追加到 `/boot/armbianEnv.txt` 的 `usbstoragequirks` 即可；runtime PM、休眠禁用和 `/volN` 自动挂载逻辑对所有 USB 盘通用。VBUS 自愈的 GPIO 编号由本板设备树决定（RK3399 ROCK Pi 4C 系），换板需核对 `vcc5v0_host` 的 gpio phandle。

真机验证：2026-11-09 ~ 11-16 连续运行近 7 天无掉盘、无复位；热插拔后 `scsi host0: usb-storage`，插入 11 分钟内错误计数 0；用 loop 设备模拟晚到卷，自动挂载分支通过。2026-11-16 一次系统升级触发软重启后桥片未上线，软件 VBUS 断电 3 秒后 `152d:0578` 重新枚举、`UAS is ignored` / `Quirks match` 生效、udev 自动把 `/vol2` 按原选项挂回；随后部署开机自愈并验证「盘在线不动作 / 盘缺失才动作」两个分支。
