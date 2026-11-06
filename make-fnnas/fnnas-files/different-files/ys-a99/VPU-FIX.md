# YS-A99 / ZM-A399SE —— RK3399 硬件转码（VPU / MPP / RGA）说明

本镜像已内置针对 YS-A99 的 RK3399 硬件加速修复，**刷完开机即可用**，无需再手动改 dtb 或重编模块。

## 镜像里有什么

| 路径 | 作用 |
| ---- | ---- |
| `/boot/dtb/rockchip/rk3399-ys-a99-mpp-rga.dtb` | 默认 `fdtfile`。在板级 dtb 上加 BSP 的 `mpp-srv` / `vepu` / `vdpu` / `rkvdec`，把 `rga` 的 compatible 改成 `rockchip,rga2`，禁用两个 mainline `video-codec` 节点。 |
| `/boot/dtb/rockchip/rk3399-ys-a99.dtb` | 原始板级 dtb（5.8 主线风格），用于回退。 |
| `/etc/udev/rules.d/99-am40-mpp.rules` | `/dev/mpp_service`、`/dev/rga` 等设为 `root:video 0660`。 |
| `/usr/local/lib/ys-a99/ys-a99-vpu-payload.tar.gz` | MPP 模块源码、vendor 头文件、mediasrv 垫片源码、诊断与回退工具。 |
| `/etc/systemd/system/ys-a99-vpu-fix.service` | 首次开机自动编译并装配（只跑一次，按内核版本缓存）。 |

## 首次开机会自动做两件事

1. 编译 `/usr/local/lib/mediasrv-shim.so` 并给 `mediasrv` 加 `LD_PRELOAD`：
   RK3399 没有 AV1/VP8 硬解和 HEVC 硬编，垫片把这些请求重定向到软解 / H.264 硬编，
   否则飞牛影视即使打开了「硬件加速」也会失败。装好后日志会出现
   `gpu enable: true, selected sequence list: [1]`。
2. 针对当前内核重编 `rk_vcodec.ko`：飞牛官方模块编译时没开 `CONFIG_CPU_RK3399`，
   匹配表里缺 `rockchip,rkv-decoder-rk3399`，导致 H.265 / VP9 / 4K 无硬解。
   重编后 `mpp_service` 版本为 `custom-rk3399-full-v3`，`supports-device` 里出现
   `DEVICE[9]:RKVDEC`。

首次启动约多花 1–3 分钟（编译期间系统照常可用）。日志：

```bash
journalctl -u ys-a99-vpu-fix --no-pager
cat /var/log/ys-a99-vpu-fix.log
cat /var/lib/ys-a99-vpu-fix.state       # 期望 "<内核版本> ok"
```

## 验证硬件加速

```bash
sudo ys-a99-vpu-diag.sh                # 只读体检
cat /proc/mpp_service/version
ls -l /dev/mpp_service /dev/rga
grep -E 'gpu enable|gpu in working' /usr/trim/logs/mediasrv.log | tail -3

# 用飞牛自带 ffmpeg 实测硬解
FF=/usr/trim/lib/mediasrv/ffmpeg
$FF -hide_banner -loglevel error -f lavfi -i "testsrc2=size=1280x720:rate=30" \
    -frames:v 30 -c:v libx265 -preset ultrafast -pix_fmt yuv420p -y /tmp/t.mp4
$FF -hide_banner -c:v hevc_rkmpp -i /tmp/t.mp4 -f null -
```

已验证能力：H.264 1080p 硬解 / 硬编、HEVC 8bit 720p、HEVC 10bit 1080p、HEVC 4K。
硬件限制：RK3399 **没有** AV1 硬解、没有 HEVC 硬编，由垫片自动降级。

## 常用命令

```bash
sudo ys-a99-dtb.sh status              # 查看当前 dtb
sudo ys-a99-dtb.sh orig && sudo reboot # 回退到原始 dtb（关闭 MPP 硬件加速）
sudo ys-a99-dtb.sh mpp  && sudo reboot # 切回修复版 dtb

sudo ys-a99-rebuild-mpp.sh             # OTA 换内核后重编模块
sudo /usr/local/sbin/ys-a99-vpu-fix.sh --force   # 强制重跑首次启动装配
```

## OTA 注意

飞牛系统 OTA 若更换内核，新内核自带 `rk_vcodec.ko` 会重新缺 RK3399 匹配，
H.265 会退回软解。此时 `ys-a99-vpu-fix.service` 会因 state 里的内核版本不同而自动重跑；
也可以手动执行 `sudo ys-a99-rebuild-mpp.sh`。dtb / udev / 垫片一般不受 OTA 影响。
若要移除垫片：`sudo rm /etc/systemd/system/mediasrv.service.d/10-ys-a99-shim.conf && sudo systemctl daemon-reload`。

## 来源

修复方案移植自 `K2O2/am40-fnos-fixes`（基于飞牛官方 Firefly-RK3399 适配），
kernel-mpp 源码与 vendor 头文件来自该仓库及 `rockchip-linux/kernel` develop-6.1。
仅 dtb 按 YS-A99 / ROCK Pi 4C 的 phandle 与中断号改写过。
