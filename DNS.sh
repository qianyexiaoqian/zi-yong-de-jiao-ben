#!/bin/bash

# DNS管理脚本
# 作者: QianYe
# 用途: 交互式管理系统DNS配置

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 配置文件路径
DNS_CONFIG="/etc/resolv.conf"
BACKUP_DIR="/root/qianye-dns"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       DNS 配置管理工具${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} 备份当前DNS配置"
    echo -e "${GREEN}2.${NC} 恢复DNS配置"
    echo -e "${GREEN}3.${NC} 快捷修改DNS (1.1.1.1 和 8.8.8.8)"
    echo -e "${GREEN}4.${NC} 查看当前DNS配置"
    echo -e "${GREEN}5.${NC} 新增DNS服务器"
    echo -e "${GREEN}6.${NC} 修改/删除DNS配置"
    echo -e "${GREEN}7.${NC} 清空当前DNS配置"
    echo -e "${GREEN}0.${NC} 退出脚本"
    echo ""
    echo -e "${BLUE}========================================${NC}"
}

# 备份当前DNS
backup_dns() {
    echo -e "${YELLOW}正在备份当前DNS配置...${NC}"
    
    if [ ! -f "$DNS_CONFIG" ]; then
        echo -e "${RED}错误: DNS配置文件不存在！${NC}"
        return 1
    fi
    
    # 生成备份文件名（带时间戳）
    BACKUP_FILE="$BACKUP_DIR/dns_backup_$(date +%Y%m%d_%H%M%S).conf"
    
    cp "$DNS_CONFIG" "$BACKUP_FILE"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 备份成功！${NC}"
        echo -e "备份文件: ${BLUE}$BACKUP_FILE${NC}"
    else
        echo -e "${RED}✗ 备份失败！${NC}"
    fi
}

