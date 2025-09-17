#!/bin/bash

# IGH EtherCAT Master 1.6 卸载脚本
# 作者: GitHub Copilot
# 日期: 2025-09-06
# 版本: 1.0

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行，请使用 sudo 执行"
        exit 1
    fi
}

# 确认卸载
confirm_uninstall() {
    echo ""
    log_warning "========================================="
    log_warning "即将卸载 IGH EtherCAT Master"
    log_warning "========================================="
    echo ""
    log_warning "此操作将删除以下内容："
    echo "  - EtherCAT主站服务"
    echo "  - 内核模块"
    echo "  - 安装文件 (/opt/etherlab)"
    echo "  - 配置文件"
    echo "  - 用户和组"
    echo "  - systemd服务"
    echo ""
    
    read -p "您确定要继续吗？(输入 'yes' 确认): " confirmation
    
    if [[ "$confirmation" != "yes" ]]; then
        log_info "卸载已取消"
        exit 0
    fi
}

# 停止服务
stop_service() {
    log_info "正在停止EtherCAT服务..."
    
    # 停止服务
    if systemctl is-active --quiet ethercat 2>/dev/null; then
        systemctl stop ethercat
        log_info "EtherCAT服务已停止"
    fi
    
    # 禁用服务
    if systemctl is-enabled --quiet ethercat 2>/dev/null; then
        systemctl disable ethercat
        log_info "EtherCAT服务已禁用"
    fi
}

# 卸载内核模块
unload_modules() {
    log_info "正在卸载内核模块..."
    
    # 卸载EtherCAT相关模块
    local modules=("ec_master" "ec_generic" "ec_8139too" "ec_e100" "ec_e1000" "ec_e1000e" "ec_r8169" "ec_igb" "ec_ixgbe")
    
    for module in "${modules[@]}"; do
        if lsmod | grep -q "^${module}"; then
            rmmod "$module" 2>/dev/null && log_info "已卸载模块: $module" || log_warning "无法卸载模块: $module"
        fi
    done
}

# 删除文件和目录
remove_files() {
    log_info "正在删除安装文件..."
    
    # 删除安装目录
    if [[ -d "/opt/etherlab" ]]; then
        rm -rf /opt/etherlab
        log_info "已删除 /opt/etherlab"
    fi
    
    # 删除源码目录
    if [[ -d "/usr/src/ethercat" ]]; then
        rm -rf /usr/src/ethercat
        log_info "已删除 /usr/src/ethercat"
    fi
    
    # 删除符号链接
    local links=("/usr/local/bin/ethercat" "/usr/local/lib/libethercat.so" "/usr/local/lib/libethercat.so.1")
    for link in "${links[@]}"; do
        if [[ -L "$link" ]]; then
            rm -f "$link"
            log_info "已删除符号链接: $link"
        fi
    done
}

# 删除配置文件
remove_config_files() {
    log_info "正在删除配置文件..."
    
    local config_files=(
        "/etc/systemd/system/ethercat.service"
        "/etc/init.d/ethercat"
        "/etc/sysconfig/ethercat"
        "/etc/sysconfig/ethercat.backup.*"
        "/etc/modprobe.d/ethercat.conf"
        "/etc/udev/rules.d/99-ethercat.rules"
        "/var/lib/ethercat"
        "/etc/ethercat.conf"
        "/etc/ethercat"
        "/etc/default/ethercat"
        "/etc/NetworkManager/conf.d/99-ethercat.conf"
        "/opt/ethercat"
        "/opt/etherlab"
    )
    
    for file in "${config_files[@]}"; do
        if [[ -e "$file" ]]; then
            rm -rf "$file"
            log_info "已删除: $file"
        fi
    done
    
    # 删除rc目录中的符号链接
    find /etc/rc*.d -name "*ethercat*" -type l 2>/dev/null | while read link; do
        if [[ -L "$link" ]]; then
            rm -f "$link"
            log_info "已删除符号链接: $link"
        fi
    done
}

# 删除用户和组
remove_user() {
    log_info "正在删除用户和组..."
    
    # 删除ethercat用户
    if getent passwd ethercat > /dev/null 2>&1; then
        userdel ethercat 2>/dev/null && log_info "已删除用户: ethercat" || log_warning "无法删除用户: ethercat"
    fi
    
    # 删除ethercat组
    if getent group ethercat > /dev/null 2>&1; then
        groupdel ethercat 2>/dev/null && log_info "已删除组: ethercat" || log_warning "无法删除组: ethercat"
    fi
}

# 清理系统
cleanup_system() {
    log_info "正在清理系统..."
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 重新加载udev规则
    udevadm control --reload-rules
    
    # 更新动态链接库缓存
    ldconfig
    
    log_success "系统清理完成"
}

