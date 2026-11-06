# YS-A99 / ZM-A399SE (FnNAS board id: `ys-a99`)

Rockchip RK3399 board, device-tree compatible with `radxa,rockpi4c` / `radxa,rockpi4` / `rockchip,rk3399`.

## Files

| Path | Purpose |
| ---- | ------- |
| `bootfs/dtb/rockchip/rk3399-ys-a99.dtb` | Board DTB from Armbian 20.11 (kernel 5.8.17), dtb name `a399se.dtb`. Contains AP6212 WiFi/BT, ES8316 audio and ROCK Pi 4C peripherals. |
| `bootfs/armbianEnv.txt` | Boot environment: selects the custom DTB, serial console on ttyS2 1500000. |
| `u-boot/idbloader.img` | TPL+SPL from the working Armbian 20.11 image (U-Boot 2020.07-armbian, includes board DDR `rockchip,sdram-params`). Written at sector 64. |
| `u-boot/u-boot.itb` | FIT image (U-Boot + TF-A/BL31) from the same image. Written at sector 16384 (8 MiB). |

Boot blobs are extracted from
`Armbian_20.11_ZM-A399SE_focal_current_5.8.17.zip` (files.kos.org.cn, 417.3 MiB).
`idbloader.img` = image bytes `[0x8000, 0x30000)`, `u-boot.itb` = `[0x800000, 0x8f0000)`.

## Build

`Build FnNAS Image` workflow -> `fnnas_board: ys-a99`, `fnnas_base_version: rockchip_1253`,
`fnnas_kernel: 6.18.y`, `auto_kernel: true`. The workflow stages the two u-boot blobs into
`make-fnnas/u-boot/rockchip/ys-a99/` before `renas -b ys-a99` runs.

## Notes / fallback

- The DTB comes from a 5.8-era kernel but is consumed by a 6.18 kernel. RK3399 bindings are
  largely stable, but if storage/network/HDMI misbehave, boot into the system (or mount the
  BOOT partition on another machine) and change `fdtfile=` in `/boot/armbianEnv.txt` to another
  rk3399 dtb shipped in `/boot/dtb/rockchip/`.
- The bootloader is the board's own U-Boot 2020.07. `boot.cmd` from ophub calls `kaslrseed`,
  which this U-Boot does not implement; the command is skipped non-fatally.

## VPU / hardware transcoding (built in)

`rk3399-ys-a99-mpp-rga.dtb` is now the **default** `fdtfile` (set in both `model_database.conf`
and `bootfs/armbianEnv.txt`). It adds the vendor MPP nodes (`mpp-srv`, `vepu`, `vdpu`, `rkvdec`),
switches `rga` to `rockchip,rga2` and disables the two mainline `video-codec` nodes.
The original `rk3399-ys-a99.dtb` is kept for fallback.

`rootfs/` injects the udev permissions rule, the `ys-a99-vpu-fix.service` oneshot unit and
`ys-a99-vpu-payload.tar.gz` (MPP module source, vendor headers, mediasrv shim source,
diagnostic and rollback tools). On first boot the service compiles `mediasrv-shim.so` and
rebuilds `rk_vcodec.ko` against the running kernel - the module vermagic is kernel-specific,
so it cannot be prebuilt in CI. The result is cached per kernel version in
`/var/lib/ys-a99-vpu-fix.state`; later boots skip it. See `VPU-FIX.md` for verification,
rollback and OTA notes.

Verified on hardware: H.264 1080p decode/encode, HEVC 8bit/10bit and 4K decode,
`mediasrv` log `gpu enable: true, selected sequence list: [1]`.