# 列出所有备份
list_backups() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}没有找到备份文件${NC}"
        return 1
    fi
    
    echo -e "${BLUE}可用的备份文件:${NC}"
    echo ""
    
    local i=1
    for file in "$BACKUP_DIR"/*.conf; do
        if [ -f "$file" ]; then
            echo -e "${GREEN}$i.${NC} $(basename "$file")"
            ((i++))
        fi
    done
    
    return 0
}

# 恢复DNS
restore_dns() {
    echo -e "${YELLOW}恢复DNS配置${NC}"
    echo ""
    
    if ! list_backups; then
        return 1
    fi
    
    echo ""
    read -p "请选择要恢复的备份编号 (0返回): " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    fi
    
    # 获取选择的文件
    local i=1
    for file in "$BACKUP_DIR"/*.conf; do
        if [ -f "$file" ] && [ "$i" -eq "$choice" ]; then
            echo ""
            echo -e "${BLUE}备份文件内容预览:${NC}"
            echo -e "${YELLOW}----------------------------------------${NC}"
            cat "$file"
            echo -e "${YELLOW}----------------------------------------${NC}"
            echo ""
            
            read -p "确认恢复此备份? (y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                cp "$file" "$DNS_CONFIG"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ DNS配置恢复成功！${NC}"
                else
                    echo -e "${RED}✗ 恢复失败！${NC}"
                fi
            else
                echo -e "${YELLOW}已取消恢复${NC}"
            fi
            return 0
        fi
        ((i++))
    done
    
    echo -e "${RED}无效的选择！${NC}"
}

# 快捷设置DNS
quick_set_dns() {
    echo -e "${YELLOW}正在设置DNS为 1.1.1.1 和 8.8.8.8...${NC}"
    
    # 先备份
    backup_dns
    
    # 写入新的DNS配置
    cat > "$DNS_CONFIG" << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ DNS设置成功！${NC}"
        echo ""
        view_dns
    else
        echo -e "${RED}✗ DNS设置失败！${NC}"
    fi
}

# 查看当前DNS配置
view_dns() {
    echo -e "${BLUE}当前DNS配置:${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    if [ -f "$DNS_CONFIG" ]; then
        cat "$DNS_CONFIG"
    else
        echo -e "${RED}配置文件不存在${NC}"
    fi
    
    echo -e "${YELLOW}----------------------------------------${NC}"
}

# 新增DNS
add_dns() {
    echo -e "${YELLOW}新增DNS服务器${NC}"
    echo ""
    
    read -p "请输入要添加的DNS服务器地址: " dns_server
    
    if [ -z "$dns_server" ]; then
        echo -e "${RED}DNS地址不能为空！${NC}"
        return 1
    fi
    
    # 验证IP格式（简单验证）
    if ! [[ $dns_server =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${RED}无效的IP地址格式！${NC}"
        return 1
    fi
    
    echo "nameserver $dns_server" >> "$DNS_CONFIG"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ DNS添加成功！${NC}"
        echo ""
        view_dns
    else
        echo -e "${RED}✗ DNS添加失败！${NC}"
    fi
}

# 修改/删除DNS
modify_dns() {
    echo -e "${YELLOW}修改/删除DNS配置${NC}"
    echo ""
    view_dns
    echo ""
    echo -e "${GREEN}1.${NC} 手动编辑DNS配置"
    echo -e "${GREEN}2.${NC} 删除指定DNS行"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    
    read -p "请选择操作: " choice
    
    case $choice in
        1)
            # 先备份
            backup_dns
            echo ""
            echo -e "${YELLOW}正在打开编辑器...${NC}"
            
            # 使用系统默认编辑器
            if command -v vim &> /dev/null; then
                vim "$DNS_CONFIG"
            elif command -v vi &> /dev/null; then
                vi "$DNS_CONFIG"
            elif command -v nano &> /dev/null; then
                nano "$DNS_CONFIG"
            else
                echo -e "${RED}未找到可用的编辑器！${NC}"
                return 1
            fi
            
            echo -e "${GREEN}✓ 编辑完成${NC}"
            ;;
        2)
            echo ""
            echo -e "${BLUE}当前DNS列表:${NC}"
            local i=1
            while IFS= read -r line; do
                if [[ $line =~ ^nameserver ]]; then
                    echo -e "${GREEN}$i.${NC} $line"
                    ((i++))
                fi
            done < "$DNS_CONFIG"
            
            echo ""
            read -p "请输入要删除的行号 (0取消): " line_num
            
            if [ "$line_num" = "0" ]; then
                return 0
            fi
            
            # 先备份
            backup_dns
            
            # 删除指定行
            local current=1
            local temp_file=$(mktemp)
            while IFS= read -r line; do
                if [[ $line =~ ^nameserver ]]; then
                    if [ "$current" -ne "$line_num" ]; then
                        echo "$line" >> "$temp_file"
                    fi
                    ((current++))
                else
                    echo "$line" >> "$temp_file"
                fi
            done < "$DNS_CONFIG"
            
            mv "$temp_file" "$DNS_CONFIG"
            echo -e "${GREEN}✓ 删除成功${NC}"
            echo ""
            view_dns
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效的选择！${NC}"
            ;;
    esac
}

# 清空DNS配置
clear_dns() {
    echo -e "${RED}警告: 此操作将清空所有DNS配置！${NC}"
    read -p "确认清空? (yes/no): " confirm
    
    if [ "$confirm" = "yes" ]; then
        # 先备份
        backup_dns
        
        # 清空文件
        > "$DNS_CONFIG"
        
        echo -e "${GREEN}✓ DNS配置已清空${NC}"
    else
        echo -e "${YELLOW}已取消操作${NC}"
    fi
}

# 主循环
main() {
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用root权限运行此脚本！${NC}"
        exit 1
    fi
    
    while true; do
        show_menu
        read -p "请选择功能 [0-7]: " choice
        echo ""
        
        case $choice in
            1)
                backup_dns
                ;;
            2)
                restore_dns
                ;;
            3)
                quick_set_dns
                ;;
            4)
                view_dns
                ;;
            5)
                add_dns
                ;;
            6)
                modify_dns
                ;;
            7)
                clear_dns
                ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入！${NC}"
                ;;
        esac
        
        echo ""
        read -p "按回车键继续..." dummy
    done
}

# 运行主程序
main
