# IGH EtherCAT Master 1.6 自动部署工具包

这个工具包提供了完整的IGH EtherCAT Master 1.6自动部署、管理和诊断功能，让您能够快速、可靠地在Linux系统上部署EtherCAT主站。

## 📦 工具包内容

| 文件名 | 大小 | 描述 |
|--------|------|------|
| `deploy_igh_ethercat.sh` | 12K | 主要部署脚本，自动安装和配置EtherCAT Master |
| `setup_ethercat_network.sh` | 12K | 网卡绑定脚本，配置EtherCAT网络接口 |
| `quick_start_ethercat.sh` | 8K | 快速启动脚本，一键启动和测试EtherCAT |
| `diagnose_ethercat.sh` | 16K | 诊断脚本，检查系统状态和排查问题 |
| `uninstall_igh_ethercat.sh` | 8K | 卸载脚本，完全移除EtherCAT Master |
| `ethercat.conf.template` | 4K | 配置文件模板，包含详细的配置说明 |
| `verify_package.sh` | 4K | 工具包验证脚本，检查文件完整性 |
| `README.md` | 12K | 本说明文档 |

## 🚀 快速开始

### 1. 验证工具包

```bash
# 验证所有文件完整性
./verify_package.sh
```

### 2. 部署EtherCAT Master

```bash
# 运行部署脚本（需要root权限）
sudo ./deploy_igh_ethercat.sh
```

**注意**: 脚本会自动从 `https://gitlab.com/etherlab.org/ethercat.git` 下载最新的IGH EtherCAT Master 1.6.7版本源码。

### 3. 配置网络接口

```bash
# 交互式选择和配置网卡
sudo ./setup_ethercat_network.sh

# 或直接指定网卡
sudo ./setup_ethercat_network.sh enx207bd22aee24
```

### 4. 快速启动和测试

```bash
# 一键启动EtherCAT
sudo ./quick_start_ethercat.sh

# 查看状态
sudo ./quick_start_ethercat.sh --status
```

### 2. 配置网络接口

部署完成后，使用专门的网络配置脚本：

```bash
# 交互式选择网卡（推荐）
sudo ./setup_ethercat_network.sh

# 直接指定网卡
sudo ./setup_ethercat_network.sh eth0

# 查看可用网卡
sudo ./setup_ethercat_network.sh --list-interfaces
```

### 3. 快速启动

```bash
# 一键启动EtherCAT（推荐）
sudo ./quick_start_ethercat.sh

# 查看运行状态
sudo ./quick_start_ethercat.sh --status

# 重新编译内核模块（如有版本不匹配问题）
sudo ./quick_start_ethercat.sh --rebuild
```

### 4. 验证安装

```bash
# 检查主站状态
ethercat master

# 扫描从站
ethercat slaves

# 运行完整诊断
sudo ./diagnose_ethercat.sh

# 快速状态检查
sudo ./diagnose_ethercat.sh --quick
```

## 🛠️ 详细使用说明

### 网络配置脚本功能

`setup_ethercat_network.sh` 脚本提供以下功能：

- **交互式网卡选择**: 自动扫描并显示可用网卡
- **自动配置**: 配置网卡为EtherCAT专用模式
- **NetworkManager集成**: 自动禁用对EtherCAT网卡的管理
- **内核模块管理**: 重新编译和加载内核模块
- **服务管理**: 自动启动和配置EtherCAT服务

#### 使用示例

```bash
# 交互式配置（推荐新用户）
sudo ./setup_ethercat_network.sh

# 直接配置USB网卡
sudo ./setup_ethercat_network.sh enx207bd22aee24

# 配置标准以太网卡
sudo ./setup_ethercat_network.sh eth0

# 查看帮助
sudo ./setup_ethercat_network.sh --help
```

### 快速启动脚本功能

`quick_start_ethercat.sh` 脚本用于日常启动和维护：

- **一键启动**: 启动网卡和EtherCAT服务
- **状态检查**: 显示详细的系统状态
- **故障修复**: 自动修复常见问题
- **模块重建**: 重新编译内核模块

