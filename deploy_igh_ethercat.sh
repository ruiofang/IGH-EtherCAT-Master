#!/bin/bash

# IGH EtherCAT Master 1.6 自动部署脚本
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

# 检测操作系统
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        log_error "无法检测操作系统版本"
        exit 1
    fi
    
    log_info "检测到操作系统: $OS $VER"
}

# 选择网卡
select_network_interface() {
    log_info "正在检测可用的网卡..."
    
    # 获取所有网络接口（排除lo和无效接口）
    local interfaces=()
    local interface_info=()
    
    # 使用ip命令获取网络接口信息
    while IFS= read -r line; do
        if [[ $line =~ ^[0-9]+:\ ([^:@]+)[@:]? ]]; then
            local iface="${BASH_REMATCH[1]}"
            # 排除lo、docker、veth等虚拟接口
            if [[ ! "$iface" =~ ^(lo|docker|br-|veth|virbr) ]]; then
                interfaces+=("$iface")
                
                # 获取接口详细信息
                local ip_addr=$(ip addr show "$iface" 2>/dev/null | grep -o "inet [0-9.]*" | cut -d' ' -f2 | head -1)
                local link_status=$(ip link show "$iface" 2>/dev/null | grep -o "state [A-Z]*" | cut -d' ' -f2)
                local speed=""
                
                # 尝试获取网卡速度信息
                if command -v ethtool >/dev/null 2>&1; then
                    speed=$(ethtool "$iface" 2>/dev/null | grep "Speed:" | cut -d: -f2 | xargs)
                fi
                
                local info="$iface"
                [[ -n "$ip_addr" ]] && info+=" (IP: $ip_addr)"
                [[ -n "$link_status" ]] && info+=" [状态: $link_status]"
                [[ -n "$speed" ]] && info+=" [速度: $speed]"
                
                interface_info+=("$info")
            fi
        fi
    done < <(ip link show 2>/dev/null)
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_error "未检测到可用的网络接口"
        exit 1
    fi
    
    log_success "检测到 ${#interfaces[@]} 个可用网卡"
    echo ""
    
    # 显示网卡列表
    echo -e "${BLUE}可用的网络接口：${NC}"
    for i in "${!interface_info[@]}"; do
        echo "  $((i+1)). ${interface_info[$i]}"
    done
    echo ""
    
    # 让用户选择
    local selected_index=""
    while true; do
        echo -n -e "${YELLOW}请选择用于EtherCAT的网卡 [1-${#interfaces[@]}]: ${NC}"
        read -r selected_index
        
        # 验证输入
        if [[ "$selected_index" =~ ^[0-9]+$ ]] && [[ "$selected_index" -ge 1 ]] && [[ "$selected_index" -le ${#interfaces[@]} ]]; then
            break
        else
            log_error "无效选择，请输入 1 到 ${#interfaces[@]} 之间的数字"
        fi
    done
    
    # 设置选中的网卡
    SELECTED_INTERFACE="${interfaces[$((selected_index-1))]}"
    log_success "已选择网卡: $SELECTED_INTERFACE"
    
    # 显示警告信息
    echo ""
    log_warning "重要提醒："
    echo "1. 选中的网卡 '$SELECTED_INTERFACE' 将被EtherCAT Master接管"
    echo "2. 该网卡将无法用于普通的TCP/IP网络通信"
    echo "3. 请确保该网卡连接到EtherCAT网络，而非普通以太网"
    echo "4. 如果该网卡当前用于系统网络连接，请先准备备用网络连接"
    echo ""
    
    # 确认选择
    while true; do
        echo -n -e "${YELLOW}确认使用网卡 '$SELECTED_INTERFACE' 用于EtherCAT吗？[y/N]: ${NC}"
        read -r confirm
        case "$confirm" in
            [Yy]|[Yy][Ee][Ss])
                log_success "已确认选择网卡: $SELECTED_INTERFACE"
                break
                ;;
            [Nn]|[Nn][Oo]|"")
                log_info "取消安装，请重新运行脚本选择其他网卡"
                exit 0
                ;;
            *)
                log_error "请输入 y 或 n"
                ;;
        esac
    done
    
    echo ""
}

# 安装依赖包
install_dependencies() {
    log_info "正在安装系统依赖包..."
    
    case "$OS" in
        *"Ubuntu"*|*"Debian"*)
            apt-get update
            apt-get install -y \
                build-essential \
                linux-headers-$(uname -r) \
                autoconf \
                libtool \
                pkg-config \
                make \
                git \
                wget \
                dkms \
                ethtool \
                net-tools
            ;;
        *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"AlmaLinux"*)
            yum groupinstall -y "Development Tools"
            yum install -y \
                kernel-devel \
                kernel-headers \
                autoconf \
                libtool \
                pkgconfig \
                make \
                git \
                wget \
                dkms \
                ethtool \
                net-tools
            ;;
        *)
            log_warning "未识别的操作系统，请手动安装依赖包"
            ;;
    esac
    
    log_success "依赖包安装完成"
}

