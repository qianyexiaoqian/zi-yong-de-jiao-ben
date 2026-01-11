#!/bin/bash

# ==========================================
# 服务器安全管理助手 (终极全功能版)
# Author: Gemini & User
# Update: 完美合并“防失联修复”与“全功能管理”
# Feature: Fail2ban管理 | SSH配置修复 | 密钥备份管理 | 踢人 | 改密码
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m' # No Color

# 检查 Root
if [ "$(id -u)" != "0" ]; then echo -e "${RED}必须使用 root 用户运行!${NC}"; exit 1; fi

# 基础变量
SSH_CONF="/etc/ssh/sshd_config"
SSH_CONF_D_DIR="/etc/ssh/sshd_config.d"
KEY_STORE_BASE="/root/qianye-password"
AUTH_FILE="$HOME/.ssh/authorized_keys"
FAIL2BAN_CONF="/etc/fail2ban/jail.local"

# ==========================================
# 核心工具函数
# ==========================================

detect_os() {
    if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; VERSION=$VERSION_ID;
    elif type lsb_release >/dev/null 2>&1; then OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]');
    elif [ -f /etc/redhat-release ]; then OS="rhel"; fi
}

pause() { echo ""; read -n 1 -s -r -p "按任意键返回..."; echo ""; }

get_ssh_service_name() {
    if systemctl list-units --type=service | grep -q "ssh.service"; then echo "ssh";
    elif systemctl list-units --type=service | grep -q "sshd.service"; then echo "sshd";
    else echo "sshd"; fi
}

# 核心配置修改逻辑 (递归扫描所有配置文件，防止云厂商配置覆盖)
update_ssh_param() {
    local param=$1
    local value=$2
    
    # 1. 修改主配置文件
    if grep -q "^$param" $SSH_CONF; then
        sed -i "s/^$param.*/$param $value/g" $SSH_CONF
    elif grep -q "^#$param" $SSH_CONF; then
        sed -i "s/^#$param.*/$param $value/g" $SSH_CONF
    else
        echo "$param $value" >> $SSH_CONF
    fi

    # 2. 修改子配置文件 (如果有)
    if [ -d "$SSH_CONF_D_DIR" ]; then
        for conf_file in "$SSH_CONF_D_DIR"/*.conf; do
            [ -e "$conf_file" ] || continue
            if grep -q "$param" "$conf_file"; then
                 sed -i "s/^#\?$param.*/$param $value/g" "$conf_file"
            fi
        done
    fi
}

restart_ssh() {
    SERVICE_NAME=$(get_ssh_service_name)
    echo -e "${YELLOW}正在验证 SSH 配置 (sshd -t)...${NC}"
    if sshd -t; then
        echo -e "${GREEN}语法检查通过，正在重启 $SERVICE_NAME ...${NC}"
        systemctl restart "$SERVICE_NAME"
        if systemctl is-active --quiet "$SERVICE_NAME"; then
             echo -e "${GREEN}SSH 服务重启成功。${NC}"
        else
             echo -e "${RED}严重警告：服务重启后状态异常！请立即检查 'systemctl status $SERVICE_NAME'${NC}"
        fi
    else
        echo -e "${RED}配置语法错误！未重启，请手动检查。${NC}"
    fi
}

# ==========================================
# SSH 功能模块 (密码/密钥/状态)
# ==========================================

# 1. 开启密码登录 (包含 KbdInteractiveAuthentication 修复)
enable_password_login() {
    echo -e "${YELLOW}正在强制开启密码登录 (覆盖所有子配置)...${NC}"
    
    update_ssh_param "PasswordAuthentication" "yes"
    update_ssh_param "PermitRootLogin" "yes"
    update_ssh_param "KbdInteractiveAuthentication" "yes"
    update_ssh_param "ChallengeResponseAuthentication" "yes"

    # 使用 sshd -T 检查最终生效配置
    local effective_pass=$(sshd -T | grep -i "^passwordauthentication" | awk '{print $2}')
    if [ "$effective_pass" == "yes" ]; then
        echo -e "${GREEN}检测通过！系统确认已开启密码认证。${NC}"
    else
        echo -e "${RED}警告：系统识别到的配置依然是关闭状态 ($effective_pass)。尝试重启服务强制生效。${NC}"
    fi
    restart_ssh
    pause
}

# 2. 关闭密码登录 (安全版)
disable_password_login() {
    echo -e "${YELLOW}正在检查密钥状态...${NC}"
    if [ ! -s "$AUTH_FILE" ]; then
        echo -e "${RED}拒绝操作：未检测到 authorized_keys 公钥！${NC}"
        echo -e "请先生成密钥，否则您将无法登录。"
        pause; return
    fi
    
    update_ssh_param "PubkeyAuthentication" "yes"
    
    echo -e "${YELLOW}关闭密码登录...${NC}"
    update_ssh_param "PasswordAuthentication" "no"
    update_ssh_param "KbdInteractiveAuthentication" "no"
    update_ssh_param "ChallengeResponseAuthentication" "no"
    
    restart_ssh
    echo -e "${GREEN}密码登录已关闭。${NC}"
    pause
}

# 3. 生成并应用密钥
generate_apply_keys() {
    DATE_DIR=$(date +%Y-%m-%d); TARGET_DIR="$KEY_STORE_BASE/$DATE_DIR"
    [ -d "$TARGET_DIR" ] && TARGET_DIR="${TARGET_DIR}_$(date +%H%M%S)"; mkdir -p "$TARGET_DIR"
    KEY_PATH="$TARGET_DIR/id_rsa_$(date +%s)"
    
    echo -e "${YELLOW}正在生成密钥对...${NC}"
    ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N "" -q
    mkdir -p ~/.ssh; chmod 700 ~/.ssh
    cat "${KEY_PATH}.pub" >> "$AUTH_FILE"; chmod 600 "$AUTH_FILE"
    
    update_ssh_param "PubkeyAuthentication" "yes"
    restart_ssh
    
    echo -e "${GREEN}公钥已应用。${NC}"
    echo -e "私钥已保存至: ${SKYBLUE}$KEY_PATH${NC}"
    echo -e "请下载该文件用于登录。"
    pause
}

# 4. 关闭密钥认证 (恢复纯密码)
disable_key_enable_pass() {
    echo -e "${YELLOW}禁用密钥认证，恢复密码登录...${NC}"
    update_ssh_param "PubkeyAuthentication" "no"
    enable_password_login # 调用上面的开启函数
}

# 5. 查看备份的密钥
list_backup_keys() {
    echo -e "${SKYBLUE}=== 本地备份目录 ($KEY_STORE_BASE) ===${NC}"
    if [ ! -d "$KEY_STORE_BASE" ]; then echo "暂无备份记录。"; else find "$KEY_STORE_BASE" -name "id_rsa_*" -type f -not -name "*.pub" | sort; fi
    pause
}

# 6. 删除备份的密钥
delete_backup_keys() {
    if [ ! -d "$KEY_STORE_BASE" ]; then echo "暂无文件。"; pause; return; fi
    mapfile -t keys < <(find "$KEY_STORE_BASE" -name "id_rsa_*" -type f -not -name "*.pub" | sort)
    if [ ${#keys[@]} -eq 0 ]; then echo "无文件。"; pause; return; fi

    local i=1; for key in "${keys[@]}"; do echo "$i) $key"; ((i++)); done
    echo "0) 取消"

    read -e -p "选择要删除的备份文件序号: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#keys[@]}" ]; then
        local target="${keys[$((choice-1))]}"
        rm -f "$target" "$target.pub"
        echo -e "${GREEN}已删除备份文件 (不影响已配置的登录)。${NC}"
        rmdir "$(dirname "$target")" 2>/dev/null
    fi
    pause
}

# 7. 移除系统已生效公钥 (踢人)
revoke_system_key() {
    if [ ! -s "$AUTH_FILE" ]; then echo -e "${RED}当前没有生效的公钥。${NC}"; pause; return; fi
    mapfile -t auth_keys < "$AUTH_FILE"
    
    echo -e "${YELLOW}正在生效的公钥列表：${NC}"
    local i=1
    for key in "${auth_keys[@]}"; do
        local comment=$(echo "$key" | awk '{print $NF}')
        [[ ${#comment} -gt 50 ]] && comment="...$(echo "$key" | tail -c 20)"
        echo -e "$i) 注释: ${GREEN}$comment${NC}"
        ((i++))
    done
    echo "0) 取消"
    
    read -e -p "输入序号删除公钥 (持有该私钥者将无法登录): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#auth_keys[@]}" ]; then
        read -e -p "确认删除吗？(y/n): " confirm
        if [ "$confirm" == "y" ]; then
            sed -i "${choice}d" "$AUTH_FILE"
            echo -e "${GREEN}删除成功，立即生效。${NC}"
        fi
    fi
    pause
}

# 8. 修改 Root 密码
change_system_password() {
    local new_pass=$(tr -dc 'A-Za-z0-9!@%^&*' < /dev/urandom | head -c 15)
    echo -e "${SKYBLUE}========================================${NC}"
    echo -e "新生成的强密码: ${GREEN}$new_pass${NC}"
    echo -e "${SKYBLUE}========================================${NC}"
    read -e -p "确认修改 root 密码吗？(y/n): " confirm
    if [ "$confirm" == "y" ]; then
        echo "root:$new_pass" | chpasswd
        [ $? -eq 0 ] && echo -e "${GREEN}修改成功。${NC}" || echo -e "${RED}修改失败。${NC}"
    fi
    pause
}

# 9. 查看系统状态
check_system_status() {
    echo -e "${SKYBLUE}=== SSH 最终生效配置 (sshd -T) ===${NC}"
    sshd -T | grep -E "^(passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractiveauthentication)"
    
    local key_count=0; [ -f "$AUTH_FILE" ] && key_count=$(grep -c "^" "$AUTH_FILE")
    echo -e "已安装公钥数: ${GREEN}$key_count${NC}"

    echo -e "${SKYBLUE}=== Fail2ban 状态 ===${NC}"
    if systemctl is-active --quiet fail2ban; then
        local jail_count=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $4}')
        echo -e "运行状态: ${GREEN}Active${NC} | 当前封禁IP数: ${RED}$jail_count${NC}"
    else
        echo -e "运行状态: ${RED}未运行${NC}"
    fi
    pause
}

# ==========================================
# Fail2ban 模块
# ==========================================

install_fail2ban() {
    if command -v fail2ban-client >/dev/null 2>&1; then echo "Fail2ban 已安装"; pause; return; fi
    detect_os
    echo -e "${YELLOW}Install Fail2ban...${NC}"
    case "$OS" in
        ubuntu|debian) apt-get update; apt-get install -y fail2ban rsyslog ;;
        centos|rhel|almalinux) yum install -y epel-release fail2ban ;;
        alpine) apk add fail2ban ;;
    esac
    
    BAN_ACTION="iptables-allports"
    [ -f /var/log/secure ] && LOG_FILE="/var/log/secure" || LOG_FILE="/var/log/auth.log"
    [ -f "$LOG_FILE" ] || touch "$LOG_FILE"

    cat <<EOF > "$FAIL2BAN_CONF"
[DEFAULT]
bantime = 600
findtime = 300
maxretry = 5
banaction = $BAN_ACTION
action = %(action_mwl)s
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = 22
logpath = $LOG_FILE
EOF
    systemctl enable fail2ban; systemctl restart fail2ban
    echo -e "${GREEN}Fail2ban 安装完成。${NC}"; pause
}

uninstall_fail2ban() {
    systemctl stop fail2ban; systemctl disable fail2ban
    rm -rf /etc/fail2ban /var/lib/fail2ban
    detect_os
    case "$OS" in
        ubuntu|debian) apt-get purge -y fail2ban ;;
        centos|rhel) yum remove -y fail2ban ;;
        alpine) apk del fail2ban ;;
    esac
    echo -e "${GREEN}Fail2ban 已卸载。${NC}"; pause
}

