#!/bin/bash

# IGH EtherCAT Master 网卡绑定和服务启动脚本
# 作者: RUIO
# 许可协议: MIT
# 日期: 2025-09-06
# 版本: 1.0

set -e  # 遇到错误立即退出

# 在脚本启动时解析真实目录；后续模块构建可能切换工作目录。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# 允许运行 sudo 的普通用户读取 /dev/EtherCAT*；新组成员资格需重新登录后生效。
grant_invoking_user_access() {
    local login_user="${SUDO_USER:-}"
    if [[ -n "$login_user" && "$login_user" != "root" ]] \
        && getent passwd "$login_user" >/dev/null \
        && ! id -nG "$login_user" | tr ' ' '\n' | grep -qx ethercat; then
        usermod -aG ethercat "$login_user"
        log_info "已将用户 $login_user 加入 ethercat 组；重新登录后权限生效"
    fi
}

# 获取接口类型提示
interface_hint() {
    local iface="$1"
    local type_val=""
    [[ -r "/sys/class/net/$iface/type" ]] && type_val="$(cat "/sys/class/net/$iface/type")"

    if [[ -d "/sys/class/net/$iface/wireless" ]] || [[ "$iface" =~ ^(wl|ww) ]]; then
        echo -e "${YELLOW}[无线-不推荐]${NC}"
    elif [[ -d "/sys/class/net/$iface/bridge" ]] || [[ "$iface" =~ ^(docker|br-|virbr) ]]; then
        echo -e "${YELLOW}[桥接/虚拟-不推荐]${NC}"
    elif [[ "$iface" =~ ^veth ]]; then
        echo -e "${YELLOW}[容器虚拟-不推荐]${NC}"
    elif [[ "$iface" =~ ^(tailscale|tun|tap|wg) ]]; then
        echo -e "${YELLOW}[VPN/隧道-不推荐]${NC}"
    elif [[ "$iface" =~ ^enx ]]; then
        echo -e "${GREEN}[USB转以太网-推荐]${NC}"
    elif [[ "$iface" =~ ^(en|eth) ]] && [[ "$type_val" == "1" ]]; then
        echo -e "${GREEN}[有线以太网-推荐]${NC}"
    fi
}

# 判断接口是否是“正在使用的默认路由”
is_default_gateway_interface() {
    local iface="$1"
    local gw_iface
    gw_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    [[ "$gw_iface" == "$iface" ]]
}

