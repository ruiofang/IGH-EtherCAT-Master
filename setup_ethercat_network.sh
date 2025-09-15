#!/bin/bash

# IGH EtherCAT Master 网卡绑定和服务启动脚本
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

# 检查EtherCAT安装
check_installation() {
    if [[ ! -d "/opt/etherlab" ]]; then
        log_error "EtherCAT Master未安装，请先运行部署脚本"
        exit 1
    fi
    
    if [[ ! -f "/opt/etherlab/etc/sysconfig/ethercat" ]]; then
        log_error "EtherCAT配置文件不存在，请先运行部署脚本"
        exit 1
    fi
    
    log_success "EtherCAT Master安装检查通过"
}

# 显示可用的网络接口
show_network_interfaces() {
    log_info "可用的网络接口："
    echo ""
    
    # 使用不同的方法获取网络接口信息
    if command -v ip &> /dev/null; then
        echo "接口名称         状态      类型        MAC地址"
        echo "--------         ----      ----        -------"
        
        # 获取所有非lo接口
        ip link show | grep -E "^[0-9]+:" | while IFS= read -r line; do
            interface=$(echo "$line" | sed -E 's/^[0-9]+: ([^:@]+)[@:]?.*/\1/')
            
            if [[ "$interface" != "lo" ]]; then
                # 获取状态
                state=$(echo "$line" | grep -o "state [A-Z]*" | cut -d' ' -f2 2>/dev/null || echo "UNKNOWN")
                
                # 获取MAC地址 - 需要读取下一行
                mac_line=$(ip link show "$interface" | grep -o "link/ether [a-f0-9:]\{17\}" | cut -d' ' -f2 2>/dev/null || echo "N/A")
                
                # 格式化输出
                printf "%-16s %-8s %-10s %s\n" "$interface" "$state" "ethernet" "$mac_line"
            fi
        done
    else
        echo "使用ifconfig显示接口："
        ifconfig -a | grep -E "^[a-zA-Z0-9]" | grep -v "lo" | while IFS= read -r line; do
            interface=$(echo "$line" | cut -d' ' -f1 | sed 's/:$//')
            printf "  %s\n" "$interface"
        done
    fi
    echo ""
}

# 交互式选择网卡
select_interface() {
    local selected_interface=""
    
    while [[ -z "$selected_interface" ]]; do
        show_network_interfaces >&2  # 重定向到stderr，避免混入返回值
        
        echo -n "请输入要绑定到EtherCAT的网卡名称 (例如: eth0, enp2s0): " >&2
        read -r interface_name
        
        if [[ -z "$interface_name" ]]; then
            log_warning "请输入有效的网卡名称" >&2
            continue
        fi
        
        # 检查网卡是否存在
        if ip link show "$interface_name" &>/dev/null; then
            selected_interface="$interface_name"
            log_success "选择的网卡: $selected_interface" >&2
        else
            log_error "网卡 '$interface_name' 不存在，请重新选择" >&2
        fi
    done
    
    echo "$selected_interface"  # 只返回接口名称
}

# 配置EtherCAT网卡
configure_ethercat_interface() {
    local interface="$1"
    local config_file="/opt/etherlab/etc/sysconfig/ethercat"
    local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    log_info "正在配置EtherCAT网卡绑定..."
    
    # 备份原配置文件
    cp "$config_file" "$backup_file"
    log_info "配置文件已备份到: $backup_file"
    
    # 更新配置文件（使用 awk 来避免 sed 的特殊字符问题）
    awk -v interface="$interface" '
    {
        if (/^MASTER0_DEVICE=/) {
            print "MASTER0_DEVICE=\"" interface "\""
        } else if (/^DEVICE_MODULES=/) {
            print "DEVICE_MODULES=\"generic\""
        } else {
            print $0
        }
    }' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    
    # 验证配置
    local configured_device=$(grep "^MASTER0_DEVICE=" "$config_file" | cut -d'=' -f2 | tr -d '"')
    if [[ "$configured_device" == "$interface" ]]; then
        log_success "网卡配置完成: $interface"
        
        # 显示当前配置
        log_info "当前EtherCAT配置:"
        grep -E "^MASTER0_DEVICE=|^DEVICE_MODULES=" "$config_file" | sed 's/^/  /'
    else
        log_error "网卡配置失败"
        exit 1
    fi
}

