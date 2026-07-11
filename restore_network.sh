#!/bin/bash

# 网络接口恢复脚本：默认释放已绑定的 EtherCAT 网卡给普通网络。
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

TARGET_INTERFACE=""
RESTORE_ALL=false
RELEASE_ETHERCAT=false
SKIP_DHCP=false

show_help() {
    cat <<EOF
网络接口恢复脚本

用法: sudo $0 [选项]

选项:
  -i, --iface NAME       恢复指定接口
  -a, --all              恢复全部非 EtherCAT 的有线接口
    --release-ethercat     停止 EtherCAT 并释放其专用接口给 NetworkManager（默认）
  --skip-dhcp            不在无 NetworkManager 时执行 DHCP
  -h, --help             显示帮助

说明: 不带选项时，恢复已绑定的 EtherCAT 网口给 NetworkManager。
    脚本不会等待连接激活、DHCP 或 IP 地址分配。
    --iface 和 --all 不会停止 EtherCAT，也不会修改其专用网卡。
EOF
}

check_root() {
    [[ $EUID -eq 0 ]] || { log_error "此脚本需要 root 权限，请使用 sudo 执行"; exit 1; }
}

configured_ethercat_interface() {
    local config="/opt/etherlab/etc/sysconfig/ethercat"
    [[ -r "$config" ]] || return 0
    sed -n 's/^MASTER0_DEVICE="\([^"]*\)".*/\1/p' "$config" | head -n 1
}

interface_mac_address() {
    local iface="$1"
    if [[ "$iface" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        printf '%s\n' "${iface,,}"
        return 0
    fi
    [[ -r "/sys/class/net/$iface/address" ]] || return 0
    tr '[:upper:]' '[:lower:]' < "/sys/class/net/$iface/address"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -i|--iface)
                [[ $# -ge 2 ]] || { log_error "--iface 需要接口名"; exit 1; }
                TARGET_INTERFACE="$2"; shift 2 ;;
            -a|--all) RESTORE_ALL=true; shift ;;
            --release-ethercat) RELEASE_ETHERCAT=true; shift ;;
            --skip-dhcp) SKIP_DHCP=true; shift ;;
            *) log_error "未知选项: $1"; show_help; exit 1 ;;
        esac
    done

    if [[ -n "$TARGET_INTERFACE" && "$RESTORE_ALL" == true ]]; then
        log_error "--iface 与 --all 不能同时使用"
        exit 1
    fi
    if [[ -z "$TARGET_INTERFACE" && "$RESTORE_ALL" != true && "$RELEASE_ETHERCAT" != true ]]; then
        RELEASE_ETHERCAT=true
        log_info "未指定选项，默认释放已绑定的 EtherCAT 网口"
    fi
}

release_ethercat() {
    local iface iface_mac
    iface="$(configured_ethercat_interface)"
    iface_mac="$(interface_mac_address "$iface")"
    log_info "停止 EtherCAT 服务并释放专用网卡..."
    systemctl stop ethercat.service 2>/dev/null || true
    systemctl disable --now ethercat.path 2>/dev/null || true
    systemctl disable --now ethercat-monitor.service 2>/dev/null || true
    rm -f /etc/NetworkManager/conf.d/99-ethercat.conf
    if [[ -n "$iface_mac" ]]; then
        cat > /etc/NetworkManager/conf.d/99-ethercat-release.conf <<EOF
[keyfile]
# Ubuntu 默认仅托管无线设备；额外托管刚释放的物理 EtherCAT 网卡。
unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma,except:mac:$iface_mac
EOF
    fi
    rm -f /etc/udev/rules.d/80-ethercat-autostart.rules
    rm -f /etc/systemd/system/ethercat.path
    rm -f /etc/systemd/system/ethercat-monitor.service
    rm -f /usr/local/libexec/ethercat-interface-resolver
    systemctl daemon-reload
    udevadm control --reload-rules
    if systemctl is-active --quiet NetworkManager; then
        systemctl reload NetworkManager || log_warning "无法重载 NetworkManager 配置"
    fi

    if [[ -z "$TARGET_INTERFACE" && -n "$iface" ]]; then
        TARGET_INTERFACE="$iface"
    fi
}

collect_interfaces() {
    local ethercat_iface="$1" iface type_val
    if [[ -n "$TARGET_INTERFACE" ]]; then
        [[ -d "/sys/class/net/$TARGET_INTERFACE" ]] || { log_error "接口不存在: $TARGET_INTERFACE"; exit 1; }
        printf '%s\n' "$TARGET_INTERFACE"
        return
    fi

    for iface in /sys/class/net/*; do
        iface="$(basename "$iface")"
        [[ "$iface" == "lo" || "$iface" == "$ethercat_iface" ]] && continue
        [[ "$iface" =~ ^(docker|br-|veth|virbr|wl|ww|tailscale|tun|tap|wg) ]] && continue
        [[ -d "/sys/class/net/$iface/wireless" || -d "/sys/class/net/$iface/bridge" ]] && continue
        type_val="$(cat "/sys/class/net/$iface/type" 2>/dev/null || true)"
        [[ "$type_val" == "1" ]] && printf '%s\n' "$iface"
    done
}

restore_interface() {
    local iface="$1" nm_managed
    log_info "恢复接口: $iface"
    ip link set dev "$iface" up

    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
        nmcli device set "$iface" managed yes 2>/dev/null || true
        nm_managed="$(nmcli -g GENERAL.NM-MANAGED device show "$iface" 2>/dev/null || true)"
        if [[ "$nm_managed" == "是" || "$nm_managed" == "yes" ]]; then
            log_success "$iface 已交由 NetworkManager 托管（不等待 IP 配置）"
        else
            log_warning "$iface 尚未由 NetworkManager 托管"
        fi
    elif [[ "$SKIP_DHCP" != true ]] && command -v dhclient >/dev/null 2>&1; then
        timeout 15 dhclient "$iface" || log_warning "$iface DHCP 未成功"
    fi
}

main() {
    parse_args "$@"
    check_root

    local ethercat_iface
    ethercat_iface="$(configured_ethercat_interface)"
    if [[ "$RELEASE_ETHERCAT" == true ]]; then
        release_ethercat
        ethercat_iface=""
    fi

    local interfaces=()
    mapfile -t interfaces < <(collect_interfaces "$ethercat_iface")
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_warning "没有需要恢复的接口"
        exit 0
    fi

    local iface
    for iface in "${interfaces[@]}"; do
        restore_interface "$iface"
    done

    if command -v nmcli >/dev/null 2>&1; then
        nmcli device status
    else
        ip -brief addr show
    fi
}

main "$@"