#### 使用示例

```bash
# 快速启动EtherCAT
sudo ./quick_start_ethercat.sh

# 查看详细状态
sudo ./quick_start_ethercat.sh --status

# 重新编译模块（解决版本不匹配）
sudo ./quick_start_ethercat.sh --rebuild
```

### 部署脚本功能

`deploy_igh_ethercat.sh` 脚本会自动完成以下任务：

1. **系统环境检测**: 自动识别操作系统类型和版本
2. **依赖包安装**: 安装编译和运行所需的所有依赖包
3. **源码下载**: 从官方Git仓库下载最新的IGH EtherCAT Master源码
4. **编译安装**: 自动配置、编译和安装EtherCAT Master
5. **系统配置**: 创建服务文件、配置文件和用户权限
6. **模块配置**: 设置内核模块和udev规则

#### 支持的操作系统

- Ubuntu 18.04+
- Debian 9+
- CentOS 7+
- RHEL 7+
- Rocky Linux 8+
- AlmaLinux 8+

#### 编译选项

脚本使用以下编译选项以获得最佳兼容性：

```bash
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
```

### 配置文件详解

#### /etc/sysconfig/ethercat

主配置文件，包含以下关键设置：

```bash
# 主网卡设备（必须配置）
MASTER0_DEVICE="eth0"

# 备用网卡（可选）
MASTER0_BACKUP=""

# 设备模块类型
DEVICE_MODULES="generic"

# 运行参数
ETHERCAT_OPTIONS=""
```

#### 网卡配置说明

1. **查看可用网卡**:
   ```bash
   ip link show
   # 或
   ethtool --version  # 检查ethtool可用性
   ```

2. **选择合适的网卡**: 选择一个专用于EtherCAT通信的网卡，避免与常规网络流量冲突

3. **配置示例**:
   ```bash
   # 单网卡配置
   MASTER0_DEVICE="enp2s0"
   
   # 双网卡冗余配置
   MASTER0_DEVICE="enp2s0"
   MASTER0_BACKUP="enp3s0"
   ```

### 诊断工具使用

`diagnose_ethercat.sh` 提供了全面的系统诊断功能：

```bash
# 完整诊断检查
sudo ./diagnose_ethercat.sh

# 快速状态检查
sudo ./diagnose_ethercat.sh --quick

# 生成详细报告
sudo ./diagnose_ethercat.sh --report

# 显示帮助
./diagnose_ethercat.sh --help
```

#### 诊断检查项目

- ✅ 安装状态检查
- ✅ 内核模块状态
- ✅ 服务运行状态
- ✅ 配置文件检查
- ✅ 网络接口状态
- ✅ EtherCAT主站通信
- ✅ 用户权限检查
- ✅ 系统资源状态

### 卸载说明

如需完全移除EtherCAT Master：

```bash
# 运行卸载脚本
sudo ./uninstall_igh_ethercat.sh

# 确认卸载（输入 'yes'）
# 脚本会安全地移除所有相关文件和配置
```

## ⚡ 常见问题解决

### 1. 编译错误

**问题**: 缺少内核头文件
```
error: linux/kernel.h: No such file or directory
```

**解决**:
```bash
# Ubuntu/Debian
sudo apt-get install linux-headers-$(uname -r)

# CentOS/RHEL
sudo yum install kernel-devel kernel-headers
```

### 2. 模块加载失败

**问题**: 模块加载时出现符号未找到错误

**解决**:
```bash
# 检查内核版本匹配
uname -r
ls /lib/modules/

# 重新编译模块
sudo make modules_install
sudo depmod -a
```

### 3. 服务启动失败

**问题**: EtherCAT服务无法启动

**解决步骤**:
```bash
# 1. 检查配置文件
sudo nano /etc/sysconfig/ethercat

# 2. 确认网卡存在
ip link show

# 3. 手动加载模块
sudo modprobe ec_master

# 4. 查看详细错误
journalctl -u ethercat -f
```