# 恢复网络驱动和网络管理
restore_network_drivers() {
    log_info "检查是否需要恢复网络驱动和网络管理..."
    
    # 恢复modprobe配置
    if [[ -f "/etc/modprobe.d/ethercat.conf.backup" ]]; then
        mv /etc/modprobe.d/ethercat.conf.backup /etc/modprobe.d/ethercat.conf
        log_info "已恢复原始网络驱动配置"
    fi
    
    # 删除NetworkManager中的不管理设备配置
    if [[ -f "/etc/NetworkManager/conf.d/99-ethercat.conf" ]]; then
        rm -f /etc/NetworkManager/conf.d/99-ethercat.conf
        log_info "已删除NetworkManager EtherCAT配置"
        
        # 重启NetworkManager
        systemctl restart NetworkManager 2>/dev/null && log_info "NetworkManager已重启" || log_warning "NetworkManager重启失败"
    fi
    
    # 移除可能存在的EtherCAT相关配置
    local ethercat_configs=(
        "/etc/modprobe.d/ethercat.conf"
        "/etc/udev/rules.d/99-ethercat.rules"
        "/etc/NetworkManager/conf.d/99-ethercat.conf"
    )
    
    for config in "${ethercat_configs[@]}"; do
        if [[ -f "$config" ]]; then
            rm -f "$config"
            log_info "已删除配置文件: $config"
        fi
    done
    
    # 重新加载udev规则
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=net
    
    # 尝试重新加载网络驱动模块（先卸载再加载以确保干净状态）
    log_info "重新加载网络驱动模块..."
    local network_modules=("ax88179_178a" "r8169" "e1000e" "igb" "ixgbe")
    
    for module in "${network_modules[@]}"; do
        # 先卸载模块（如果已加载）
        if lsmod | grep -q "^${module}"; then
            rmmod "$module" 2>/dev/null && log_info "已卸载模块: $module" || log_warning "无法卸载模块: $module"
        fi
        
        # 重新加载模块
        modprobe "$module" 2>/dev/null && log_info "已重新加载模块: $module" || log_warning "无法加载模块: $module"
    done
    
    # 等待设备初始化
    sleep 2
    
    # 启用所有网络接口并配置
    log_info "启用和配置网络接口..."
    
    # 获取所有以太网接口
    local interfaces=($(ip link show | grep -oP '^\d+: \K[^:]+' | grep -E '^(eth|enp|enx|ens)'))
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_warning "未找到以太网接口"
    else
        for interface in "${interfaces[@]}"; do
            log_info "处理接口: $interface"
            
            # 启用接口
            if ip link set "$interface" up 2>/dev/null; then
                log_success "已启用接口: $interface"
                
                # 检查接口状态
                local link_status=$(ip link show "$interface" | grep -o "state [A-Z]*" | cut -d' ' -f2)
                log_info "接口 $interface 状态: $link_status"
                
                # 尝试获取自动IP地址（如果连接了DHCP）
                dhclient "$interface" 2>/dev/null &
                
            else
                log_error "无法启用接口: $interface"
            fi
        done
    fi
    
    # 重启网络相关服务
    log_info "重启网络服务..."
    systemctl restart NetworkManager 2>/dev/null && log_info "NetworkManager已重启" || log_warning "NetworkManager重启失败"
    
    # 等待网络服务启动
    sleep 5
    
    # 确保所有以太网接口被NetworkManager托管
    log_info "恢复NetworkManager对网络接口的托管..."
    for interface in "${interfaces[@]}"; do
        # 检查接口是否存在
        if ip link show "$interface" &>/dev/null; then
            # 强制设置为托管状态
            nmcli device set "$interface" managed yes 2>/dev/null && log_info "已设置接口 $interface 为托管状态" || log_warning "无法设置接口 $interface 为托管状态"
            
            # 启用自动连接
            if nmcli connection show "$interface" &>/dev/null; then
                nmcli connection modify "$interface" connection.autoconnect yes 2>/dev/null && log_info "已启用接口 $interface 的自动连接" || log_warning "无法设置接口 $interface 的自动连接"
            fi
        fi
    done
    
    # 再次等待NetworkManager处理完成
    sleep 3
    
    # 显示NetworkManager设备状态
    log_info "NetworkManager设备状态:"
    nmcli device status 2>/dev/null | while read line; do
        echo "  $line"
    done
    
    echo ""
    
    # 显示网络接口状态
    log_info "网络接口物理状态:"
    ip link show | grep -E "^[0-9]+:" | while read line; do
        echo "  $line"
    done
}

# 显示卸载后信息
show_post_uninstall_info() {
    log_success "========================================="
    log_success "IGH EtherCAT Master 卸载完成！"
    log_success "========================================="
    echo ""
    log_info "已删除的内容："
    echo "  ✓ EtherCAT主站服务"
    echo "  ✓ 内核模块"
    echo "  ✓ 安装文件和目录"
    echo "  ✓ 配置文件"
    echo "  ✓ 用户和组"
    echo "  ✓ systemd服务文件"
    echo ""
    log_warning "注意事项："
    echo "1. 网络接口已尝试自动恢复并设置为NetworkManager托管"
    echo "2. 如果网络接口仍显示为'未托管'，请运行: sudo nmcli device set <接口名> managed yes"
    echo "3. 如需启用自动连接，请运行: sudo nmcli connection modify <连接名> connection.autoconnect yes"
    echo "4. 建议重启系统以确保所有更改完全生效"
    echo ""
    log_info "网络恢复脚本："
    echo "  如有网络问题，可以运行: sudo ./restore_network.sh"
    echo ""
    log_info "如需重新安装，请运行部署脚本: ./deploy_igh_ethercat.sh"
    echo ""
}

# 主函数
main() {
    log_info "开始卸载IGH EtherCAT Master..."
    echo ""
    
    check_root
    confirm_uninstall
    stop_service
    unload_modules
    remove_files
    remove_config_files
    remove_user
    cleanup_system
    restore_network_drivers
    
    echo ""
    show_post_uninstall_info
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
