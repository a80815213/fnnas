#!/bin/bash
# ============================================================================
#  YS-A99 / ZM-A399SE (RK3399) -- VPU / MPP first-boot enablement
#
#  镜像里已经内置：
#    * /boot/dtb/rockchip/rk3399-ys-a99-mpp-rga.dtb  (默认 fdtfile)
#    * /etc/udev/rules.d/99-am40-mpp.rules           (设备权限)
#    * /usr/local/lib/ys-a99/ys-a99-vpu-payload.tar.gz (源码 / 规则 / 工具)
#
#  本服务在首次开机（或内核版本变化后）现场编译两样 vermagic / ABI 相关的东西：
#    1. /usr/local/lib/mediasrv-shim.so
#       隐藏 RK3399 没有的 av1_rkmpp / vp8_rkmpp，HEVC 硬编回退 H.264 硬编。
#    2. /lib/modules/$(uname -r)/updates/trim/rk_vcodec/rk_vcodec.ko
#       飞牛官方模块编译时未开 CONFIG_CPU_RK3399，缺 RKVDEC 匹配，
#       导致 H.265 / VP9 / 4K 无硬解。用 K2O2/kernel-mpp 源码针对当前内核重编。
#
#  结果按内核版本记录在 /var/lib/ys-a99-vpu-fix.state，之后开机直接跳过。
#  手动重跑： sudo /usr/local/sbin/ys-a99-vpu-fix.sh --force
#  日志：     journalctl -u ys-a99-vpu-fix  或  /var/log/ys-a99-vpu-fix.log
# ============================================================================
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

KVER="$(uname -r)"
PAYLOAD=/usr/local/lib/ys-a99/ys-a99-vpu-payload.tar.gz
SRC=/usr/local/src/ys-a99-mpp
SHARE=/usr/local/share/ys-a99
STATE=/var/lib/ys-a99-vpu-fix.state
LOG=/var/log/ys-a99-vpu-fix.log
SO=/usr/local/lib/mediasrv-shim.so
KO="/lib/modules/${KVER}/updates/trim/rk_vcodec/rk_vcodec.ko"
DROPIN=/etc/systemd/system/mediasrv.service.d/10-ys-a99-shim.conf
RKV_MATCH='rockchip,rkv-decoder-rk3399'

log() { echo "[$(date '+%F %T')] $*"; }
log "===== ys-a99-vpu-fix start (kernel ${KVER}) ====="

[ "$(id -u)" -eq 0 ] || { log "需要 root 权限"; exit 1; }
[ -f "${PAYLOAD}" ] || { log "缺少 payload: ${PAYLOAD}，跳过"; exit 0; }

# ---- 快速路径：当前内核已处理过，且两个产物都还在 -------------------------
if [ "${1:-}" != "--force" ] && [ -f "${STATE}" ]; then
    read -r st_kver st_status _ < "${STATE}" 2>/dev/null || true
    if [ "${st_kver:-}" = "${KVER}" ] && [ "${st_status:-}" = "ok" ] &&
       [ -f "${SO}" ] && [ -f "${KO}" ] && grep -aq "${RKV_MATCH}" "${KO}"; then
        log "已就绪（state=ok），无需重编"; exit 0
    fi
fi

# ---- 展开 payload ----------------------------------------------------------
mkdir -p "${SRC}" "${SHARE}"
if ! tar -xzf "${PAYLOAD}" -C "${SRC}" mpp build.sh headers; then
    log "payload 展开(源码)失败"; exit 1
fi
tar -xzf "${PAYLOAD}" -C "${SHARE}" \
    mediasrv-shim.c 99-am40-mpp.rules 10-am40-shim.conf \
    ys-a99-dtb.sh ys-a99-rebuild-mpp.sh ys-a99-vpu-diag.sh VPU-FIX.md 2>/dev/null || true

# ---- udev 规则 + 用户工具 --------------------------------------------------
install -d /etc/udev/rules.d
install -m 644 "${SHARE}/99-am40-mpp.rules" /etc/udev/rules.d/99-am40-mpp.rules
udevadm control --reload-rules 2>/dev/null || true
for f in ys-a99-dtb.sh ys-a99-rebuild-mpp.sh ys-a99-vpu-diag.sh; do
    [ -f "${SHARE}/${f}" ] && install -m 755 "${SHARE}/${f}" "/usr/local/sbin/${f}"
done

# 编译工具缺失时尝试安装（fnOS 官方 rootfs 自带 gcc/make，这里只是兜底）
if ! command -v gcc >/dev/null || ! command -v make >/dev/null; then
    log "gcc/make 缺失，尝试 apt 安装（最多 180 秒）"
    export DEBIAN_FRONTEND=noninteractive
    timeout 180 apt-get update -o Acquire::Check-Valid-Until=false >/dev/null 2>&1 || true
    timeout 180 apt-get install -y --no-install-recommends gcc make bc >/dev/null 2>&1 || true
fi
HAS_GCC=0; command -v gcc >/dev/null && HAS_GCC=1

# ---- 1) mediasrv 兼容垫片 --------------------------------------------------
SHIM_OK=0
if [ -f "${SO}" ]; then
    SHIM_OK=1
elif [ "${HAS_GCC}" = "1" ]; then
    log "编译 mediasrv-shim.so"
    if gcc -shared -fPIC -O2 -o "${SO}.tmp" "${SHARE}/mediasrv-shim.c" -ldl -lpthread; then
        mv -f "${SO}.tmp" "${SO}"; chmod 644 "${SO}"; SHIM_OK=1
        log "垫片编译成功"
    else
        rm -f "${SO}.tmp"; log "垫片编译失败（不影响系统启动，AV1 会走软解异常）"
    fi