### 4. 权限问题

**问题**: 普通用户无法访问EtherCAT设备

**解决**:
```bash
# 将用户添加到ethercat组
sudo usermod -a -G ethercat $USER

# 重新登录或刷新组权限
newgrp ethercat

# 检查设备文件权限
ls -l /dev/EtherCAT*
```

### 5. 网络冲突

**问题**: 网卡被其他网络服务占用

**解决**:
```bash
# 禁用NetworkManager对特定网卡的管理
sudo nmcli device set eth0 managed no

# 或编辑NetworkManager配置
sudo nano /etc/NetworkManager/NetworkManager.conf
# 添加: [keyfile]
#      unmanaged-devices=interface-name:eth0
```

## 🔧 高级配置

### 实时性能优化

1. **CPU隔离**:
   ```bash
   # 在内核启动参数中添加
   isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3
   ```

2. **IRQ绑定**:
   ```bash
   # 将EtherCAT网卡IRQ绑定到指定CPU
   echo 2 > /proc/irq/24/smp_affinity_list
   ```

3. **内核抢占禁用**:
   ```bash
   # 使用PREEMPT_RT内核或调整调度策略
   chrt -f 80 your_ethercat_application
   ```

### 多主站配置

```bash
# 在配置文件中添加第二个主站
MASTER1_DEVICE="eth1"
MASTER1_BACKUP=""

# 对应的模块参数
DEVICE_MODULES="generic,generic"
```

### 自定义编译选项

如需使用特定网卡驱动而非通用驱动：

```bash
# 编辑部署脚本中的configure选项
./configure \
    --prefix=/opt/etherlab \
    --enable-8139too \      # 启用RTL8139驱动
    --enable-e1000 \        # 启用Intel e1000驱动
    --enable-e1000e \       # 启用Intel e1000e驱动
    --enable-igb \          # 启用Intel IGB驱动
    # ... 其他选项
```

## 📊 性能监控

### 监控命令

```bash
# 实时监控主站状态
watch -n 1 'ethercat master'

# 查看从站状态
ethercat slaves

# 监控网络流量
sudo tcpdump -i eth0 ether proto 0x88a4

# 查看系统负载
htop

# 监控中断
watch -n 1 'cat /proc/interrupts | grep eth0'
```

### 性能指标

关注以下指标确保系统性能：

- **周期时间**: 通常设置为1ms或更小
- **抖动**: 应小于10微秒
- **丢包率**: 应为0
- **CPU使用率**: EtherCAT任务应有专用CPU核心

## 🛡️ 安全注意事项

1. **网络隔离**: EtherCAT网络应与普通网络物理隔离
2. **用户权限**: 合理分配用户权限，避免不必要的root访问
3. **防火墙**: 确保EtherCAT端口不被防火墙阻断
4. **备份**: 定期备份配置文件和应用程序

## 📞 技术支持

如遇到问题，请按以下步骤获取支持：

1. **运行诊断脚本**:
   ```bash
   sudo ./diagnose_ethercat.sh --report
   ```

2. **收集系统信息**:
   - 操作系统版本
   - 内核版本  
   - 硬件信息
   - 错误日志

3. **查看日志**:
   ```bash
   journalctl -u ethercat -n 50
   dmesg | grep -i ethercat
   ```

4. **联系支持**: 提供诊断报告和详细的错误描述

## 📝 更新日志

### v1.0 (2025-09-06)
- 初始版本发布
- 支持IGH EtherCAT Master 1.6.2
- 包含完整的部署、诊断和卸载功能
- 支持主流Linux发行版
- 提供详细的配置模板和文档

## 📄 许可证

本项目基于MIT许可证开源，详见LICENSE文件。

## 🤝 贡献

欢迎提交问题报告和改进建议！请通过GitHub Issues或Pull Requests参与贡献。

---

**注意**: 使用本工具包前，请确保您有足够的Linux系统管理经验，并在生产环境部署前进行充分测试。