interface_mac_address() {
    local interface="$1"
    local hex

    if [[ "$interface" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        printf '%s\n' "${interface,,}"
        return 0
    fi
    if [[ -r "/sys/class/net/$interface/address" ]]; then
        tr '[:upper:]' '[:lower:]' < "/sys/class/net/$interface/address"
        return 0
    fi
    if [[ "$interface" =~ ^enx([0-9A-Fa-f]{12})$ ]]; then
        hex="${BASH_REMATCH[1],,}"
        printf '%s:%s:%s:%s:%s:%s\n' "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" \
            "${hex:6:2}" "${hex:8:2}" "${hex:10:2}"
        return 0
    fi
    log_error "无法获取接口 $interface 的 MAC 地址；请在网卡已连接时运行，或将 MASTER0_DEVICE 配置为 MAC 地址"
    return 1
}

# 脚本可能被从 /usr/src/ethercat、软链接或项目目录调用；解析器始终从
# 实际可用的位置安装，避免绑定流程在重建模块后因辅助脚本路径错误中断。
install_interface_resolver() {
    local candidate

    for candidate in \
        "$SCRIPT_DIR/ethercat_interface_resolver.sh" \
        "$PWD/ethercat_interface_resolver.sh" \
        "/opt/etherlab/libexec/ethercat-interface-resolver"; do
        if [[ -f "$candidate" ]]; then
            install -D -m 0755 "$candidate" /usr/local/libexec/ethercat-interface-resolver
            return 0
        fi
    done

    log_error "找不到 ethercat_interface_resolver.sh；请从完整工具包目录运行此脚本"
    return 1
}

# 收集接口信息到并列数组
# 结果写入全局数组 INTERFACES / INTERFACE_LABELS
collect_interfaces() {
    INTERFACES=()
    INTERFACE_LABELS=()

    local line iface ip_addr link_state speed carrier hint info
    while IFS= read -r line; do
        if [[ $line =~ ^[0-9]+:\ ([^:@]+)[@:]? ]]; then
            iface="${BASH_REMATCH[1]}"
            [[ "$iface" == "lo" ]] && continue
            [[ "$iface" =~ ^ecdbgm ]] && continue

            ip_addr=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
            link_state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
            carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "0")
            speed=""
            if command -v ethtool >/dev/null 2>&1; then
                speed=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/{print $2; exit}' | xargs)
            fi
            hint=$(interface_hint "$iface")

            info="$iface"
            [[ -n "$ip_addr" ]]    && info+=" (IP: $ip_addr)"
            [[ -n "$link_state" ]] && info+=" [状态: $link_state]"
            [[ "$carrier" == "1" ]] && info+=" [连接: 已插线]" || info+=" [连接: 无载波]"
            [[ -n "$speed" ]]      && info+=" [速度: $speed]"
            [[ -n "$hint" ]]       && info+=" $hint"

            INTERFACES+=("$iface")
            INTERFACE_LABELS+=("$info")
        fi
    done < <(ip link show 2>/dev/null)
}

# 仅显示接口列表（供 --list 使用）
show_network_interfaces() {
    collect_interfaces
    echo ""
    echo -e "${BLUE}当前网络接口:${NC}"
    local i
    for i in "${!INTERFACES[@]}"; do
        echo -e "  $((i+1)). ${INTERFACE_LABELS[$i]}"
    done
    echo ""
}

# 交互式选择网卡（通过编号选择，带警告）
select_interface() {
    collect_interfaces

    if [[ ${#INTERFACES[@]} -eq 0 ]]; then
        log_error "未检测到任何网络接口" >&2
        exit 1
    fi

    {
        echo ""
        echo -e "${BLUE}可用的网络接口:${NC}"
        local i
        for i in "${!INTERFACES[@]}"; do
            echo -e "  $((i+1)). ${INTERFACE_LABELS[$i]}"
        done
        echo ""
        echo -e "${BLUE}提示：${NC}请选择带${GREEN}[推荐]${NC}标签的有线以太网；避免选择无线/容器/VPN 虚拟接口。"
        echo ""
    } >&2

    local idx selected
    while true; do
        echo -n -e "${YELLOW}请选择用于 EtherCAT 的网卡 [1-${#INTERFACES[@]}]: ${NC}" >&2
        read -r idx
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#INTERFACES[@]} )); then
            selected="${INTERFACES[$((idx-1))]}"
            break
        fi
        log_error "无效选择" >&2
    done

    # 使用中接口警告
    if is_default_gateway_interface "$selected"; then
        log_warning "接口 '$selected' 当前是系统的默认网关，绑定后将失去上网能力！" >&2
        local confirm
        echo -n -e "${YELLOW}确认继续？[y/N]: ${NC}" >&2
        read -r confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消" >&2; exit 0; }
    fi

    echo "$selected"
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

# 通过持久 MAC 地址识别目标网卡，避免 USB 网卡重插时临时接口名称变化。
# 监视器在后台检查，不会因网卡缺失而阻塞系统启动。
configure_systemd_service_for_interface() {
    local interface="$1"
    local interface_mac

    interface_mac="$(interface_mac_address "$interface")"
    install_interface_resolver
    log_info "正在配置非阻塞开机和网卡热插拔自动加载..."

    cat > /etc/systemd/system/ethercat.service << EOF
[Unit]
Description=EtherCAT Master Service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStartPre=/usr/local/libexec/ethercat-interface-resolver $interface_mac /opt/etherlab/etc/sysconfig/ethercat --apply
ExecStart=/etc/init.d/ethercat start
ExecStop=/etc/init.d/ethercat stop
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

EOF

    cat > /etc/systemd/system/ethercat-monitor.service << EOF
[Unit]
Description=EtherCAT interface recovery monitor
After=multi-user.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'while :; do if /usr/local/libexec/ethercat-interface-resolver $interface_mac /opt/etherlab/etc/sysconfig/ethercat >/dev/null; then /usr/bin/systemctl is-active --quiet ethercat.service || /usr/bin/systemctl start ethercat.service; else /usr/bin/systemctl is-active --quiet ethercat.service && /usr/bin/systemctl stop ethercat.service || true; fi; sleep 2; done'
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl disable --now ethercat.timer 2>/dev/null || true
    rm -f /etc/systemd/system/ethercat.timer
    systemctl disable --now ethercat.path 2>/dev/null || true
    rm -f /etc/systemd/system/ethercat.path
    rm -f /etc/udev/rules.d/80-ethercat-autostart.rules
    systemctl daemon-reload
    systemctl disable ethercat.service 2>/dev/null || true
    systemctl enable --now ethercat-monitor.service >/dev/null
    systemctl restart ethercat-monitor.service
    log_success "已设置基于 MAC 的自动加载；网卡重命名与重插均可恢复"
}

# 停止NetworkManager对指定网卡的管理
disable_networkmanager() {
    local interface="$1"
    local interface_mac=""
    interface_mac="$(interface_mac_address "$interface" 2>/dev/null || true)"
    
    # 无论 NetworkManager 当前是否已运行，都写入持久化配置，确保重启后不会
    # 抢占 EtherCAT 专用接口。USB 网卡可能重插后改名，所以同时按 MAC 忽略。
    mkdir -p /etc/NetworkManager/conf.d
    rm -f /etc/NetworkManager/conf.d/99-ethercat-release.conf
    cat > /etc/NetworkManager/conf.d/99-ethercat.conf << EOF
[keyfile]
# ecdbgm* 是 EtherCAT 主站创建的内部调试网卡，不得由 NetworkManager
# 自动建立 DHCP 连接，否则会产生多余的“有线连接”并干扰主站通信。
unmanaged-devices=interface-name:$interface${interface_mac:+,mac:$interface_mac},interface-name:ecdbgm*
EOF

    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        log_info "检测到NetworkManager，正在禁用对 $interface 的管理..."

        # 先释放可能残留的普通网络连接，再应用持久规则。
        nmcli device disconnect "$interface" 2>/dev/null || true
        nmcli device set "$interface" managed no 2>/dev/null || true
        systemctl reload NetworkManager 2>/dev/null || true
        if [[ "$(nmcli -g GENERAL.NM-MANAGED device show "$interface" 2>/dev/null || true)" =~ ^(no|否)$ ]]; then
            log_success "已禁用NetworkManager对 $interface 的管理"
        else
            log_error "NetworkManager 仍在管理 $interface"
            return 1
        fi
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
    
    # 重新编译内核模块
    make -C "$build_dir" modules
    make -C "$build_dir" modules_install
    
    # 更新模块依赖
    depmod -a
    
    log_success "内核模块重新编译完成"
}

# 卸载 EtherCAT 内核模块（让 ethercat 服务带正确的 MAC 参数自己加载）
unload_kernel_modules() {
    log_info "卸载已加载的 EtherCAT 内核模块（由服务重新按 MAC 绑定加载）..."

    # 先停服务，避免服务引用模块导致无法卸载
    if systemctl is-active --quiet ethercat 2>/dev/null; then
        systemctl stop ethercat 2>/dev/null || true
    fi

    # 按依赖顺序卸载：先子模块（ec_generic 等），再 ec_master
    local ec_modules
    ec_modules=$(lsmod | awk '/^ec_/ {print $1}' || true)
    if [[ -n "$ec_modules" ]]; then
        for m in $(echo "$ec_modules" | grep -v '^ec_master$' || true); do
            rmmod "$m" 2>/dev/null && log_info "  - 已卸载 $m" \
                || log_warning "  - 无法卸载 $m"
        done
        if lsmod | grep -q '^ec_master'; then
            rmmod ec_master 2>/dev/null && log_info "  - 已卸载 ec_master" \
                || log_warning "  - 无法卸载 ec_master（可能仍被占用）"
        fi
    else
        log_info "当前没有加载 EtherCAT 模块"
    fi
}

# 重新绑定期间暂停自动恢复，避免其在模块重建或卸载过程中抢先启动主站。
pause_recovery_monitor() {
    if systemctl is-active --quiet ethercat-monitor.service 2>/dev/null; then
        log_info "暂时停止 EtherCAT 自动恢复监视器..."
        systemctl stop ethercat-monitor.service
    fi
}

# 启动EtherCAT服务
ethercat_slave_identity_available() {
    local ec_bin="$1" scan
    scan="$($ec_bin slaves -v 2>/dev/null || true)"
    grep -qE 'Vendor Id:[[:space:]]+0x0*[1-9a-fA-F][0-9a-fA-F]*' <<< "$scan" \
        && grep -qE 'Product code:[[:space:]]+0x0*[1-9a-fA-F][0-9a-fA-F]*' <<< "$scan"
}

start_ethercat_service() {
    log_info "正在启动EtherCAT服务..."
    local ec_bin=""

    if command -v ethercat >/dev/null 2>&1; then
        ec_bin="ethercat"
    elif [[ -x "/opt/etherlab/bin/ethercat" ]]; then
        ec_bin="/opt/etherlab/bin/ethercat"
    fi
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启动服务（ethercat 启动脚本会读取 MASTER0_DEVICE 的 MAC，
    # 并以 'modprobe ec_master main_devices=<MAC>' 的方式加载模块）
    if systemctl restart ethercat; then
        log_success "EtherCAT服务启动成功"
    else
        log_error "EtherCAT服务启动失败"
        log_info "查看服务状态:"
        systemctl status ethercat --no-pager || true
        journalctl -u ethercat -n 30 --no-pager || true
        return 1
    fi
    
    # systemctl restart 会等待 oneshot 服务完成，此时应已可立即检查设备。
    if systemctl is-active --quiet ethercat; then
        log_success "EtherCAT服务运行正常"
    else
        log_warning "EtherCAT服务状态异常"
    fi

    # 校验设备文件是否已创建
    if [[ -c "/dev/EtherCAT0" ]]; then
        log_success "主站设备文件已创建: /dev/EtherCAT0"
    else
        log_warning "未发现 /dev/EtherCAT0，模块可能未正确绑定到网卡 MAC"
        log_info "检查 modprobe 参数: $(grep -h '^options ec_master' /etc/modprobe.d/*.conf 2>/dev/null || echo '（无）')"
    fi

    # 身份读取由主站后台持续扫描；不能在此处反复重启服务，否则会中断
    # 正在进行的扫描并使重新绑定流程不必要地失败。
    if [[ -n "$ec_bin" ]] && ! ethercat_slave_identity_available "$ec_bin"; then
        log_warning "从站 SII 身份尚未读取完成；主站将继续后台扫描，不重启服务"
    fi
}

# 验证EtherCAT功能
verify_ethercat() {
    log_info "正在验证EtherCAT功能..."

    # 确保 ethercat CLI 可用
    local ec_bin=""
    if command -v ethercat >/dev/null 2>&1; then
        ec_bin="ethercat"
    elif [[ -x "/opt/etherlab/bin/ethercat" ]]; then
        ec_bin="/opt/etherlab/bin/ethercat"
        log_info "使用 $ec_bin（未在 PATH 中）"
    else
        log_warning "未找到 ethercat 命令（/opt/etherlab/bin/ethercat 不存在）"
    fi

    # 检查设备文件
    if [[ -c "/dev/EtherCAT0" ]]; then
        log_success "EtherCAT 设备文件存在: /dev/EtherCAT0"
    else
        log_warning "EtherCAT 设备文件不存在: /dev/EtherCAT0"
    fi

    if [[ -n "$ec_bin" ]] && $ec_bin master >/dev/null 2>&1; then
        log_success "EtherCAT 主站通信正常"
        echo ""
        log_info "主站状态:"
        $ec_bin master | sed 's/^/  /'
        echo ""
        log_info "扫描从站:"
        $ec_bin slaves 2>/dev/null | sed 's/^/  /' || echo "  （无从站设备）"
    else
        log_warning "EtherCAT 主站通信异常，可能的原因："
        echo "  1. 网卡尚未连接 EtherCAT 从站设备"
        echo "  2. 链路无载波（未插网线）"
        echo "  3. 需要重启系统以完全加载驱动"
        echo "  4. 硬件连接问题"
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
    echo "  --install-boot-fix 安装开机自动绑定修复（无需网卡当前在线）"
    echo ""
    echo "示例:"
    echo "  $0                    # 交互式选择网卡"
    echo "  $0 eth0              # 直接绑定eth0网卡"
    echo "  $0 --list            # 显示可用网卡"
    echo "  $0 --rebuild         # 重新编译模块"
    echo "  $0 --install-boot-fix # 修复已部署系统的开机自动绑定"
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
    local install_boot_fix_only=false
    
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
            --install-boot-fix)
                install_boot_fix_only=true
                shift
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
    grant_invoking_user_access

    # 从现有配置读取接口名称。此模式不要求 USB 网卡已经被系统枚举，
    # 因而可用于修复“开机过早启动导致接口不存在”的系统。
    if [[ "$install_boot_fix_only" == true ]]; then
        interface=$(sed -n 's/^MASTER0_DEVICE="\([^"]*\)".*/\1/p' \
            /opt/etherlab/etc/sysconfig/ethercat | head -n 1)
        if [[ -z "$interface" ]]; then
            log_error "未能从 EtherCAT 配置读取 MASTER0_DEVICE"
            exit 1
        fi
        configure_systemd_service_for_interface "$interface"
        disable_networkmanager "$interface"
        systemctl restart ethercat
        log_success "开机自动绑定修复已安装，目标网卡: $interface"
        exit 0
    fi
    
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
        # 指定网卡：如果它是默认网关，给出严重警告
        if is_default_gateway_interface "$interface"; then
            log_warning "接口 '$interface' 当前是默认网关，绑定后将失去上网能力！"
            echo -n -e "${YELLOW}确认继续？[y/N]: ${NC}"
            read -r confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消"; exit 0; }
        fi
    fi

    # 检查物理连接
    local carrier
    carrier=$(cat "/sys/class/net/$interface/carrier" 2>/dev/null || echo "0")
    if [[ "$carrier" != "1" ]]; then
        log_warning "接口 '$interface' 当前未检测到网线连接（carrier=$carrier）"
        log_warning "EtherCAT 将无法扫描到从站，请确保网线已连接到 EtherCAT 从站设备"
    fi
    
    # 执行配置流程
    pause_recovery_monitor
    configure_ethercat_interface "$interface"
    disable_networkmanager "$interface"
    rebuild_kernel_modules
    unload_kernel_modules
    configure_systemd_service_for_interface "$interface"
    start_ethercat_service
    verify_ethercat
    show_configuration_summary "$interface"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
