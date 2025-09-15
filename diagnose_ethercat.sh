#!/bin/bash

# IGH EtherCAT Master 状态检查和诊断脚本
# 作者: GitHub Copilot
# 日期: 2025-09-06
# 版本: 1.0

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 状态符号
CHECK_MARK="✓"
CROSS_MARK="✗"
WARNING_MARK="⚠"

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[${CHECK_MARK}]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[${WARNING_MARK}]${NC} $1"
}

log_error() {
    echo -e "${RED}[${CROSS_MARK}]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}===========================================${NC}"
}

# 检查安装状态
check_installation() {
    log_section "检查安装状态"
    
    # 检查安装目录
    if [[ -d "/opt/etherlab" ]]; then
        log_success "安装目录存在: /opt/etherlab"
        
        # 检查关键文件
        local key_files=("bin/ethercat" "lib/libethercat.so" "sbin/ethercatctl")
        for file in "${key_files[@]}"; do
            if [[ -f "/opt/etherlab/$file" ]]; then
                log_success "关键文件存在: $file"
            else
                log_warning "关键文件缺失: $file"
            fi
        done
    else
        log_error "安装目录不存在: /opt/etherlab"
        return 1
    fi
    
    # 检查命令可用性
    if command -v ethercat &> /dev/null; then
        local version=$(ethercat version 2>/dev/null || echo "未知")
        log_success "ethercat命令可用 (版本: $version)"
    else
        log_warning "ethercat命令不可用，请检查PATH设置"
    fi
}

