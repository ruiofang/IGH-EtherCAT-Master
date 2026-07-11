#!/bin/bash

# IGH EtherCAT Master 安全卸载脚本
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

ETHERCAT_INTERFACE=""

check_root() {
    [[ $EUID -eq 0 ]] || { log_error "此脚本需要 root 权限，请使用 sudo 执行"; exit 1; }
}

read_configured_interface() {
    local config="/opt/etherlab/etc/sysconfig/ethercat"
    [[ -r "$config" ]] || return 0
    ETHERCAT_INTERFACE="$(sed -n 's/^MASTER0_DEVICE="\([^"]*\)".*/\1/p' "$config" | head -n 1)"
}

confirm_uninstall() {
    echo
    log_warning "将停止并移除 IGH EtherCAT Master、内核模块与项目创建的配置。"
    log_warning "专用网卡将恢复为普通 NetworkManager 接口。"
    read -r -p "输入 yes 确认卸载: " confirmation
    [[ "$confirmation" == "yes" ]] || { log_info "卸载已取消"; exit 0; }
}

stop_services() {
    log_info "停止 EtherCAT 服务..."
    systemctl disable --now ethercat.timer 2>/dev/null || true
    systemctl disable --now ethercat.path 2>/dev/null || true
    systemctl disable --now ethercat-monitor.service 2>/dev/null || true
    systemctl stop ethercat.service 2>/dev/null || true
    systemctl disable ethercat.service 2>/dev/null || true
}

unload_modules() {
    log_info "卸载 EtherCAT 内核模块..."
    local modules=() module
    mapfile -t modules < <(lsmod | awk '/^ec_/ {print $1}' | grep -v '^ec_master$' || true)
    for module in "${modules[@]}"; do
        rmmod "$module" 2>/dev/null || log_warning "无法卸载模块: $module"
    done
    rmmod ec_master 2>/dev/null || true
}

remove_project_files() {
    log_info "删除 EtherCAT 安装文件与项目配置..."
    rm -f /etc/systemd/system/ethercat.service
    rm -f /etc/systemd/system/ethercat.timer
    rm -f /etc/systemd/system/ethercat.path
    rm -f /etc/systemd/system/ethercat-monitor.service
    rm -f /usr/local/libexec/ethercat-interface-resolver
    rm -f /etc/init.d/ethercat
    rm -f /etc/sysconfig/ethercat
    rm -f /etc/sysconfig/ethercat.backup.*
    rm -f /etc/modprobe.d/ethercat.conf
    rm -f /etc/udev/rules.d/99-ethercat.rules
    rm -f /etc/udev/rules.d/80-ethercat-autostart.rules
    rm -f /etc/NetworkManager/conf.d/99-ethercat.conf
    rm -f /etc/NetworkManager/conf.d/99-ethercat-release.conf
    rm -rf /var/lib/ethercat /opt/etherlab /usr/src/ethercat
    rm -f /usr/local/bin/ethercat
    find /usr/local/lib -maxdepth 1 -type l -lname '/opt/etherlab/lib/*' -delete 2>/dev/null || true
}

restore_network_interface() {
    [[ -n "$ETHERCAT_INTERFACE" && -d "/sys/class/net/$ETHERCAT_INTERFACE" ]] || return 0
    log_info "恢复网络接口: $ETHERCAT_INTERFACE"
    ip link set dev "$ETHERCAT_INTERFACE" up || log_warning "无法启用接口 $ETHERCAT_INTERFACE"

    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
        systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true
        nmcli device set "$ETHERCAT_INTERFACE" managed yes 2>/dev/null || true
        nmcli device connect "$ETHERCAT_INTERFACE" 2>/dev/null || \
            log_warning "接口已恢复为托管状态，但没有可用的 NetworkManager 连接配置"
    fi
}

remove_service_account() {
    if getent passwd ethercat >/dev/null 2>&1; then
        userdel ethercat 2>/dev/null || log_warning "无法删除 ethercat 用户"
    fi
    if getent group ethercat >/dev/null 2>&1; then
        groupdel ethercat 2>/dev/null || log_warning "无法删除 ethercat 组（可能仍有成员）"
    fi
}

main() {
    check_root
    read_configured_interface
    confirm_uninstall
    stop_services
    unload_modules
    remove_project_files
    systemctl daemon-reload
    udevadm control --reload-rules
    ldconfig
    restore_network_interface
    remove_service_account
    log_success "IGH EtherCAT Master 已卸载"
}

main "$@"