# 下载IGH EtherCAT Master源码
download_source() {
    local download_dir="/usr/src/ethercat"
    local version="1.6.7"
    local url="https://gitlab.com/etherlab.org/ethercat.git"
    local max_retries=3
    local retry_count=0
    local current_dir=$(pwd)
    local tarball_name="ethercat-stable-1.6.tar.gz"
    
    log_info "正在准备IGH EtherCAT Master源码..."
    
    # 删除已存在的目录
    if [[ -d "$download_dir" ]]; then
        rm -rf "$download_dir"
    fi
    
    # 创建下载目录
    mkdir -p "$download_dir"
    
    # 首先检查当前目录或脚本所在目录是否存在压缩包
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local tarball_path=""
    
    if [[ -f "$current_dir/$tarball_name" ]]; then
        tarball_path="$current_dir/$tarball_name"
        log_info "在当前目录找到压缩包: $tarball_path"
    elif [[ -f "$script_dir/$tarball_name" ]]; then
        tarball_path="$script_dir/$tarball_name"
        log_info "在脚本目录找到压缩包: $tarball_path"
    fi
    
    # 如果找到压缩包，使用解压方式
    if [[ -n "$tarball_path" ]]; then
        log_info "使用现有压缩包，跳过下载..."
        
        # 验证压缩包完整性
        if tar -tzf "$tarball_path" >/dev/null 2>&1; then
            log_success "压缩包验证通过"
            
            # 解压到目标目录
            cd "$download_dir"
            tar -xzf "$tarball_path" --strip-components=1
            
            if [[ $? -eq 0 ]]; then
                log_success "源码解压完成"
                return 0
            else
                log_error "压缩包解压失败，将尝试在线下载"
            fi
        else
            log_warning "压缩包验证失败，将尝试在线下载"
        fi
    else
        log_info "未找到现有压缩包，将进行在线下载"
    fi
    
    # 如果没有找到压缩包或解压失败，进行在线下载
    cd "$download_dir"
    
    # 尝试克隆源码，带重试机制
    while [[ $retry_count -lt $max_retries ]]; do
        log_info "尝试下载源码 (第 $((retry_count + 1))/$max_retries 次)..."
        
        # 清理可能的部分下载
        rm -rf .git * .[^.]* ..?* 2>/dev/null || true
        
        if git clone --depth 1 --branch "$version" "$url" .; then
            log_success "源码下载完成 (版本: $version)"
            return 0
        else
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                log_warning "下载失败，等待5秒后重试..."
                sleep 5
            fi
        fi
    done
    
    # 如果指定版本失败，尝试下载stable分支
    log_warning "尝试下载stable-1.6分支..."
    rm -rf .git * .[^.]* ..?* 2>/dev/null || true
    if git clone --depth 1 --branch "stable-1.6" "$url" .; then
        log_success "源码下载完成 (stable-1.6分支)"
        return 0
    fi
    
    log_error "源码下载失败，所有重试均失败"
    exit 1
}

# 配置和编译
configure_and_build() {
    local build_dir="/usr/src/ethercat"
    
    log_info "正在配置和编译EtherCAT Master..."
    
    cd "$build_dir"
    
    # 运行bootstrap（如果存在）
    if [[ -f "bootstrap" ]]; then
        ./bootstrap
    fi
    
    # 配置编译选项
    ./configure \
        --prefix=/opt/etherlab \
        --disable-8139too \
        --enable-generic \
        --enable-hrtimer \
        --enable-cycles \
        --with-linux-dir=/lib/modules/$(uname -r)/build \
        --enable-userlib \
        --enable-tool \
        --enable-debug-if
    
    # 编译
    make clean
    make -j$(nproc)
    
    log_success "编译完成"
}

# 安装EtherCAT Master
install_ethercat() {
    local build_dir="/usr/src/ethercat"
    
    log_info "正在安装EtherCAT Master..."
    
    cd "$build_dir"
    
    # 安装
    make install
    
    # 创建符号链接
    ln -sf /opt/etherlab/bin/ethercat /usr/local/bin/ethercat
    ln -sf /opt/etherlab/lib/libethercat.so* /usr/local/lib/
    
    # 更新动态链接库缓存
    ldconfig
    
    log_success "EtherCAT Master安装完成"
}

