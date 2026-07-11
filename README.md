# IGH EtherCAT Master 部署工具

用于在 Linux 上构建、安装和维护 IGH EtherCAT Master 1.6.9。

## 文件说明

- `deploy_igh_ethercat.sh`：安装依赖、构建主站并配置专用网卡。
- `setup_ethercat_network.sh`：重新绑定网卡、重建模块和检查主站。
- `ethercat_interface_resolver.sh`：通过持久 MAC 地址定位当前物理网卡。
- `diagnose_ethercat.sh`：检查安装、服务、设备和从站状态。
- `restore_network.sh`：恢复普通网络管理；默认释放已绑定的 EtherCAT 网口。
- `uninstall_igh_ethercat.sh`：移除项目创建的 EtherCAT 文件和配置。
- `99-ethercat.rules`：`/dev/EtherCAT*` 的访问权限规则。

## 安装

```bash
./verify_package.sh
sudo ./deploy_igh_ethercat.sh
```

部署时选择一个**专用于 EtherCAT 的有线网卡**。不要选择默认路由、Wi-Fi、Docker、VPN 或其他虚拟接口。

## 绑定或更换 EtherCAT 网卡

```bash
sudo ./setup_ethercat_network.sh
sudo ./setup_ethercat_network.sh enx207bd22aee24
sudo ./setup_ethercat_network.sh --list
```

脚本会备份配置、将目标接口设为 NetworkManager 未托管、重建模块并启动主站。

## 自动启动与热插拔

EtherCAT 不依赖图形界面、`network-online.target` 或固定延时。

- `ethercat-monitor.service` 每 2 秒按网卡 MAC 做一次轻量状态检查，确保 USB 网卡重插、临时命名或重命名后仍会自动恢复 `ethercat.service`。
- 接口不存在时，不会创建等待任务，也不会影响系统开机。
- 接口拔出时，服务随设备停止。
- 接口重新接入时，udev 立即再次启动服务。

检查状态：

```bash
systemctl status ethercat.service
ethercat master
ethercat slaves
```

## 诊断

```bash
sudo ./diagnose_ethercat.sh
sudo ./diagnose_ethercat.sh --quick
sudo ./diagnose_ethercat.sh --report
```

主站可用的最小判断条件是：`/dev/EtherCAT0` 存在，并且 `ethercat master` 显示主网卡为 `(attached)`。`Link: UP` 后才可扫描从站。

部署脚本会将运行 `sudo` 的普通用户加入 `ethercat` 组，并把该用户设置为 `/dev/EtherCAT*` 的 udev 所有者。因此首次安装后的当前终端即可直接运行 `ethercat slaves`，无需使用不安全的 `0666`。其他用户通过加入 `ethercat` 组获得访问权限；新成员需重新登录以刷新组会话。

## 恢复普通网络

不带选项会释放已绑定的 EtherCAT 专用网卡，并交回 NetworkManager。脚本不会等待 DHCP、IP 地址分配或连接激活：

```bash
sudo ./restore_network.sh
```

该操作会停止 EtherCAT 服务、删除热插拔规则和 NetworkManager 未托管配置；如需再次作为 EtherCAT 使用，请重新运行网卡绑定脚本。

若只恢复其他普通网卡而不影响 EtherCAT，请显式指定范围：

```bash
sudo ./restore_network.sh --iface enp2s0
sudo ./restore_network.sh --all
```

也可明确指定释放 EtherCAT 专用网卡：

```bash
sudo ./restore_network.sh --release-ethercat
```

## 卸载

```bash
sudo ./uninstall_igh_ethercat.sh
```

卸载会删除 `/opt/etherlab`、构建源码、服务、udev 规则、NetworkManager 配置和 EtherCAT 服务用户，并尝试把原专用接口重新交给 NetworkManager。
