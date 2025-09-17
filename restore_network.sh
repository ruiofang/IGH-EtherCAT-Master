#!/bin/bash

# 网络接口恢复脚本
# 用于在EtherCAT卸载后恢复网络连接和NetworkManager托管
# 作者: RUIO
# 日期: 2025-09-17
# 版本: 2.0

set -e

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

# 恢复网络接口
restore_network_interfaces() {
    log_info "开始恢复网络接口..."
    
    # 重新加载网络驱动模块
    log_info "重新加载网络驱动模块..."
    local network_modules=("ax88179_178a" "r8169" "e1000e" "igb" "ixgbe")
    
    for module in "${network_modules[@]}"; do
        if ! lsmod | grep -q "^${module}"; then
            modprobe "$module" 2>/dev/null && log_info "已加载模块: $module" || log_warning "无法加载模块: $module"
        else
            log_info "模块 $module 已加载"
        fi
    done
    
    # 重新加载udev规则
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=net
    
    # 等待设备初始化
    sleep 2
    
    # 获取所有以太网接口
    log_info "检测网络接口..."
    local interfaces=($(ip link show | grep -oP '^\d+: \K[^:]+' | grep -E '^(eth|enp|enx|ens)'))
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_error "未找到任何以太网接口"
        return 1
    fi
    
    log_success "找到 ${#interfaces[@]} 个网络接口: ${interfaces[*]}"
    
    # 启用每个接口
    for interface in "${interfaces[@]}"; do
        log_info "处理接口: $interface"
        
        # 检查接口当前状态
        local current_state=$(ip link show "$interface" | grep -oP 'state \K[A-Z]+' 2>/dev/null || echo "UNKNOWN")
        log_info "接口 $interface 当前状态: $current_state"
        
        # 启用接口
        if ip link set "$interface" up 2>/dev/null; then
            log_success "已启用接口: $interface"
            
            # 等待接口启动
            sleep 1
            
            # 检查新状态
            local new_state=$(ip link show "$interface" | grep -oP 'state \K[A-Z]+' 2>/dev/null || echo "UNKNOWN")
            log_info "接口 $interface 新状态: $new_state"
            
        else
            log_error "无法启用接口: $interface"
        fi
    done
    
    # 等待网络稳定
    sleep 3
    
    return 0
}

# 重启网络服务
restart_network_services() {
    log_info "重启网络服务..."
    
    # 重启NetworkManager
    if systemctl is-active --quiet NetworkManager; then
        systemctl restart NetworkManager
        log_success "NetworkManager已重启"
        sleep 5
    else
        log_warning "NetworkManager未运行"
    fi
}

# 恢复NetworkManager托管
restore_networkmanager_management() {
    log_info "恢复NetworkManager托管状态..."
    
    # 获取所有以太网接口
    local interfaces=($(ip link show | grep -oP '^\d+: \K[^:]+' | grep -E '^(eth|enp|enx|ens)'))
    
    for interface in "${interfaces[@]}"; do
        if ip link show "$interface" &>/dev/null; then
            log_info "设置接口 $interface 为托管状态..."
            
            # 设置为托管状态
            if nmcli device set "$interface" managed yes 2>/dev/null; then
                log_success "接口 $interface 已设置为托管状态"
                
                # 等待NetworkManager处理
                sleep 2
                
                # 检查是否有现有连接
                if nmcli connection show "$interface" &>/dev/null; then
                    # 启用自动连接
                    if nmcli connection modify "$interface" connection.autoconnect yes 2>/dev/null; then
                        log_success "已启用接口 $interface 的自动连接"
                    else
                        log_warning "无法设置接口 $interface 的自动连接"
                    fi
                    
                    # 激活连接
                    nmcli connection up "$interface" 2>/dev/null && log_success "已激活连接 $interface" || log_warning "无法激活连接 $interface"
                else
                    log_info "接口 $interface 没有现有连接，尝试创建..."
                    # 创建新连接
                    nmcli connection add type ethernet ifname "$interface" con-name "$interface" autoconnect yes 2>/dev/null && log_success "已创建连接 $interface" || log_warning "无法创建连接 $interface"
                fi
                
            else
                log_error "无法设置接口 $interface 为托管状态"
            fi
        fi
    done
    
    # 等待连接建立
    sleep 5
}

# 显示网络状态
show_network_status() {
    log_info "当前网络状态:"
    echo ""
    
    # 显示NetworkManager设备状态
    log_info "NetworkManager设备状态:"
    if command -v nmcli &>/dev/null; then
        nmcli device status | while read line; do
            echo "  $line"
        done
    else
        log_warning "nmcli命令不可用"
    fi
    
    echo ""
    
    # 显示接口状态
    log_info "网络接口物理状态:"
    ip link show | grep -E "^[0-9]+:" | while read line; do
        echo "  $line"
    done
    
    echo ""
    
    # 显示IP地址
    log_info "IP地址分配:"
    ip addr show | grep -E "(^[0-9]+:|inet )" | while read line; do
        if [[ $line =~ ^[0-9]+: ]]; then
            echo "  $line"
        elif [[ $line =~ inet ]]; then
            echo "    $line"
        fi
    done
    
    echo ""
    
    # 测试网络连通性
    log_info "测试网络连通性..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log_success "网络连通性正常"
    else
        log_warning "网络连通性测试失败，可能需要手动配置"
    fi
}

# 显示手动恢复指令
show_manual_instructions() {
    log_info "如果自动恢复失败，请尝试以下手动命令:"
    echo ""
    echo "1. 设置接口为托管状态:"
    echo "   sudo nmcli device set <接口名> managed yes"
    echo ""
    echo "2. 创建新连接:"
    echo "   sudo nmcli connection add type ethernet ifname <接口名> con-name <接口名> autoconnect yes"
    echo ""
    echo "3. 启用自动连接:"
    echo "   sudo nmcli connection modify <连接名> connection.autoconnect yes"
    echo ""
    echo "4. 激活连接:"
    echo "   sudo nmcli connection up <连接名>"
    echo ""
    echo "5. 手动启用接口:"
    echo "   sudo ip link set <接口名> up"
    echo ""
    echo "6. 获取IP地址:"
    echo "   sudo dhclient <接口名>"
    echo ""
}

# 主函数
main() {
    echo ""
    log_info "========================================="
    log_info "网络接口恢复脚本 v2.0"
    log_info "========================================="
    echo ""
    
    check_root
    
    if restore_network_interfaces; then
        restart_network_services
        restore_networkmanager_management
        show_network_status
        
        echo ""
        log_success "========================================="
        log_success "网络接口恢复完成！"
        log_success "========================================="
        echo ""
        
        show_manual_instructions
    else
        log_error "网络接口恢复失败"
        echo ""
        show_manual_instructions
        exit 1
    fi
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi