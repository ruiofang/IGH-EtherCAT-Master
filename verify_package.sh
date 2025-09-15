#!/bin/bash

# IGH EtherCAT Master 工具包验证脚本
# 检查所有必需文件是否存在且格式正确

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "IGH EtherCAT Master 1.6 工具包验证"
echo "====================================="
echo ""

# 检查必需文件
required_files=(
    "deploy_igh_ethercat.sh"
    "uninstall_igh_ethercat.sh" 
    "diagnose_ethercat.sh"
    "setup_ethercat_network.sh"
    "quick_start_ethercat.sh"
    "ethercat.conf.template"
    "README.md"
)

all_ok=true

for file in "${required_files[@]}"; do
    if [[ -f "$file" ]]; then
        # 检查脚本文件是否可执行
        if [[ "$file" == *.sh ]]; then
            if [[ -x "$file" ]]; then
                echo -e "${GREEN}✓${NC} $file (可执行)"
            else
                echo -e "${YELLOW}⚠${NC} $file (存在，但不可执行)"
                echo "  运行: chmod +x $file"
            fi
        else
            echo -e "${GREEN}✓${NC} $file"
        fi
    else
        echo -e "${RED}✗${NC} $file (缺失)"
        all_ok=false
    fi
done

echo ""

# 检查脚本语法
echo "检查脚本语法..."
for script in deploy_igh_ethercat.sh uninstall_igh_ethercat.sh diagnose_ethercat.sh setup_ethercat_network.sh quick_start_ethercat.sh; do
    if [[ -f "$script" ]]; then
        if bash -n "$script" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} $script 语法正确"
        else
            echo -e "${RED}✗${NC} $script 语法错误"
            all_ok=false
        fi
    fi
done

echo ""

if [[ "$all_ok" == true ]]; then
    echo -e "${GREEN}✓ 工具包验证通过！${NC}"
    echo ""
    echo "使用说明:"
    echo "1. 运行部署脚本: sudo ./deploy_igh_ethercat.sh"
    echo "2. 配置网络接口: sudo ./setup_ethercat_network.sh"
    echo "3. 快速启动: sudo ./quick_start_ethercat.sh"
    echo "4. 运行诊断: sudo ./diagnose_ethercat.sh"
    echo ""
    echo "详细说明请查看 README.md 文件"
else
    echo -e "${RED}✗ 工具包验证失败！${NC}"
    echo "请检查缺失的文件或修复语法错误"
fi

echo ""