# 停止NetworkManager对指定网卡的管理
disable_networkmanager() {
    local interface="$1"
    
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        log_info "检测到NetworkManager，正在禁用对 $interface 的管理..."
        
        # 设置网卡为非托管状态
        nmcli device set "$interface" managed no 2>/dev/null || true
        
        # 创建NetworkManager配置文件
        cat > /etc/NetworkManager/conf.d/99-ethercat.conf << EOF
[keyfile]
unmanaged-devices=interface-name:$interface
EOF
        
        # 重新加载NetworkManager配置
        systemctl reload NetworkManager 2>/dev/null || true
        
        log_success "已禁用NetworkManager对 $interface 的管理"
    fi
}

# 编译和安装内核模块
rebuild_kernel_modules() {
    log_info "正在重新编译内核模块..."
    
    local build_dir="/usr/src/ethercat"
    
    if [[ ! -d "$build_dir" ]]; then
        log_error "源码目录不存在: $build_dir"
        exit 1
    fi
    
    cd "$build_dir"
    
    # 重新编译内核模块
    make modules
    make modules_install
    
    # 更新模块依赖
    depmod -a
    
    log_success "内核模块重新编译完成"
}

# 加载内核模块
load_kernel_modules() {
    log_info "正在加载EtherCAT内核模块..."
    
    # 卸载现有模块（如果已加载）
    local modules=("ec_generic" "ec_master")
    for module in "${modules[@]}"; do
        if lsmod | grep -q "^${module}"; then
            rmmod "$module" 2>/dev/null || log_warning "无法卸载模块: $module"
        fi
    done
    
    # 加载主模块
    if modprobe ec_master; then
        log_success "EtherCAT主模块加载成功"
    else
        log_error "EtherCAT主模块加载失败"
        return 1
    fi
    
    # 加载设备模块
    if modprobe ec_generic; then
        log_success "EtherCAT通用设备模块加载成功"
    else
        log_error "EtherCAT通用设备模块加载失败"
        return 1
    fi
    
    # 显示已加载的模块
    log_info "已加载的EtherCAT模块:"
    lsmod | grep "^ec_" | sed 's/^/  /'
}

# 启动EtherCAT服务
start_ethercat_service() {
    log_info "正在启动EtherCAT服务..."
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启动服务
    if systemctl start ethercat; then
        log_success "EtherCAT服务启动成功"
    else
        log_error "EtherCAT服务启动失败"
        log_info "查看服务状态:"
        systemctl status ethercat --no-pager || true
        return 1
    fi
    
    # 检查服务状态
    sleep 2
    if systemctl is-active --quiet ethercat; then
        log_success "EtherCAT服务运行正常"
    else
        log_warning "EtherCAT服务状态异常"
    fi
}

# 验证EtherCAT功能
verify_ethercat() {
    log_info "正在验证EtherCAT功能..."
    
    # 检查设备文件
    if [[ -c "/dev/EtherCAT0" ]]; then
        log_success "EtherCAT设备文件存在: /dev/EtherCAT0"
    else
        log_warning "EtherCAT设备文件不存在: /dev/EtherCAT0"
    fi
    
    # 测试ethercat命令
    sleep 1
    if ethercat master 2>/dev/null; then
        log_success "EtherCAT主站通信正常"
        echo ""
        log_info "主站状态:"
        ethercat master | sed 's/^/  /'
        
        echo ""
        log_info "扫描从站:"
        ethercat slaves | sed 's/^/  /' || echo "  没有检测到从站设备"
        
    else
        log_warning "EtherCAT主站通信异常，可能的原因："
        echo "  1. 网卡还没有EtherCAT设备连接"
        echo "  2. 需要重启系统以完全加载驱动"
        echo "  3. 硬件连接问题"
    fi
}