configure_fail2ban_params() {
    [ ! -f "$FAIL2BAN_CONF" ] && echo "请先安装 Fail2ban" && pause && return
    grep "^bantime" $FAIL2BAN_CONF
    read -e -p "输入封禁时长(秒) [回车跳过]: " nb
    [[ "$nb" =~ ^[0-9]+$ ]] && sed -i "s/^bantime = .*/bantime = $nb/" $FAIL2BAN_CONF
    read -e -p "输入最大重试次数 [回车跳过]: " nm
    [[ "$nm" =~ ^[0-9]+$ ]] && sed -i "s/^maxretry = .*/maxretry = $nm/" $FAIL2BAN_CONF
    systemctl restart fail2ban
    echo -e "${GREEN}已更新。${NC}"; pause
}

add_whitelist_ip() {
    [ ! -f "$FAIL2BAN_CONF" ] && echo "请先安装 Fail2ban" && pause && return
    read -e -p "输入IP: " ip
    sed -i "/^ignoreip/s/$/ $ip/" $FAIL2BAN_CONF
    systemctl restart fail2ban
    echo -e "${GREEN}已添加白名单。${NC}"; pause
}

unban_specific_ip() {
    read -e -p "输入要解封的IP: " ip
    fail2ban-client set sshd unbanip "$ip"
    pause
}

menu_fail2ban() {
    while true; do
        clear; echo -e "${SKYBLUE}=== Fail2ban 管理 ===${NC}"
        echo "1. 安装 Fail2ban"
        echo "2. 卸载 Fail2ban"
        echo "3. 修改 策略 (时长/次数)"
        echo "4. 添加 白名单 IP"
        echo "5. 解封 指定 IP"
        echo "0. 返回"
        read -e -p "Opt: " fc
        case "$fc" in
            1) install_fail2ban ;; 2) uninstall_fail2ban ;; 3) configure_fail2ban_params ;;
            4) add_whitelist_ip ;; 5) unban_specific_ip ;; 0) return ;;
        esac
    done
}

# ==========================================
# 主菜单
# ==========================================

show_menu() {
    clear
    echo -e "${SKYBLUE}========================================${NC}"
    echo -e "${SKYBLUE}    服务器安全助手 (终极全功能版) ${NC}"
    echo -e "${SKYBLUE}========================================${NC}"
    echo -e "1. Fail2ban 管理 (安装/配置/白名单)"
    echo -e "----------------------------------------"
    echo -e "2. 开启 密码登录 ${GREEN}(含防失联修复)${NC}"
    echo -e "3. 关闭 密码登录 ${YELLOW}(仅限密钥, 安全检测)${NC}"
    echo -e "----------------------------------------"
    echo -e "4. 新增 密钥对 (自动应用 + 备份)"
    echo -e "5. 关闭 密钥认证 (强制密码)"
    echo -e "6. 查看 本地备份密钥 (列表)"
    echo -e "7. 删除 本地备份密钥 (清理)"
    echo -e "${RED}8. 移除 系统已生效公钥 (踢人)${NC}"
    echo -e "----------------------------------------"
    echo -e "9. 修改 Root 密码 (随机强密码)"
    echo -e "10. 查看 系统状态 (SSH检测)"
    echo -e "0. 退出脚本"
    echo -e "${SKYBLUE}========================================${NC}"
    
    read -e -p "请输入选项 [0-10]: " choice
    
    case "$choice" in
        1) menu_fail2ban ;;
        2) enable_password_login ;;
        3) disable_password_login ;;
        4) generate_apply_keys ;;
        5) disable_key_enable_pass ;;
        6) list_backup_keys ;;
        7) delete_backup_keys ;;
        8) revoke_system_key ;;
        9) change_system_password ;;
        10) check_system_status ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
}

while true; do show_menu; done