fi
if [ "${SHIM_OK}" = "1" ]; then
    install -d "$(dirname "${DROPIN}")"
    cat > "${DROPIN}" <<'EOF'
# YS-A99 / ZM-A399SE (RK3399): mediasrv codec compatibility shim
# 仅注入 LD_PRELOAD，保留飞牛原版 ExecStart 参数。
# 垫片把 RK3399 不支持的 av1_rkmpp / vp8_rkmpp 重定向到软解，
# 把 HEVC 硬编请求回退到 H.264 硬编，使网页「硬件加速」开关真正生效。
[Service]
Environment=LD_PRELOAD=/usr/local/lib/mediasrv-shim.so
EOF
    systemctl daemon-reload 2>/dev/null || true
fi

# ---- 2) 重编 rk_vcodec.ko -------------------------------------------------
KO_OK=0
if [ -f "${KO}" ] && grep -aq "${RKV_MATCH}" "${KO}"; then
    KO_OK=1
    log "当前 rk_vcodec.ko 已含 RK3399 RKVDEC 匹配，跳过编译"
elif [ "${HAS_GCC}" != "1" ]; then
    log "无 gcc，跳过 rk_vcodec.ko 重编（H.264 硬解仍可用）"
else
    KDIR="$(readlink -f "/lib/modules/${KVER}/build" 2>/dev/null || true)"
    [ -d "${KDIR}/include" ] || KDIR="/usr/src/linux-headers-${KVER}"
    if [ ! -d "${KDIR}/include" ]; then
        log "缺内核头文件 ${KDIR}，跳过重编"
    else
        log "补 vendor 头文件到 ${KDIR}"
        mkdir -p "${KDIR}/include/linux/rockchip" "${KDIR}/include/uapi/linux" "${KDIR}/include/soc/rockchip"
        cp -f "${SRC}/headers/linux/dma-buf-cache.h"               "${KDIR}/include/linux/"
        cp -f "${SRC}/headers/linux/rockchip/rockchip_sip.h"       "${KDIR}/include/linux/rockchip/"
        cp -f "${SRC}/headers/soc/rockchip/rockchip_opp_select.h"  "${KDIR}/include/soc/rockchip/"
        cp -f "${SRC}/headers/uapi/linux/rk-mpp.h"                 "${KDIR}/include/uapi/linux/"
        SIPH="${KDIR}/include/soc/rockchip/rockchip_sip.h"
        [ -f "${SIPH}.bak-ys-a99" ] || cp -a "${SIPH}" "${SIPH}.bak-ys-a99" 2>/dev/null || true
        cat > "${SIPH}" <<'EOF'
#ifndef __SOC_ROCKCHIP_SIP_H
#define __SOC_ROCKCHIP_SIP_H
#include <linux/rockchip/rockchip_sip.h>
#endif
EOF
        log "编译 rk_vcodec.ko（约 1-3 分钟）"
        if ( cd "${SRC}" && KDIR="${KDIR}" bash build.sh ) >>"${LOG}" 2>&1; then
            NEWKO="${SRC}/build/rk_vcodec.ko"
            VM="$(modinfo -F vermagic "${NEWKO}" 2>/dev/null || true)"
            VM_OK=0; case "${VM}" in *"${KVER}"*) VM_OK=1;; esac
            if [ -f "${NEWKO}" ] && [ "${VM_OK}" = "1" ]; then
                BAK="/boot/ys-a99-rk_vcodec.ko.bak-${KVER}"
                [ -f "${BAK}" ] || cp -a "${KO}" "${BAK}" 2>/dev/null || true
                mkdir -p "$(dirname "${KO}")"
                cp -f "${NEWKO}" "${KO}" && chmod 644 "${KO}"
                depmod -a 2>/dev/null || true
                # 已加载则热重载，否则下次开机自动生效
                if lsmod 2>/dev/null | grep -q '^rk_vcodec'; then
                    systemctl stop mediasrv 2>/dev/null || true
                    pkill -x ffmpeg 2>/dev/null || true
                    sleep 1
                    if rmmod rk_vcodec 2>/dev/null && insmod "${KO}" 2>/dev/null; then
                        log "模块热重载成功"
                    else
                        log "模块热重载失败，已安装新模块，重启后生效"
                    fi
                    systemctl start mediasrv 2>/dev/null || true
                fi
                KO_OK=1
                log "rk_vcodec.ko 安装完成（vermagic ${VM}）"
            else
                log "vermagic 不匹配（${VM} != ${KVER}），放弃安装"
            fi
        else
            log "rk_vcodec.ko 编译失败，详情见 ${LOG}"
        fi
    fi
fi

# ---- 收尾 ------------------------------------------------------------------
if [ "${SHIM_OK}" = "1" ] && [ "${KO_OK}" = "1" ]; then
    echo "${KVER} ok" > "${STATE}"
    log "完成：H.264 / H.265 / VP9 / 4K 硬解与 H.264 硬编已启用"
else
    echo "${KVER} partial" > "${STATE}"
    log "部分完成（shim=${SHIM_OK} ko=${KO_OK}）。可运行 sudo ys-a99-vpu-fix.sh --force 重试"
fi
if systemctl is-active mediasrv >/dev/null 2>&1; then
    systemctl restart mediasrv 2>/dev/null || true
    log "已重启 mediasrv 以加载垫片"
fi
log "===== ys-a99-vpu-fix done ====="
exit 0