# 检查内核模块状态
check_kernel_modules() {
    log_section "检查内核模块状态"
    
    local modules=("ec_master" "ec_generic")
    local loaded_modules=()
    
    for module in "${modules[@]}"; do
        if lsmod | grep -q "^${module}"; then
            log_success "内核模块已加载: $module"
            loaded_modules+=("$module")
        else
            log_warning "内核模块未加载: $module"
        fi
    done
    
    # 显示模块详细信息
    if [[ ${#loaded_modules[@]} -gt 0 ]]; then
        echo ""
        log_info "已加载模块详细信息:"
        for module in "${loaded_modules[@]}"; do
            modinfo "$module" 2>/dev/null | grep -E "(version|description|author)" | sed 's/^/  /'
        done
    fi
}

# 检查服务状态
check_service_status() {
    log_section "检查服务状态"
    
    # 检查systemd服务
    if systemctl list-unit-files | grep -q "ethercat.service"; then
        log_success "systemd服务文件存在"
        
        if systemctl is-enabled --quiet ethercat 2>/dev/null; then
            log_success "服务已启用"
        else
            log_warning "服务未启用"
        fi
        
        if systemctl is-active --quiet ethercat 2>/dev/null; then
            log_success "服务正在运行"
        else
            log_warning "服务未运行"
            
            # 显示服务状态详情
            echo ""
            log_info "服务状态详情:"
            systemctl status ethercat --no-pager 2>/dev/null | sed 's/^/  /' || echo "  无法获取服务状态"
        fi
    else
        log_error "systemd服务文件不存在"
    fi
    
    # 检查传统init脚本
    if [[ -f "/etc/init.d/ethercat" ]]; then
        log_success "init脚本存在: /etc/init.d/ethercat"
        if [[ -x "/etc/init.d/ethercat" ]]; then
            log_success "init脚本可执行"
        else
            log_warning "init脚本不可执行"
        fi
    else
        log_warning "init脚本不存在: /etc/init.d/ethercat"
    fi
}

# 检查配置文件
check_configuration() {
    log_section "检查配置文件"
    
    # 检查主配置文件
    if [[ -f "/etc/sysconfig/ethercat" ]]; then
        log_success "配置文件存在: /etc/sysconfig/ethercat"
        
        # 读取并显示关键配置
        echo ""
        log_info "当前配置:"
        while IFS= read -r line; do
            if [[ "$line" =~ ^[A-Z_]+=.*$ ]] && [[ ! "$line" =~ ^#.*$ ]]; then
                echo "  $line"
            fi
        done < /etc/sysconfig/ethercat
    else
        log_warning "配置文件不存在: /etc/sysconfig/ethercat"
    fi
    
    # 检查modprobe配置
    if [[ -f "/etc/modprobe.d/ethercat.conf" ]]; then
        log_success "模块配置文件存在: /etc/modprobe.d/ethercat.conf"
    else
        log_warning "模块配置文件不存在: /etc/modprobe.d/ethercat.conf"
    fi
    
    # 检查udev规则
    if [[ -f "/etc/udev/rules.d/99-ethercat.rules" ]]; then
        log_success "udev规则存在: /etc/udev/rules.d/99-ethercat.rules"
    else
        log_warning "udev规则不存在: /etc/udev/rules.d/99-ethercat.rules"
    fi
}

# 检查网络接口
check_network_interfaces() {
    log_section "检查网络接口"
    
    # 显示所有网络接口
    log_info "可用的网络接口:"
    ip link show | grep -E "^[0-9]+:" | sed 's/^/  /'
    
    # 检查配置的接口
    if [[ -f "/etc/sysconfig/ethercat" ]]; then
        local device=$(grep "^MASTER0_DEVICE=" /etc/sysconfig/ethercat 2>/dev/null | cut -d'=' -f2 | tr -d '"')
        if [[ -n "$device" ]]; then
            log_info "配置的主接口: $device"
            
            if ip link show "$device" &>/dev/null; then
                log_success "接口 $device 存在"
                
                # 显示接口状态
                local status=$(ip link show "$device" | grep -o "state [A-Z]*" | cut -d' ' -f2)
                log_info "接口状态: $status"
                
                # 检查是否被EtherCAT占用
                if [[ -d "/sys/class/net/$device/master" ]]; then
                    log_success "接口已被EtherCAT主站占用"
                else
                    log_warning "接口未被EtherCAT主站占用"
                fi
            else
                log_error "配置的接口 $device 不存在"
            fi
        else
            log_warning "未配置主接口"
        fi
    fi
}

# 检查EtherCAT主站状态
check_ethercat_master() {
    log_section "检查EtherCAT主站状态"
    
    if command -v ethercat &> /dev/null; then
        # 检查主站
        echo ""
        log_info "主站信息:"
        if ethercat master 2>/dev/null; then
            log_success "主站通信正常"
        else
            log_warning "无法获取主站信息，可能主站未启动或配置错误"
        fi
        
        # 检查从站
        echo ""
        log_info "从站信息:"
        if ethercat slaves 2>/dev/null; then
            log_success "从站扫描完成"
        else
            log_warning "无从站或无法扫描从站"
        fi
        
        # 检查配置
        echo ""
        log_info "配置信息:"
        if ethercat config 2>/dev/null; then
            log_success "配置信息获取成功"
        else
            log_warning "无法获取配置信息"
        fi
    else
        log_error "ethercat命令不可用"
    fi
}

# 检查用户权限
check_permissions() {
    log_section "检查用户权限"
    
    # 检查ethercat用户和组
    if getent passwd ethercat > /dev/null 2>&1; then
        log_success "ethercat用户存在"
    else
        log_warning "ethercat用户不存在"
    fi
    
    if getent group ethercat > /dev/null 2>&1; then
        log_success "ethercat组存在"
    else
        log_warning "ethercat组不存在"
    fi
    
    # 检查当前用户权限
    if groups | grep -q ethercat; then
        log_success "当前用户属于ethercat组"
    else
        log_warning "当前用户不属于ethercat组"
        log_info "运行以下命令将用户添加到ethercat组: sudo usermod -a -G ethercat \$USER"
    fi
    
    # 检查设备文件权限
    if [[ -c "/dev/EtherCAT0" ]]; then
        local perms=$(stat -c "%a %U:%G" /dev/EtherCAT0)
        log_success "EtherCAT设备文件存在: /dev/EtherCAT0 ($perms)"
    else
        log_warning "EtherCAT设备文件不存在: /dev/EtherCAT0"
    fi
}

# 检查系统资源
check_system_resources() {
    log_section "检查系统资源"
    
    # CPU信息
    local cpu_count=$(nproc)
    log_info "CPU核心数: $cpu_count"
    
    # 内存信息
    local mem_total=$(free -h | awk '/^Mem:/ {print $2}')
    local mem_available=$(free -h | awk '/^Mem:/ {print $7}')
    log_info "内存: 总计 $mem_total, 可用 $mem_available"
    
    # 负载信息
    local load=$(uptime | awk -F'load average:' '{print $2}')
    log_info "系统负载:$load"
    
    # 内核版本
    local kernel=$(uname -r)
    log_info "内核版本: $kernel"
    
    # 检查内核头文件
    if [[ -d "/lib/modules/$kernel/build" ]]; then
        log_success "内核头文件已安装"
    else
        log_warning "内核头文件未安装，可能影响模块编译"
    fi
}

# 生成诊断报告
generate_report() {
    log_section "生成诊断报告"
    
    local report_file="/tmp/ethercat_diagnostic_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "IGH EtherCAT Master 诊断报告"
        echo "生成时间: $(date)"
        echo "主机名: $(hostname)"
        echo "操作系统: $(lsb_release -d 2>/dev/null | cut -d: -f2 | xargs || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
        echo "内核版本: $(uname -r)"
        echo ""
        
        echo "=== 系统信息 ==="
        uname -a
        echo ""
        
        echo "=== 网络接口 ==="
        ip link show
        echo ""
        
        echo "=== 内核模块 ==="
        lsmod | grep ec_
        echo ""
        
        echo "=== 进程信息 ==="
        ps aux | grep -i ethercat | grep -v grep
        echo ""
        
        echo "=== 服务状态 ==="
        systemctl status ethercat --no-pager 2>/dev/null || echo "服务状态不可用"
        echo ""
        
        echo "=== EtherCAT信息 ==="
        if command -v ethercat &> /dev/null; then
            echo "--- 主站信息 ---"
            ethercat master 2>/dev/null || echo "主站信息不可用"
            echo ""
            echo "--- 从站信息 ---"
            ethercat slaves 2>/dev/null || echo "从站信息不可用"
            echo ""
        else
            echo "ethercat命令不可用"
        fi
        
        echo "=== 日志信息 ==="
        echo "--- 系统日志 (最近10行) ---"
        journalctl -u ethercat -n 10 --no-pager 2>/dev/null || echo "无法获取服务日志"
        echo ""
        echo "--- 内核日志 (EtherCAT相关) ---"
        dmesg | grep -i ethercat | tail -10 2>/dev/null || echo "无EtherCAT相关内核日志"
        
    } > "$report_file"
    
    log_success "诊断报告已生成: $report_file"
    log_info "您可以将此报告发送给技术支持以获得帮助"
}

# 显示帮助信息
show_help() {
    echo "IGH EtherCAT Master 诊断工具"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help        显示此帮助信息"
    echo "  -q, --quick       快速检查（仅基本状态）"
    echo "  -r, --report      生成详细诊断报告"
    echo "  -v, --verbose     详细输出模式"
    echo ""
    echo "不带参数运行将执行完整的诊断检查。"
}

# 快速检查
quick_check() {
    log_section "快速状态检查"
    
    # 检查安装
    if [[ -d "/opt/etherlab" ]]; then
        log_success "EtherCAT Master已安装"
    else
        log_error "EtherCAT Master未安装"
        return 1
    fi
    
    # 检查服务
    if systemctl is-active --quiet ethercat 2>/dev/null; then
        log_success "EtherCAT服务正在运行"
    else
        log_warning "EtherCAT服务未运行"
    fi
    
    # 检查主站
    if command -v ethercat &> /dev/null && ethercat master &>/dev/null; then
        log_success "EtherCAT主站通信正常"
    else
        log_warning "EtherCAT主站通信异常"
    fi
}

# 完整检查
full_check() {
    check_installation
    check_kernel_modules
    check_service_status
    check_configuration
    check_network_interfaces
    check_ethercat_master
    check_permissions
    check_system_resources
}

# 主函数
main() {
    local quick_mode=false
    local report_mode=false
    local verbose_mode=false
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -q|--quick)
                quick_mode=true
                shift
                ;;
            -r|--report)
                report_mode=true
                shift
                ;;
            -v|--verbose)
                verbose_mode=true
                shift
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    echo "IGH EtherCAT Master 诊断工具"
    echo "生成时间: $(date)"
    echo ""
    
    if [[ "$quick_mode" == true ]]; then
        quick_check
    else
        full_check
    fi
    
    if [[ "$report_mode" == true ]]; then
        generate_report
    fi
    
    echo ""
    log_info "诊断完成。如需帮助，请查看生成的报告或联系技术支持。"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
