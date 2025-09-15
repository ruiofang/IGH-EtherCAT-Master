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
        "/etc/modprobe.d/ethercat.conf"
        "/etc/udev/rules.d/99-ethercat.rules"
        "/var/lib/ethercat"
    )
    
    for file in "${config_files[@]}"; do
        if [[ -e "$file" ]]; then
            rm -rf "$file"
            log_info "已删除: $file"
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

# 恢复网络驱动（可选）
restore_network_drivers() {
    log_info "检查是否需要恢复网络驱动..."
    
    if [[ -f "/etc/modprobe.d/ethercat.conf.backup" ]]; then
        mv /etc/modprobe.d/ethercat.conf.backup /etc/modprobe.d/ethercat.conf
        log_info "已恢复原始网络驱动配置"
    fi
    
    # 提醒用户检查网络配置
    log_warning "请检查网络配置是否需要手动恢复"
    log_warning "可能需要重新启用之前被禁用的网络驱动"
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
    echo "1. 建议重启系统以确保所有更改生效"
    echo "2. 检查网络配置是否需要手动恢复"
    echo "3. 如果之前禁用了网络驱动，可能需要重新启用"
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
