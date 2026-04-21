#!/bin/bash

# 网络接口恢复脚本
# 用于在 EtherCAT 卸载/停用后恢复网络连接和 NetworkManager 托管
# 作者: RUIO
# 版本: 2.1

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

TARGET_INTERFACE=""
SKIP_DHCP=false

# 帮助信息
show_help() {
    cat <<EOF
网络接口恢复脚本

用法: sudo $0 [选项] [接口名]

选项:
  -h, --help         显示此帮助
  -i, --iface NAME   仅恢复指定接口（例如 enx00e04c5f63b8）
  --skip-dhcp        不主动触发 DHCP 获取 IP

示例:
  sudo $0                       # 恢复所有以太网接口
  sudo $0 enp2s0                # 仅恢复 enp2s0
  sudo $0 -i enx00e04c5f63b8    # 同上（选项形式）
EOF
}

# 参数解析
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -i|--iface) TARGET_INTERFACE="$2"; shift 2 ;;
            --skip-dhcp) SKIP_DHCP=true; shift ;;
            -*) log_error "未知选项: $1"; show_help; exit 1 ;;
            *)  TARGET_INTERFACE="$1"; shift ;;
        esac
    done
}

# 检查 root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限，请使用 sudo 执行"
        exit 1
    fi
}

# 停止 EtherCAT 服务并卸载内核模块
stop_ethercat_stack() {
    log_info "停止 EtherCAT 服务与内核模块..."

    if systemctl list-unit-files 2>/dev/null | grep -q '^ethercat\.service'; then
        if systemctl is-active --quiet ethercat 2>/dev/null; then
            systemctl stop ethercat 2>/dev/null || log_warning "停止 ethercat 服务失败"
            log_info "已停止 ethercat 服务"
        fi
    fi

    # 卸载 EtherCAT 相关内核模块（先卸子模块，再卸 ec_master）
    local ec_modules
    ec_modules=$(lsmod | awk '/^ec_/ {print $1}' || true)
    if [[ -n "$ec_modules" ]]; then
        for m in $(echo "$ec_modules" | grep -v '^ec_master$' || true); do
            rmmod "$m" 2>/dev/null && log_info "已卸载模块: $m" \
                || log_warning "无法卸载模块: $m"
        done
        if lsmod | grep -q '^ec_master'; then
            rmmod ec_master 2>/dev/null && log_info "已卸载模块: ec_master" \
                || log_warning "无法卸载模块: ec_master（可能仍被占用）"
        fi
    else
        log_info "未检测到已加载的 EtherCAT 模块"
    fi
}

# 清除 EtherCAT 遗留的 NetworkManager 非托管配置
clear_nm_unmanaged_config() {
    local conf="/etc/NetworkManager/conf.d/99-ethercat.conf"
    if [[ -f "$conf" ]]; then
        log_info "删除 NetworkManager 非托管配置: $conf"
        rm -f "$conf"
    fi
}

# 重新加载常见网络驱动模块
reload_network_drivers() {
    log_info "尝试重新加载常见网络驱动模块..."
    local modules=(ax88179_178a cdc_ether r8152 r8169 e1000 e1000e igb ixgbe)
    for m in "${modules[@]}"; do
        if modinfo "$m" >/dev/null 2>&1; then
            modprobe "$m" 2>/dev/null && log_info "  + $m" || true
        fi
    done

    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=net 2>/dev/null || true
    sleep 2
}