# 配置内核模块
configure_kernel_module() {
    log_info "正在配置内核模块..."
    
    # 创建模块配置目录
    mkdir -p /etc/modprobe.d
    
    # 禁用通用网络驱动（避免冲突）
    cat > /etc/modprobe.d/ethercat.conf << EOF
# EtherCAT Master配置
# 禁用通用以太网驱动以避免与EtherCAT冲突
# blacklist r8169
# blacklist e1000
# blacklist e1000e
# blacklist igb
# blacklist ixgbe
# 请根据您的网卡型号取消相应行的注释
EOF
    
    # 创建systemd服务文件
    cat > /etc/systemd/system/ethercat.service << EOF
[Unit]
Description=EtherCAT Master Service
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/init.d/ethercat start
ExecStop=/etc/init.d/ethercat stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # 复制初始化脚本
    cp /opt/etherlab/etc/init.d/ethercat /etc/init.d/
    chmod +x /etc/init.d/ethercat
    
    log_success "内核模块配置完成"
}

# 配置EtherCAT参数
configure_ethercat() {
    log_info "正在配置EtherCAT参数..."
    
    # 创建配置目录
    mkdir -p /opt/etherlab/etc/sysconfig
    mkdir -p /etc/sysconfig
    
    local config_file="/opt/etherlab/etc/sysconfig/ethercat"
    local current_dir=$(pwd)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local template_file=""
    
    # 检查是否存在本地配置模板
    if [[ -f "$current_dir/ethercat.conf.template" ]]; then
        template_file="$current_dir/ethercat.conf.template"
        log_info "在当前目录找到配置模板: $template_file"
    elif [[ -f "$script_dir/ethercat.conf.template" ]]; then
        template_file="$script_dir/ethercat.conf.template"
        log_info "在脚本目录找到配置模板: $template_file"
    fi
    
        # 如果找到模板文件，基于模板创建配置
    if [[ -n "$template_file" ]]; then
        log_info "使用模板文件创建配置..."
        
        # 从模板创建配置，并替换网卡设置
        {
            echo "# EtherCAT Master配置文件"
            echo "# 基于模板文件生成: $(basename "$template_file")"
            echo "# 生成时间: $(date)"
            echo "# 用户选择的网卡: $SELECTED_INTERFACE"
            echo ""
            
            # 从模板中提取配置行，但替换MASTER0_DEVICE
            while IFS= read -r line; do
                if [[ $line =~ ^MASTER0_DEVICE= ]]; then
                    echo "MASTER0_DEVICE=\"$SELECTED_INTERFACE\"  # 用户选择的网卡"
                elif [[ $line =~ ^(MASTER[0-9]_BACKUP|DEVICE_MODULES|ETHERCAT_OPTIONS|ETHERCAT_USER|ETHERCAT_GROUP)= ]]; then
                    echo "$line"
                fi
            done < "$template_file"
            
            # 如果模板中没有必要的配置，添加默认值
            if ! grep -q "^MASTER0_DEVICE=" "$template_file" 2>/dev/null; then
                echo "# 主设备配置"
                echo "MASTER0_DEVICE=\"$SELECTED_INTERFACE\"  # 用户选择的网卡"
                echo "MASTER0_BACKUP=\"\""
            fi
            if ! grep -q "^DEVICE_MODULES=" "$template_file" 2>/dev/null; then
                echo ""
                echo "# 设备模块"
                echo "DEVICE_MODULES=\"generic\""
            fi
            if ! grep -q "^ETHERCAT_OPTIONS=" "$template_file" 2>/dev/null; then
                echo ""
                echo "# 运行参数"
                echo "ETHERCAT_OPTIONS=\"\""
            fi
            if ! grep -q "^ETHERCAT_USER=" "$template_file" 2>/dev/null; then
                echo ""
                echo "# 用户和组"
                echo "ETHERCAT_USER=\"ethercat\""
                echo "ETHERCAT_GROUP=\"ethercat\""
            fi
        } > "$config_file"
        
        log_success "基于模板创建配置文件完成"
    else
        log_info "未找到配置模板，使用默认配置..."
        
        # 创建默认配置文件，使用用户选择的网卡
        cat > "$config_file" << EOF
# EtherCAT Master配置文件
# 生成时间: $(date)
# 用户选择的网卡: $SELECTED_INTERFACE
#
# 主设备配置
MASTER0_DEVICE="$SELECTED_INTERFACE"  # 用户选择的网卡
MASTER0_BACKUP=""

# 设备模块
DEVICE_MODULES="generic"

# 运行参数
ETHERCAT_OPTIONS=""

# 用户和组
ETHERCAT_USER="ethercat"
ETHERCAT_GROUP="ethercat"
EOF
        
        log_success "默认配置文件创建完成"
    fi    # 创建到系统配置目录的符号链接（为了兼容性）
    ln -sf /opt/etherlab/etc/sysconfig/ethercat /etc/sysconfig/ethercat
    
    log_success "EtherCAT参数配置完成"
}