# 显示配置摘要
show_configuration_summary() {
    local interface="$1"
    
    echo ""
    log_success "========================================="
    log_success "EtherCAT网卡绑定和服务启动完成！"
    log_success "========================================="
    echo ""
    log_info "配置摘要："
    echo "  绑定网卡: $interface"
    echo "  配置文件: /opt/etherlab/etc/sysconfig/ethercat"
    echo "  服务状态: $(systemctl is-active ethercat 2>/dev/null || echo '未知')"
    echo ""
    log_info "常用命令："
    echo "  ethercat master           - 显示主站信息"
    echo "  ethercat slaves           - 显示从站信息"
    echo "  systemctl status ethercat - 检查服务状态"
    echo "  systemctl restart ethercat - 重启服务"
    echo ""
    log_info "如需修改配置，请编辑: /opt/etherlab/etc/sysconfig/ethercat"
    log_info "如需重新绑定网卡，请重新运行此脚本"
    echo ""
}

# 显示帮助信息
show_help() {
    echo "EtherCAT网卡绑定和服务启动脚本"
    echo ""
    echo "用法: $0 [选项] [网卡名称]"
    echo ""
    echo "选项:"
    echo "  -h, --help        显示此帮助信息"
    echo "  -l, --list        仅显示可用网络接口"
    echo "  -r, --rebuild     重新编译内核模块"
    echo "  -s, --status      显示当前状态"
    echo ""
    echo "示例:"
    echo "  $0                    # 交互式选择网卡"
    echo "  $0 eth0              # 直接绑定eth0网卡"
    echo "  $0 --list            # 显示可用网卡"
    echo "  $0 --rebuild         # 重新编译模块"
    echo ""
}

# 显示当前状态
show_status() {
    echo "EtherCAT系统状态"
    echo "================"
    echo ""
    
    # 服务状态
    echo "服务状态:"
    systemctl status ethercat --no-pager | sed 's/^/  /' || echo "  服务未安装"
    echo ""
    
    # 模块状态
    echo "内核模块状态:"
    lsmod | grep "^ec_" | sed 's/^/  /' || echo "  没有加载的EtherCAT模块"
    echo ""
    
    # 配置信息
    if [[ -f "/opt/etherlab/etc/sysconfig/ethercat" ]]; then
        echo "当前配置:"
        grep -E "^[A-Z_]+=.*$" /opt/etherlab/etc/sysconfig/ethercat | grep -v "^#" | sed 's/^/  /'
    else
        echo "配置文件不存在"
    fi
    echo ""
    
    # 设备文件
    echo "设备文件:"
    if [[ -c "/dev/EtherCAT0" ]]; then
        ls -l /dev/EtherCAT* | sed 's/^/  /'
    else
        echo "  没有EtherCAT设备文件"
    fi
    echo ""
}

# 主函数
main() {
    local interface=""
    local rebuild_only=false
    local list_only=false
    local status_only=false
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                show_network_interfaces
                exit 0
                ;;
            -r|--rebuild)
                rebuild_only=true
                shift
                ;;
            -s|--status)
                show_status
                exit 0
                ;;
            -*)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                interface="$1"
                shift
                ;;
        esac
    done
    
    echo "EtherCAT网卡绑定和服务启动脚本"
    echo "生成时间: $(date)"
    echo ""
    
    check_root
    check_installation
    
    # 仅重新编译模块
    if [[ "$rebuild_only" == true ]]; then
        rebuild_kernel_modules
        log_info "内核模块重新编译完成，请运行完整的启动流程"
        exit 0
    fi
    
    log_info "准备选择网络接口..."
    
    # 如果没有指定网卡，交互式选择
    if [[ -z "$interface" ]]; then
        log_info "进入交互式网卡选择..."
        interface=$(select_interface)
        log_info "网卡选择完成: $interface"
    else
        # 验证指定的网卡是否存在
        if ! ip link show "$interface" &>/dev/null; then
            log_error "指定的网卡 '$interface' 不存在"
            show_network_interfaces
            exit 1
        fi
    fi
    
    # 执行配置流程
    configure_ethercat_interface "$interface"
    disable_networkmanager "$interface"
    rebuild_kernel_modules
    load_kernel_modules
    start_ethercat_service
    verify_ethercat
    show_configuration_summary "$interface"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