# 获取需要处理的接口列表
get_target_interfaces() {
    if [[ -n "$TARGET_INTERFACE" ]]; then
        if ! ip link show "$TARGET_INTERFACE" &>/dev/null; then
            log_error "接口不存在: $TARGET_INTERFACE"
            exit 1
        fi
        echo "$TARGET_INTERFACE"
        return
    fi

    # 自动识别有线以太网接口（排除虚拟/无线）
    local iface type_val
    for iface in /sys/class/net/*; do
        iface="$(basename "$iface")"
        [[ "$iface" == "lo" ]] && continue
        [[ "$iface" =~ ^(docker|br-|veth|virbr|wl|ww|tailscale|tun|tap|wg) ]] && continue
        [[ -d "/sys/class/net/$iface/wireless" ]] && continue
        [[ -d "/sys/class/net/$iface/bridge" ]] && continue
        type_val="$(cat "/sys/class/net/$iface/type" 2>/dev/null || echo)"
        [[ "$type_val" != "1" ]] && continue
        echo "$iface"
    done
}

# 启用物理链路
bring_up_interfaces() {
    local interfaces=("$@")
    for iface in "${interfaces[@]}"; do
        local state
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        log_info "启用接口 $iface (当前: $state)"
        ip link set "$iface" up 2>/dev/null \
            && log_success "接口 $iface 已 up" \
            || log_warning "接口 $iface 启用失败"
    done
    sleep 2
}

# 重启 NetworkManager
restart_nm() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        log_info "重启 NetworkManager..."
        systemctl restart NetworkManager
        sleep 4
    else
        log_warning "NetworkManager 未运行（跳过重启）"
    fi
}

# 恢复 NetworkManager 托管
restore_nm_management() {
    local interfaces=("$@")

    if ! command -v nmcli &>/dev/null; then
        log_warning "nmcli 不可用，跳过 NetworkManager 托管恢复"
        return
    fi

    for iface in "${interfaces[@]}"; do
        log_info "恢复 $iface 的 NetworkManager 托管..."
        nmcli device set "$iface" managed yes 2>/dev/null \
            || log_warning "  设置 managed 失败"
        sleep 1

        # 查找现有连接（按接口名过滤）
        local con_name
        con_name=$(nmcli -g NAME,DEVICE connection show 2>/dev/null \
                   | awk -F: -v d="$iface" '$2==d {print $1; exit}')

        if [[ -n "$con_name" ]]; then
            log_info "  找到连接: $con_name，启用自动连接"
            nmcli connection modify "$con_name" connection.autoconnect yes 2>/dev/null || true
            nmcli connection up "$con_name" 2>/dev/null \
                && log_success "  已激活连接 $con_name" \
                || log_warning "  连接 $con_name 激活失败（可能未插网线）"
        else
            log_info "  无现有连接，创建 DHCP 以太网连接"
            nmcli connection add type ethernet ifname "$iface" con-name "$iface" \
                autoconnect yes 2>/dev/null \
                && log_success "  已创建连接 $iface" \
                || log_warning "  创建连接失败"
            nmcli connection up "$iface" 2>/dev/null || true
        fi
    done
    sleep 3
}

# 若 NetworkManager 不可用，手动触发 DHCP
fallback_dhcp() {
    local interfaces=("$@")
    [[ "$SKIP_DHCP" == true ]] && return
    if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; then
        return
    fi

    log_info "NetworkManager 不可用，尝试通过 dhclient 获取 IP..."
    for iface in "${interfaces[@]}"; do
        if command -v dhclient &>/dev/null; then
            dhclient -r "$iface" 2>/dev/null || true
            dhclient "$iface" 2>/dev/null \
                && log_success "  $iface 已获取 DHCP 地址" \
                || log_warning "  $iface DHCP 失败"
        elif command -v dhcpcd &>/dev/null; then
            dhcpcd "$iface" 2>/dev/null || true
        fi
    done
}

# 显示结果
show_network_status() {
    echo ""
    log_info "====== 恢复后网络状态 ======"
    echo ""

    if command -v nmcli &>/dev/null; then
        echo -e "${BLUE}NetworkManager 设备状态:${NC}"
        nmcli device status | sed 's/^/  /'
        echo ""
    fi

    echo -e "${BLUE}接口与 IP:${NC}"
    ip -brief addr show | sed 's/^/  /'
    echo ""

    echo -e "${BLUE}默认路由:${NC}"
    ip route show default | sed 's/^/  /' || echo "  （无默认路由）"
    echo ""

    echo -e "${BLUE}连通性测试:${NC}"
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        log_success "  外网可达 (ping 1.1.1.1 OK)"
    else
        log_warning "  外网不可达，请检查网线/路由/DNS"
    fi
}

# 手动恢复指引
show_manual_instructions() {
    cat <<'EOF'

如果自动恢复未完全成功，可手动执行：

  # 删除 EtherCAT 遗留的 NM 非托管配置
  sudo rm -f /etc/NetworkManager/conf.d/99-ethercat.conf
  sudo systemctl restart NetworkManager

  # 启用接口
  sudo ip link set <iface> up
  sudo nmcli device set <iface> managed yes
  sudo nmcli connection up <iface>     # 或创建新连接：
  sudo nmcli connection add type ethernet ifname <iface> con-name <iface> autoconnect yes

  # 手动 DHCP
  sudo dhclient <iface>

EOF
}

main() {
    parse_args "$@"
    check_root

    echo ""
    log_info "========================================="
    log_info "  网络接口恢复脚本 v2.1"
    log_info "========================================="
    echo ""

    stop_ethercat_stack
    clear_nm_unmanaged_config
    reload_network_drivers

    local interfaces=()
    mapfile -t interfaces < <(get_target_interfaces)

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_error "未找到任何以太网接口"
        show_manual_instructions
        exit 1
    fi

    log_success "待恢复接口: ${interfaces[*]}"
    bring_up_interfaces "${interfaces[@]}"
    restart_nm
    restore_nm_management "${interfaces[@]}"
    fallback_dhcp "${interfaces[@]}"
    show_network_status

    echo ""
    log_success "========================================="
    log_success "  网络恢复流程结束"
    log_success "========================================="
    show_manual_instructions
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
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