# 创建用户和组
create_user() {
    log_info "正在创建EtherCAT用户和组..."
    
    # 创建ethercat组（如果不存在）
    if ! getent group ethercat > /dev/null 2>&1; then
        groupadd -r ethercat
        log_info "已创建ethercat组"
    fi
    
    # 创建ethercat用户（如果不存在）
    if ! getent passwd ethercat > /dev/null 2>&1; then
        useradd -r -g ethercat -d /var/lib/ethercat -s /sbin/nologin \
                -c "EtherCAT Master Service" ethercat
        log_info "已创建ethercat用户"
    fi
    
    # 创建工作目录
    mkdir -p /var/lib/ethercat
    chown ethercat:ethercat /var/lib/ethercat
    
    log_success "用户和组创建完成"
}

# 设置权限
set_permissions() {
    log_info "正在设置文件权限..."
    
    local current_dir=$(pwd)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local rules_file=""
    local target_rules="/etc/udev/rules.d/99-ethercat.rules"
    
    # 检查是否存在本地udev规则文件
    if [[ -f "$current_dir/99-ethercat.rules" ]]; then
        rules_file="$current_dir/99-ethercat.rules"
        log_info "在当前目录找到udev规则文件: $rules_file"
    elif [[ -f "$script_dir/99-ethercat.rules" ]]; then
        rules_file="$script_dir/99-ethercat.rules"
        log_info "在脚本目录找到udev规则文件: $rules_file"
    fi
    
    # 设置udev规则
    if [[ -n "$rules_file" ]]; then
        log_info "使用现有的udev规则文件..."
        cp "$rules_file" "$target_rules"
        chmod 644 "$target_rules"
        chown root:root "$target_rules"
        log_success "已复制并设置udev规则文件权限"
    else
        log_info "未找到现有规则文件，创建默认udev规则..."
        cat > "$target_rules" << EOF
# EtherCAT Master设备权限规则
KERNEL=="EtherCAT[0-9]*", MODE="0664", GROUP="ethercat"
EOF
        chmod 644 "$target_rules"
        chown root:root "$target_rules"
        log_success "已创建默认udev规则文件"
    fi
    
    # 重新加载udev规则
    udevadm control --reload-rules
    log_info "已重新加载udev规则"
    
    # 设置目录权限
    chown -R root:ethercat /opt/etherlab
    chmod -R 755 /opt/etherlab
    
    log_success "权限设置完成"
}

# 启动服务
start_service() {
    log_info "正在启动EtherCAT服务..."
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 启用服务
    systemctl enable ethercat.service
    
    # 检查是否可以启动（不实际启动，因为可能没有EtherCAT设备）
    log_warning "注意: 请在启动服务前修改 /etc/sysconfig/ethercat 中的网卡配置"
    log_info "配置完成后，使用以下命令启动服务:"
    log_info "  systemctl start ethercat"
    log_info "  systemctl status ethercat"
    
    log_success "服务配置完成"
}

# 显示安装后信息
show_post_install_info() {
    log_success "========================================="
    log_success "IGH EtherCAT Master 1.6 安装完成！"
    log_success "========================================="
    echo ""
    log_info "安装位置: /opt/etherlab"
    log_info "配置文件: /opt/etherlab/etc/sysconfig/ethercat"
    log_info "服务文件: /etc/systemd/system/ethercat.service"
    log_info "初始化脚本: /etc/init.d/ethercat"
    log_info "EtherCAT网卡: $SELECTED_INTERFACE"
    echo ""
    log_warning "重要提醒："
    echo "1. EtherCAT网卡已配置为: $SELECTED_INTERFACE"
    echo "2. 根据需要修改 /etc/modprobe.d/ethercat.conf 禁用相应的网络驱动"
    echo "3. 重启系统或手动加载内核模块"
    echo "4. 使用 'systemctl start ethercat' 启动服务"
    echo "5. 使用 'ethercat master' 命令检查主站状态"
    echo ""
    log_info "常用命令："
    echo "  ethercat master           - 显示主站信息"
    echo "  ethercat slaves           - 显示从站信息"
    echo "  ethercat config           - 显示配置信息"
    echo "  systemctl status ethercat - 检查服务状态"
    echo ""
}

# 主函数
main() {
    log_info "开始安装IGH EtherCAT Master 1.6..."
    echo ""
    
    check_root
    detect_os
    select_network_interface
    install_dependencies
    download_source
    configure_and_build
    install_ethercat
    configure_kernel_module
    configure_ethercat
    create_user
    set_permissions
    start_service
    
    echo ""
    show_post_install_info
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
