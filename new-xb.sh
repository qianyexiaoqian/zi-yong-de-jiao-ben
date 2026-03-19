#!/bin/bash
# Xboard 完整管理脚本 v1.5
# 作者: qianye
# 功能: 部署、升级、卸载、配置管理
# 优化: 支持退格删除、输入修改、输入验证、密码安全处理

# 注意: 不使用 set -e，因为会与菜单循环中的 return 1 冲突
# 使用显式错误检查代替

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置文件路径
INSTALL_DIR="${INSTALL_DIR:-/root/Xboard}"
CONFIG_FILE="$INSTALL_DIR/.deploy_config"

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_step() {
    echo -e "${CYAN}[→]${NC} $1"
}

# 带旋转动画执行命令
run_with_spinner() {
    local message="$1"
    shift
    local pid
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    # 后台运行命令（输出写入临时日志，失败时可排查）
    local spinner_log
    spinner_log=$(mktemp)
    "$@" &>"$spinner_log" &
    pid=$!

    # 显示旋转动画
    printf "${CYAN}[%s]${NC} %s" "${spin_chars:0:1}" "$message"
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i + 1) % 10 ))
        printf "\r${CYAN}[%s]${NC} %s" "${spin_chars:$i:1}" "$message"
        sleep 0.1
    done

    # 等待命令结束并获取退出码
    wait $pid
    local exit_code=$?

    # 清除行并显示结果
    printf "\r"
    if [ $exit_code -eq 0 ]; then
        print_success "$message"
    else
        print_error "$message"
        # 失败时显示最后几行日志帮助排查
        if [ -s "$spinner_log" ]; then
            echo "  最近输出:" >&2
            tail -3 "$spinner_log" | sed 's/^/    /' >&2
        fi
    fi
    rm -f "$spinner_log"

    return $exit_code
}

# 增强的输入函数 - 支持退格和默认值
read_input() {
    local prompt="$1"
    local default="$2"
    local is_password="$3"
    local result=""

    # 密码类型不显示默认值
    if [ -n "$default" ] && [ "$is_password" != "true" ]; then
        prompt="$prompt (默认: $default)"
    fi

    if [ "$is_password" = "true" ]; then
        read -e -p "$prompt: " -s result
        echo "" >&2  # 密码输入后换行，输出到 stderr 避免被捕获
    else
        read -e -p "$prompt: " result
    fi

    # 如果输入为空且有默认值，使用默认值
    if [ -z "$result" ] && [ -n "$default" ]; then
        result="$default"
    fi

    echo "$result"
}

# 生成随机密码（只包含安全字符）
generate_password() {
    local length="${1:-16}"
    # 只使用字母和数字，避免特殊字符引起的问题
    if [ -e /dev/urandom ]; then
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "$length" | head -n 1
    else
        # 备选方案：使用 openssl 或 date + md5
        if command -v openssl &> /dev/null; then
            openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$length"
        else
            date +%s%N | md5sum | tr -dc 'a-zA-Z0-9' | head -c "$length"
        fi
    fi
}

# 转义密码中的特殊字符（用于 shell 配置文件）
escape_password() {
    local password="$1"
    # 转义单引号：' -> '\''
    echo "$password" | sed "s/'/'\\\\''/g"
}


# 增强的选择函数 - 带输入验证
read_choice() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local choice=""

    while true; do
        read -e -p "$prompt [$min-$max]: " choice

        # 验证输入是否为数字且在范围内
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge "$min" ] && [ "$choice" -le "$max" ]; then
            echo "$choice"
            return 0
        else
            # 错误信息输出到 stderr，避免被命令替换捕获
            print_error "无效输入，请输入 $min 到 $max 之间的数字" >&2
        fi
    done
}

# 确认函数 - 支持退格修改
read_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response=""

    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]"
    else
        prompt="$prompt [y/N]"
    fi

    read -e -p "$prompt: " response
    response=${response:-$default}

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# 验证邮箱格式
validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 验证端口号
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 获取公网IP（带缓存，避免重复请求）
PUBLIC_IP_CACHE=""
get_public_ip() {
    # 如果已缓存，直接返回
    if [ -n "$PUBLIC_IP_CACHE" ]; then
        echo "$PUBLIC_IP_CACHE"
        return
    fi

    local ip=""
    # 尝试多个公网IP获取服务（超时缩短到2秒）
    # 优先获取 IPv4，回退 IPv6
    ip=$(curl -4 -s --connect-timeout 2 --max-time 3 ip.sb 2>/dev/null) ||
    ip=$(curl -4 -s --connect-timeout 2 --max-time 3 ifconfig.me 2>/dev/null) ||
    ip=$(curl -4 -s --connect-timeout 2 --max-time 3 ipinfo.io/ip 2>/dev/null) ||
    ip=$(curl -4 -s --connect-timeout 2 --max-time 3 api.ipify.org 2>/dev/null) ||
    ip=$(curl -6 -s --connect-timeout 2 --max-time 3 ip.sb 2>/dev/null) ||
    ip=$(curl -6 -s --connect-timeout 2 --max-time 3 ifconfig.me 2>/dev/null)

    # 验证是否为有效 IPv4 或 IPv6 格式
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]; then
        PUBLIC_IP_CACHE="$ip"
        echo "$ip"
    else
        # 回退到本地IP
        ip=$(hostname -I | awk '{print $1}')
        PUBLIC_IP_CACHE="$ip"
        echo "$ip"
    fi
}

# 显示 Logo
show_logo() {
    clear
    echo -e "${BLUE}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║   Xboard Docker 管理脚本 v1.5                                 ║
║   作者: qianye                                                ║
║   让人人都有机会成为坤场主，拒绝炒鸡，做一个合格的MJJ。       ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# 主菜单
show_menu() {
    show_logo
    echo "请选择操作:"
    echo ""
    echo -e "  ${GREEN}部署相关:${NC}"
    echo "    1) 全新部署 Xboard"
    echo "    2) 升级 Xboard"
    echo "    3) 卸载 Xboard"
    echo ""
    echo -e "  ${CYAN}运维相关:${NC}"
    echo "    4) 重启服务"
    echo "    5) 查看日志"
    echo "    6) 查看状态"
    echo ""
    echo -e "  ${YELLOW}数据相关:${NC}"
    echo "    7) 备份数据"
    echo "    8) 恢复数据"
    echo ""
    echo "    0) 退出"
    echo "=========================================="

    choice=$(read_choice "请输入选项" 0 8)
}

# 选择数据库类型
select_database() {
    echo ""
    echo -e "${BLUE}=========================================="
    echo -e "选择数据库类型:"
    echo -e "==========================================${NC}"
    echo "  1) SQLite (推荐，简单易用，适合大多数场景)"
    echo "  2) 外部 MySQL (已有数据库，在安装时配置)"
    echo ""

    local db_choice=$(read_choice "请选择数据库类型" 1 2)

    case $db_choice in
        1)
            DB_TYPE="sqlite"
            print_success "已选择: SQLite"
            ;;
        2)
            DB_TYPE="mysql_external"
            print_success "已选择: 外部 MySQL"
            print_info "MySQL 连接参数将在 Xboard 安装过程中配置"
            ;;
    esac
}

# 选择网络模式
select_network() {
    echo ""
    echo -e "${BLUE}=========================================="
    echo -e "选择网络模式:"
    echo -e "==========================================${NC}"
    echo "  1) Host 模式 (推荐，性能最佳，直接使用主机网络)"
    echo "  2) Bridge 模式 (端口映射，更好的隔离性)"
    echo ""

    local network_choice=$(read_choice "请选择网络模式" 1 2)

    case $network_choice in
        1)
            NETWORK_MODE="host"
            WEB_PORT="7001"
            # Host 模式检查端口 7001 和 8076 是否被占用
            local host_port_conflict=false
            for check_port in 7001 8076; do
                local hp_in_use=false
                if command -v ss &> /dev/null; then
                    ss -tuln 2>/dev/null | grep -qE "(:|\.)${check_port}([[:space:]]|$)" && hp_in_use=true
                elif command -v netstat &> /dev/null; then
                    netstat -tuln 2>/dev/null | grep -qE "(:|\.)${check_port}([[:space:]]|$)" && hp_in_use=true
                fi
                if [ "$hp_in_use" = "true" ]; then
                    print_warning "端口 $check_port 已被占用"
                    host_port_conflict=true
                fi
            done
            if [ "$host_port_conflict" = "true" ]; then
                print_warning "Host 模式需要端口 7001（Web）和 8076（WebSocket）可用"
                if ! read_confirm "端口存在冲突，是否仍然使用 Host 模式？" "n"; then
                    print_info "请重新选择网络模式"
                    select_network
                    return
                fi
            fi
            print_success "已选择: Host 模式 (端口: 7001, 8076)"
            ;;
        2)
            NETWORK_MODE="bridge"
            print_success "已选择: Bridge 模式"
            echo ""

            while true; do
                WEB_PORT=$(read_input "Web 访问端口" "7001")
                if validate_port "$WEB_PORT"; then
                    # 检查端口是否被占用（兼容 netstat 和 ss 命令）
                    # 使用更精确的正则匹配：:端口号后跟空格或行尾
                    local port_in_use=false
                    if command -v ss &> /dev/null; then
                        ss -tuln 2>/dev/null | grep -qE "(:|\.)${WEB_PORT}([[:space:]]|$)" && port_in_use=true
                    elif command -v netstat &> /dev/null; then
                        netstat -tuln 2>/dev/null | grep -qE "(:|\.)${WEB_PORT}([[:space:]]|$)" && port_in_use=true
                    fi

                    if [ "$port_in_use" = "true" ]; then
                        print_error "端口 $WEB_PORT 已被占用，请选择其他端口"
                    else
                        break
                    fi
                else
                    print_error "无效的端口号"
                fi
            done

            print_info "Web 端口设置为: $WEB_PORT"

            # 检查 ws-server 端口 8076 是否被占用
            local ws_port_in_use=false
            if command -v ss &> /dev/null; then
                ss -tuln 2>/dev/null | grep -qE "(:|\.)(8076)([[:space:]]|$)" && ws_port_in_use=true
            elif command -v netstat &> /dev/null; then
                netstat -tuln 2>/dev/null | grep -qE "(:|\.)(8076)([[:space:]]|$)" && ws_port_in_use=true
            fi
            if [ "$ws_port_in_use" = "true" ]; then
                print_warning "WebSocket 端口 8076 已被占用，ws-server 服务可能无法启动"
                if ! read_confirm "是否仍然继续？" "n"; then
                    print_info "请释放端口 8076 后重试"
                    select_network
                    return
                fi
            fi
            ;;
    esac
}

# 生成 compose.yaml（与之前相同，这里省略...）
generate_compose() {
    local compose_file="$INSTALL_DIR/compose.yaml"

    print_step "生成 docker-compose 配置文件..."

    # 通用 volume 映射（web/horizon/ws-server 共用）
    local common_volumes='    volumes:
      - ./.docker/.data/redis/:/data/
      - ./.env:/www/.env
      - ./.docker/.data/:/www/.docker/.data
      - ./storage/logs:/www/storage/logs
      - ./storage/theme:/www/storage/theme
      - ./storage/app:/www/storage/app
      - ./storage/backup:/www/storage/backup
      - ./storage/framework:/www/storage/framework
      - ./plugins:/www/plugins
      - ./resources:/www/resources
      - ./public/theme:/www/public/theme
      - ./public/assets:/www/public/assets'

    local common_env='    environment:
      - docker=true'

    local common_depends='    depends_on:
      - redis'

    # ========== web 服务 ==========
    {
        echo "services:"
        echo "  web:"
        echo "    image: ghcr.io/cedar2025/xboard:new"
        echo "$common_volumes"
        echo "$common_env"
        echo "$common_depends"
        if [ "$NETWORK_MODE" = "host" ]; then
            echo "    network_mode: host"
        else
            echo "    ports:"
            echo "      - \"${WEB_PORT}:7001\""
        fi
        echo "    command: php artisan octane:start --host=0.0.0.0 --port=7001"
        echo "    restart: unless-stopped"
        echo ""

        # ========== horizon 服务 ==========
        echo "  horizon:"
        echo "    image: ghcr.io/cedar2025/xboard:new"
        echo "$common_volumes"
        echo "$common_env"
        echo "$common_depends"
        if [ "$NETWORK_MODE" = "host" ]; then
            echo "    network_mode: host"
        fi
        echo "    command: php artisan horizon"
        echo "    restart: unless-stopped"
        echo ""

        # ========== ws-server 服务（WebSocket / Laravel Reverb）==========
        echo "  ws-server:"
        echo "    image: ghcr.io/cedar2025/xboard:new"
        echo "$common_volumes"
        echo "$common_env"
        echo "$common_depends"
        if [ "$NETWORK_MODE" = "host" ]; then
            echo "    network_mode: host"
        else
            echo "    ports:"
            echo "      - \"8076:8076\""
        fi
        echo "    command: php artisan ws-server start"
        echo "    restart: unless-stopped"
        echo ""

        # ========== redis 服务 ==========
        echo "  redis:"
        echo "    image: redis:8-alpine"
        echo "    command: redis-server --unixsocket /data/redis.sock --unixsocketperm 777 --save 900 1 --save 300 10 --save 60 10000"
        echo "    restart: unless-stopped"
        echo "    volumes:"
        echo "      - ./.docker/.data/redis:/data"
    } > "$compose_file"

    print_success "配置文件生成完成"
}

# 检测 compose 配置文件路径（兼容多种文件名）
detect_compose_file() {
    local dir="${1:-$INSTALL_DIR}"
    if [ -f "$dir/compose.yaml" ]; then
        echo "$dir/compose.yaml"
    elif [ -f "$dir/compose.yml" ]; then
        echo "$dir/compose.yml"
    elif [ -f "$dir/docker-compose.yaml" ]; then
        echo "$dir/docker-compose.yaml"
    elif [ -f "$dir/docker-compose.yml" ]; then
        echo "$dir/docker-compose.yml"
    else
        echo ""
    fi
}

# 自动补丁: 检测并修补 compose 配置中缺失的 volume 映射（用于旧版部署升级）
patch_compose_volumes() {
    local compose_file
    compose_file=$(detect_compose_file)

    if [ -z "$compose_file" ] || [ ! -f "$compose_file" ]; then
        print_warning "未找到 compose 配置文件（已检查 compose.yaml/yml、docker-compose.yaml/yml），跳过映射补丁"
        return 1
    fi

    local compose_basename
    compose_basename=$(basename "$compose_file")
    print_info "检测到配置文件: $compose_basename"

    # 需要存在的映射列表（新增的 6 个，含 resources）
    local -a required_mappings=(
        "./resources:/www/resources"
        "./storage/app:/www/storage/app"
        "./storage/backup:/www/storage/backup"
        "./storage/framework:/www/storage/framework"
        "./public/theme:/www/public/theme"
        "./public/assets:/www/public/assets"
    )

    # 检测是否使用了 ./:/www/ 全量映射（master 分支 compose.sample.yaml 的方式）
    if grep -qE '\./:/www/?' "$compose_file"; then
        print_success "检测到全量目录映射 (./:/www/)，所有目录已自动包含，无需补丁"
        return 0
    fi

    local patched=false
    # 使用 ./plugins:/www/plugins 作为锚点（官方原版 compose.yaml 各服务均存在此行）
    local anchor="./plugins:/www/plugins"

    # 预检: 锚点必须在 compose 配置中存在，否则跳过并提示手动处理
    if ! grep -qF "$anchor" "$compose_file"; then
        print_warning "$compose_basename 中未找到锚点映射 ($anchor)，无法自动补丁"
        print_info "请手动在各服务的 volumes 段添加以下映射:"
        for mapping in "${required_mappings[@]}"; do
            if ! grep -qF "$mapping" "$compose_file"; then
                echo "      - $mapping"
            fi
        done
        return 1
    fi

    # 自适应缩进：从锚点行提取实际缩进前缀（兼容不同空格/tab 风格）
    local indent_prefix
    indent_prefix=$(grep -m1 -F "$anchor" "$compose_file" | sed "s|${anchor}.*||")
    # indent_prefix 现在包含锚点行 "- ./plugins..." 前面的全部空白

    # 修改前备份，以便验证失败时回滚
    cp "$compose_file" "${compose_file}.patch_bak"

    for mapping in "${required_mappings[@]}"; do
        if ! grep -qF "$mapping" "$compose_file"; then
            # 使用与锚点行相同的缩进前缀追加映射
            sed -i "\\|${anchor}|a\\${indent_prefix}- ${mapping}" "$compose_file"
            print_info "  补充映射: $mapping"
            patched=true
        fi
    done

    if [ "$patched" = "true" ]; then
        # 验证修改后的 YAML 语法是否正确
        if docker compose -f "$compose_file" config > /dev/null 2>&1; then
            rm -f "${compose_file}.patch_bak"
            print_success "$compose_basename 已自动补充缺失的目录映射"
        else
            print_error "补丁后 YAML 语法校验失败，正在回滚..."
            mv "${compose_file}.patch_bak" "$compose_file"
            print_warning "已回滚到补丁前状态，请手动添加以下映射:"
            for mapping in "${required_mappings[@]}"; do
                if ! grep -qF "$mapping" "$compose_file"; then
                    echo "      - $mapping"
                fi
            done
            return 1
        fi
    else
        rm -f "${compose_file}.patch_bak"
        print_success "$compose_basename 映射已是最新，无需补充"
    fi
}

# 保存配置（使用 printf 逐行写入，避免 heredoc 展开 $ 反引号等特殊字符）
save_config() {
    local install_date
    install_date=$(date '+%Y-%m-%d %H:%M:%S')
    {
        printf "DB_TYPE='%s'\n" "$DB_TYPE"
        printf "NETWORK_MODE='%s'\n" "$NETWORK_MODE"
        printf "MYSQL_ROOT_PASSWORD='%s'\n" "$(escape_password "$MYSQL_ROOT_PASSWORD")"
        printf "MYSQL_DATABASE='%s'\n" "$MYSQL_DATABASE"
        printf "MYSQL_USER='%s'\n" "$MYSQL_USER"
        printf "MYSQL_PASSWORD='%s'\n" "$(escape_password "$MYSQL_PASSWORD")"
        printf "DB_HOST='%s'\n" "$DB_HOST"
        printf "DB_PORT='%s'\n" "$DB_PORT"
        printf "WEB_PORT='%s'\n" "$WEB_PORT"
        printf "ADMIN_EMAIL='%s'\n" "$ADMIN_EMAIL"
        printf "ADMIN_PASSWORD='%s'\n" "$(escape_password "$ADMIN_PASSWORD")"
        printf "ADMIN_PANEL_URL='%s'\n" "$ADMIN_PANEL_URL"
        printf "INSTALL_DATE='%s'\n" "$install_date"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"  # 保护配置文件
    print_success "配置已保存"
}

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

# 全新部署
deploy_xboard() {
    show_logo
    print_info "开始全新部署 Xboard..."
    echo ""

    # 检查已存在
    if [ -d "$INSTALL_DIR" ]; then
        print_warning "检测到已存在安装目录: $INSTALL_DIR"
        if read_confirm "是否删除并重新安装？"; then
            cd /
            rm -rf "$INSTALL_DIR"
            print_success "已删除旧安装"
        else
            print_info "部署已取消"
            return 1
        fi
    fi

    # 克隆仓库
    print_step "克隆 Xboard 仓库..."
    if git clone -b compose --depth 1 https://github.com/cedar2025/Xboard "$INSTALL_DIR"; then
        print_success "仓库克隆完成"
    else
        print_error "克隆失败，请检查："
        echo "  1. 网络连接是否正常"
        echo "  2. GitHub 是否可访问"
        echo "  3. 是否有足够的磁盘空间"
        return 1
    fi

    cd "$INSTALL_DIR"

    # 配置选择
    select_database
    select_network

    # 管理员账号
    echo ""
    print_step "配置管理员账号..."
    while true; do
        ADMIN_EMAIL=$(read_input "管理员邮箱" "admin@demo.com")
        if validate_email "$ADMIN_EMAIL"; then
            break
        else
            print_error "邮箱格式不正确"
        fi
    done

    # 生成配置
    generate_compose

    # 创建必要目录
    print_step "创建必要目录..."
    mkdir -p resources plugins \
             storage/logs storage/theme storage/app storage/backup storage/framework \
             public/theme public/assets \
             .docker/.data .docker/.data/redis

    # 创建空的 .env 文件（安装时会被填充）
    touch .env

    # 先拉取镜像
    print_step "拉取 Docker 镜像（首次可能较慢）..."
    if ! docker pull ghcr.io/cedar2025/xboard:new; then
        print_error "镜像拉取失败，请检查网络连接"
        return 1
    fi
    print_success "镜像拉取完成"

    # 从容器复制初始资源文件
    print_step "准备 resources 目录..."
    docker run --rm -v "$(pwd)/resources:/tmp/resources" ghcr.io/cedar2025/xboard:new cp -r /www/resources/. /tmp/resources/ 2>/dev/null || true
    print_success "resources 目录已准备"

    print_step "准备 public/theme 目录..."
    docker run --rm -v "$(pwd)/public/theme:/tmp/public_theme" ghcr.io/cedar2025/xboard:new cp -r /www/public/theme/. /tmp/public_theme/ 2>/dev/null || true
    print_success "public/theme 目录已准备"

    print_step "准备 public/assets 目录..."
    docker run --rm -v "$(pwd)/public/assets:/tmp/public_assets" ghcr.io/cedar2025/xboard:new cp -r /www/public/assets/. /tmp/public_assets/ 2>/dev/null || true
    print_success "public/assets 目录已准备"

    print_step "准备 storage/framework 目录..."
    docker run --rm -v "$(pwd)/storage/framework:/tmp/framework" ghcr.io/cedar2025/xboard:new cp -r /www/storage/framework/. /tmp/framework/ 2>/dev/null || true
    print_success "storage/framework 目录已准备"

    # 确认部署
    echo ""
    echo -e "${YELLOW}=========================================="
    echo -e "部署配置确认:"
    echo -e "==========================================${NC}"
    echo "数据库类型: $DB_TYPE"
    echo "网络模式: $NETWORK_MODE"
    echo "Web 端口: $WEB_PORT"
    echo "管理员邮箱: $ADMIN_EMAIL"
    echo ""

    if ! read_confirm "确认开始部署？" "y"; then
        print_info "部署已取消"
        if read_confirm "是否清理已创建的目录？" "y"; then
            cd /
            rm -rf "$INSTALL_DIR"
            print_success "目录已清理"
        fi
        return 1
    fi

    # 执行安装
    echo ""

    # 启动 Redis
    print_step "启动 Redis 服务..."
    docker compose up -d redis
    sleep 3

    print_step "执行 Xboard 安装（这可能需要几分钟）..."

    # 构建安装命令（使用数组避免特殊字符问题）
    local -a install_args=("docker" "compose" "run" "--rm")
    # 检测 TTY，有终端时才加 -it（cron/CI 环境无 TTY）
    if [ -t 0 ]; then
        install_args+=("-it")
    fi

    # SQLite 模式自动配置，外部 MySQL 由 Xboard 安装程序交互式配置
    if [ "$DB_TYPE" = "sqlite" ]; then
        install_args+=("-e" "ENABLE_SQLITE=true")
    fi

    install_args+=("-e" "ENABLE_REDIS=true" "-e" "ADMIN_ACCOUNT=$ADMIN_EMAIL" "web" "php" "artisan" "xboard:install")

    # 执行安装并捕获输出以提取密码
    local install_output
    install_output=$(mktemp)

    # 使用 pipefail 确保管道中 docker 命令的退出码能被正确捕获
    set -o pipefail
    if "${install_args[@]}" 2>&1 | tee "$install_output"; then
        set +o pipefail
        print_success "Xboard 安装完成"

        # 从输出中提取管理员密码和面板地址（兼容无 grep -P 的环境）
        ADMIN_PASSWORD=$(grep -o '管理员密码：[a-zA-Z0-9]*' "$install_output" 2>/dev/null | sed 's/管理员密码：//' || echo "")
        ADMIN_PANEL_URL=$(grep -o '站点/[a-zA-Z0-9]*' "$install_output" 2>/dev/null | tail -1 | sed 's|站点/||' || echo "")

        rm -f "$install_output"
    else
        set +o pipefail
        rm -f "$install_output"
        print_error "安装失败"
        print_step "清理已启动的容器..."
        docker compose down 2>/dev/null || true
        print_info "可以查看日志排查问题: docker compose logs"
        return 1
    fi

    # 启动服务
    print_step "启动服务..."
    docker compose up -d

    # 保存配置（包含密码）
    save_config

    # 等待启动
    print_step "等待服务启动..."
    sleep 10

    # 显示信息
    show_deploy_info
}

# 显示部署信息
show_deploy_info() {
    # 先获取公网IP（如果未缓存会稍有延迟）
    if [ -z "$PUBLIC_IP_CACHE" ]; then
        printf "${CYAN}[→]${NC} 正在获取服务器公网IP..."
        local server_ip=$(get_public_ip)
        printf "\r\033[K"  # 清除该行
    else
        local server_ip=$(get_public_ip)
    fi

    show_logo
    print_success "Xboard 部署成功！"
    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "部署信息:"
    echo -e "==========================================${NC}"
    echo "安装目录: $INSTALL_DIR"
    echo "数据库类型: $DB_TYPE"
    echo "网络模式: $NETWORK_MODE"

    # IPv6 地址需要用 [] 包裹才能构成有效 URL
    local url_ip="$server_ip"
    if [[ "$server_ip" == *:* ]]; then
        url_ip="[${server_ip}]"
    fi

    if [ "$NETWORK_MODE" = "host" ]; then
        local access_url="http://${url_ip}:7001"
    else
        local access_url="http://${url_ip}:$WEB_PORT"
    fi
    echo "访问地址: $access_url"

    echo ""
    echo -e "${RED}=========================================="
    echo -e "⚠️  管理员账号信息（请务必保存！）:"
    echo -e "==========================================${NC}"
    echo "管理员邮箱: $ADMIN_EMAIL"
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo -e "管理员密码: ${YELLOW}$ADMIN_PASSWORD${NC}"
    else
        echo "管理员密码: (请查看上方安装日志)"
    fi
    if [ -n "$ADMIN_PANEL_URL" ]; then
        echo -e "管理面板: ${access_url}/${ADMIN_PANEL_URL}"
    fi
    echo ""
    echo -e "${YELLOW}如果遗失密码，可以通过以下命令重置:${NC}"
    echo "  cd $INSTALL_DIR"
    echo "  docker compose exec web php artisan reset:password $ADMIN_EMAIL"
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "文件目录:"
    echo -e "==========================================${NC}"
    echo "  邮件模板:     $INSTALL_DIR/resources/views/mail/"
    echo "  语言包:       $INSTALL_DIR/resources/lang/"
    echo "  日志目录:     $INSTALL_DIR/storage/logs/"
    echo "  主题存储:     $INSTALL_DIR/storage/theme/"
    echo "  应用存储:     $INSTALL_DIR/storage/app/"
    echo "  备份目录:     $INSTALL_DIR/storage/backup/"
    echo "  框架缓存:     $INSTALL_DIR/storage/framework/"
    echo "  插件目录:     $INSTALL_DIR/plugins/"
    echo "  前端主题:     $INSTALL_DIR/public/theme/"
    echo "  前端资源:     $INSTALL_DIR/public/assets/"
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "常用命令:"
    echo -e "==========================================${NC}"
    echo "cd $INSTALL_DIR"
    echo "docker compose logs -f        # 查看日志"
    echo "docker compose restart        # 重启服务"
    echo "docker compose ps             # 查看状态"
    echo "=========================================="
    echo ""
    read -e -p "按 Enter 键返回主菜单..."
}

# 升级
upgrade_xboard() {
    show_logo
    print_info "开始升级 Xboard..."

    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "未找到安装目录"
        return 1
    fi

    cd "$INSTALL_DIR"

    if read_confirm "是否先备份数据？" "y"; then
        # 传入 no_restart 参数：备份后不重启服务，避免升级过程中无谓的 停→启→停 抖动
        backup_data "upgrade_backup_$(date +%Y%m%d_%H%M%S)" "silent" "no_restart"
    fi

    print_step "拉取最新镜像..."
    if ! docker compose pull; then
        print_error "镜像拉取失败，请检查网络连接"
        if ! read_confirm "仍要继续升级（使用本地镜像）？" "n"; then
            return 1
        fi
    fi

    # 升级前从旧容器提取未映射的自定义文件（防止数据丢失）
    # 注意：必须在 stop 之前获取容器ID（运行中的容器，docker cp 也支持已停止的容器）
    print_step "检查并提取旧容器中未映射的自定义文件..."
    local web_container
    web_container=$(docker compose ps -aq web 2>/dev/null)
    if [ -n "$web_container" ]; then
        for dir in resources public/theme public/assets storage/framework; do
            if [ ! -d "$INSTALL_DIR/$dir" ] || [ -z "$(ls -A "$INSTALL_DIR/$dir" 2>/dev/null)" ]; then
                mkdir -p "$INSTALL_DIR/$dir"
                docker cp "$web_container:/www/$dir/." "$INSTALL_DIR/$dir/" 2>/dev/null || true
                print_info "  已从旧容器提取: $dir"
            fi
        done
    fi

    # 使用 stop 而非 down：只停止容器不删除，更安全（保留容器状态便于排查）
    # 后续 docker compose up -d 会自动检测镜像更新并重建容器
    print_step "停止旧服务..."
    docker compose stop

    # 同步 resources 目录（只复制新文件，不覆盖已存在的文件）
    print_step "同步 resources 目录..."
    docker run --rm -v "$(pwd)/resources:/tmp/resources" ghcr.io/cedar2025/xboard:new \
        sh -c 'cd /www/resources && find . -type f | while read f; do
            if [ ! -f "/tmp/resources/$f" ]; then
                mkdir -p "/tmp/resources/$(dirname "$f")"
                cp "$f" "/tmp/resources/$f"
            fi
        done'
    print_success "resources 目录同步完成（已保留您的自定义文件）"

    # 同步 public/theme 目录（只补缺，不覆盖用户自定义的主题文件）
    print_step "同步 public/theme 目录..."
    mkdir -p public/theme
    docker run --rm -v "$(pwd)/public/theme:/tmp/public_theme" ghcr.io/cedar2025/xboard:new \
        sh -c 'cd /www/public/theme && find . -type f | while read f; do
            if [ ! -f "/tmp/public_theme/$f" ]; then
                mkdir -p "/tmp/public_theme/$(dirname "$f")"
                cp "$f" "/tmp/public_theme/$f"
            fi
        done' 2>/dev/null || true
    print_success "public/theme 目录同步完成（已保留您的自定义主题）"

    # 同步 public/assets 目录（全量更新，编译产物需要跟随版本）
    print_step "同步 public/assets 目录..."
    mkdir -p public/assets
    docker run --rm -v "$(pwd)/public/assets:/tmp/public_assets" ghcr.io/cedar2025/xboard:new \
        cp -r /www/public/assets/. /tmp/public_assets/ 2>/dev/null || true
    print_success "public/assets 目录同步完成"

    # 同步 storage/framework 目录（确保缓存结构完整）
    print_step "同步 storage/framework 目录..."
    mkdir -p storage/framework
    docker run --rm -v "$(pwd)/storage/framework:/tmp/framework" ghcr.io/cedar2025/xboard:new \
        sh -c 'for d in cache data sessions testing views; do
            mkdir -p "/tmp/framework/$d"
        done' 2>/dev/null || true
    print_success "storage/framework 目录同步完成"

    # 确保其他映射目录存在
    mkdir -p storage/app storage/backup

    # 自动补丁: 检测并更新 compose.yaml 中缺失的 volume 映射
    print_step "检查 compose.yaml 目录映射..."
    patch_compose_volumes

    # 执行升级命令（官方流程：docker compose run -it --rm web php artisan xboard:update）
    print_step "执行 Xboard 升级..."
    local -a update_args=("docker" "compose" "run" "--rm")
    if [ -t 0 ]; then
        update_args+=("-it")
    fi
    update_args+=("web" "php" "artisan" "xboard:update")

    if "${update_args[@]}"; then
        print_success "Xboard 升级完成"
    else
        print_warning "升级命令执行异常，请检查输出日志"
        if ! read_confirm "是否仍然启动服务？" "y"; then
            print_info "可手动执行: cd $INSTALL_DIR && docker compose up -d"
            return 1
        fi
    fi

    print_step "启动新服务..."
    docker compose up -d

    print_success "升级完成！"
    docker compose ps

    read -e -p "按 Enter 键返回主菜单..."
}

# 卸载
uninstall_xboard() {
    show_logo
    print_warning "即将卸载 Xboard"
    echo ""

    if read_confirm "是否备份数据？" "y"; then
        backup_data "uninstall_backup_$(date +%Y%m%d_%H%M%S)" "silent"
    fi

    echo ""
    print_error "此操作将删除所有容器和数据！"

    if ! read_confirm "确认卸载？" "n"; then
        print_info "已取消卸载"
        return 0
    fi

    # 二次确认
    echo ""
    read -e -p "请输入 'DELETE' 确认删除: " confirm
    if [ "$confirm" != "DELETE" ]; then
        print_info "已取消卸载"
        return 0
    fi

    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        print_step "停止并删除容器..."
        docker compose down -v 2>/dev/null || true

        cd /
        print_step "删除安装目录..."
        rm -rf "$INSTALL_DIR"

        print_success "Xboard 已卸载"
    else
        print_warning "安装目录不存在: $INSTALL_DIR"
        print_info "可能已经被删除"
    fi

    read -e -p "按 Enter 键返回主菜单..."
}

# 重启服务
restart_service() {
    show_logo
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "未找到安装目录"
        return 1
    fi

    cd "$INSTALL_DIR"
    print_step "重启服务..."
    docker compose restart
    print_success "服务已重启"
    docker compose ps

    read -e -p "按 Enter 键返回主菜单..."
}

# 查看日志
view_logs() {
    show_logo
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "未找到安装目录"
        return 1
    fi

    cd "$INSTALL_DIR"

    # 检查是否有 MySQL 服务
    local has_mysql=false
    if docker compose config --services 2>/dev/null | grep -q "mysql"; then
        has_mysql=true
    fi

    echo "选择查看的日志:"
    echo "  1) Web 服务"
    echo "  2) Horizon 队列"
    echo "  3) Redis"
    echo "  4) WebSocket (ws-server)"
    if [ "$has_mysql" = "true" ]; then
        echo "  5) MySQL"
        echo "  6) 所有服务"
        echo ""
        print_info "提示: 按 Ctrl+C 退出日志查看"
        echo ""
        local log_choice=$(read_choice "请选择" 1 6)
    else
        echo "  5) 所有服务"
        echo ""
        print_info "提示: 按 Ctrl+C 退出日志查看"
        echo ""
        local log_choice=$(read_choice "请选择" 1 5)
    fi

    # 临时忽略 SIGINT，让 docker compose logs -f 能被 Ctrl+C 正常中断而不退出脚本
    trap '' SIGINT

    case $log_choice in
        1) docker compose logs -f --tail=100 web ;;
        2) docker compose logs -f --tail=100 horizon ;;
        3) docker compose logs -f --tail=100 redis ;;
        4) docker compose logs -f --tail=100 ws-server ;;
        5)
            if [ "$has_mysql" = "true" ]; then
                docker compose logs -f --tail=100 mysql
            else
                docker compose logs -f --tail=100
            fi
            ;;
        6) docker compose logs -f --tail=100 ;;
    esac

    # 恢复 SIGINT 信号处理
    trap cleanup SIGINT

    echo ""
    read -e -p "按 Enter 键返回主菜单..."
}

# 查看状态
view_status() {
    show_logo
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "未找到安装目录"
        return 1
    fi

    cd "$INSTALL_DIR"
    print_info "服务状态:"
    docker compose ps

    echo ""
    print_info "磁盘使用:"
    du -sh "$INSTALL_DIR"
    du -sh "$INSTALL_DIR/.docker/.data" 2>/dev/null || true

    if load_config; then
        echo ""
        print_info "配置信息:"
        echo "数据库类型: $DB_TYPE"
        echo "网络模式: $NETWORK_MODE"
        echo "Web 端口: $WEB_PORT"
        echo "管理员邮箱: $ADMIN_EMAIL"
        if [ -n "$ADMIN_PASSWORD" ]; then
            echo -e "管理员密码: ${YELLOW}$ADMIN_PASSWORD${NC}"
        fi
        if [ -n "$ADMIN_PANEL_URL" ]; then
            echo "管理面板路径: /$ADMIN_PANEL_URL"
        fi
        echo "安装时间: $INSTALL_DATE"
    fi

    read -e -p "按 Enter 键返回主菜单..."
}

# 备份数据
backup_data() {
    local backup_name="${1:-backup_$(date +%Y%m%d_%H%M%S)}"
    local backup_dir="/root/xboard_backups/$backup_name"

    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "未找到安装目录"
        return 1
    fi

    cd "$INSTALL_DIR"

    # 显示备份内容说明
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "将要备份的内容:"
    echo -e "==========================================${NC}"
    echo "  • .env              - 站点环境配置"
    echo "  • compose.yaml      - Docker 配置"
    echo "  • .docker/.data/    - 数据目录 (包含 SQLite 数据库、Redis 数据)"
    echo "  • storage/          - 存储目录 (日志、主题、上传文件、备份、缓存)"
    echo "  • resources/        - 资源目录 (邮件模板、语言包等)"
    echo "  • plugins/          - 插件目录"
    echo "  • public/theme/     - 前端主题静态资源"
    echo "  • public/assets/    - 前端编译资源"
    echo ""

    # 显示预估备份大小
    print_info "预估备份大小:"
    du -sh "$INSTALL_DIR" 2>/dev/null || echo "  无法计算"
    echo ""

    # 检查磁盘空间
    local available_space=$(df -BM /root 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'M')
    local install_size=$(du -sm "$INSTALL_DIR" 2>/dev/null | awk '{print $1}')
    if [ -n "$available_space" ] && [ -n "$install_size" ]; then
        if [ "$available_space" -lt "$install_size" ]; then
            print_warning "磁盘空间可能不足！可用: ${available_space}MB, 需要: ${install_size}MB"
            if ! read_confirm "仍要继续备份？" "n"; then
                return 1
            fi
        fi
    fi

    print_step "开始备份到: $backup_dir"
    mkdir -p "$backup_dir"

    # 停止服务以确保数据一致性（尤其是 SQLite）
    print_step "暂停服务以保证数据一致性..."
    docker compose stop 2>/dev/null || true

    # 备份配置文件（兼容多种 compose 文件名）
    print_step "备份配置文件..."
    cp -r .env "$backup_dir/" 2>/dev/null || true
    local detected_compose
    detected_compose=$(detect_compose_file)
    if [ -n "$detected_compose" ] && [ -f "$detected_compose" ]; then
        cp -r "$detected_compose" "$backup_dir/" 2>/dev/null || true
    fi
    cp -r "$CONFIG_FILE" "$backup_dir/" 2>/dev/null || true

    # 备份数据目录（包含 SQLite 数据库）
    print_step "备份数据目录 (SQLite 数据库 + Redis)..."
    tar -czf "$backup_dir/data.tar.gz" .docker/.data 2>/dev/null || true

    # 检测并备份 Docker named volume 中的 Redis 数据（官方 compose.yaml 使用 named volume）
    # Docker Compose v2 创建的 named volume 带项目前缀，如 xboard_redis-data
    # 需要动态查找而非硬编码名称
    local redis_vol
    redis_vol=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep 'redis-data$' | head -1)
    if [ -n "$redis_vol" ]; then
        print_step "检测到 Redis named volume ($redis_vol)，额外备份..."
        docker run --rm -v "$redis_vol":/data -v "$backup_dir":/backup \
            alpine tar czf /backup/redis-volume.tar.gz -C / data 2>/dev/null || true
        print_success "Redis named volume 已备份 (redis-volume.tar.gz)"
    fi

    # 备份 storage 目录
    print_step "备份存储目录..."
    tar -czf "$backup_dir/storage.tar.gz" storage 2>/dev/null || true

    # 备份自定义文件
    print_step "备份自定义文件..."
    tar -czf "$backup_dir/resources.tar.gz" resources 2>/dev/null || true
    tar -czf "$backup_dir/plugins.tar.gz" plugins 2>/dev/null || true
    tar -czf "$backup_dir/public.tar.gz" public/theme public/assets 2>/dev/null || true

    # 重新启动服务（第3个参数为 no_restart 时跳过，用于升级场景避免无谓抖动）
    if [ "$3" != "no_restart" ]; then
        print_step "重新启动服务..."
        docker compose up -d 2>/dev/null || true
    else
        print_info "跳过重启（后续流程将负责启动服务）"
    fi

    print_success "备份完成: $backup_dir"
    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "备份文件说明:"
    echo -e "==========================================${NC}"
    echo "  data.tar.gz      - SQLite 数据库 + Redis 数据"
    echo "  storage.tar.gz   - 日志、主题、上传文件、备份、缓存等"
    echo "  resources.tar.gz - 邮件模板、语言包等资源"
    echo "  plugins.tar.gz   - 插件文件"
    echo "  public.tar.gz    - 前端主题 + 前端编译资源"
    echo "  .env             - 环境配置"
    echo "  compose.yaml     - Docker 配置"
    echo ""
    print_info "备份文件列表:"
    ls -lh "$backup_dir"
    echo ""
    print_info "备份总大小: $(du -sh "$backup_dir" | awk '{print $1}')"

    if [ "$2" != "silent" ]; then
        read -e -p "按 Enter 键返回主菜单..."
    fi
}

# 恢复数据
restore_data() {
    show_logo
    local backup_base="/root/xboard_backups"

    if [ ! -d "$backup_base" ]; then
        print_error "未找到备份目录"
        return 1
    fi

    print_info "可用的备份:"
    ls -1 "$backup_base"
    echo ""

    local backup_name=$(read_input "输入备份名称" "")
    local backup_dir="$backup_base/$backup_name"

    if [ ! -d "$backup_dir" ]; then
        print_error "备份不存在"
        return 1
    fi

    # 验证备份完整性
    print_info "备份内容:"
    ls -lh "$backup_dir"
    echo ""

    # 检查关键文件（兼容多种 compose 文件名）
    local missing_files=""
    [ ! -f "$backup_dir/.env" ] && missing_files="$missing_files .env"
    local backup_compose
    backup_compose=$(detect_compose_file "$backup_dir")
    [ -z "$backup_compose" ] && missing_files="$missing_files compose配置文件"

    if [ -n "$missing_files" ]; then
        print_warning "备份中缺少以下关键文件:$missing_files"
        if ! read_confirm "仍要继续恢复？" "n"; then
            return 1
        fi
    fi

    print_warning "恢复将覆盖当前数据！"
    if ! read_confirm "确认恢复？" "n"; then
        return 0
    fi

    # 检查安装目录是否存在
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "安装目录不存在: $INSTALL_DIR"
        print_info "请先执行全新部署或手动创建目录"
        return 1
    fi

    cd "$INSTALL_DIR"
    docker compose down 2>/dev/null || true

    print_step "恢复配置文件..."
    cp "$backup_dir/.env" ./ 2>/dev/null || true
    if [ -n "$backup_compose" ] && [ -f "$backup_compose" ]; then
        cp "$backup_compose" ./ 2>/dev/null || true
    fi

    print_step "恢复数据目录..."
    tar -xzf "$backup_dir/data.tar.gz" -C ./ 2>/dev/null || true
    tar -xzf "$backup_dir/storage.tar.gz" -C ./ 2>/dev/null || true

    print_step "恢复自定义文件..."
    tar -xzf "$backup_dir/resources.tar.gz" -C ./ 2>/dev/null || true
    tar -xzf "$backup_dir/plugins.tar.gz" -C ./ 2>/dev/null || true
    tar -xzf "$backup_dir/public.tar.gz" -C ./ 2>/dev/null || true

    # 恢复 Redis named volume 数据（如果备份中包含）
    if [ -f "$backup_dir/redis-volume.tar.gz" ]; then
        print_step "恢复 Redis named volume 数据..."
        local redis_vol
        redis_vol=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep 'redis-data$' | head -1)
        if [ -n "$redis_vol" ]; then
            docker run --rm -v "$redis_vol":/data -v "$backup_dir":/backup \
                alpine sh -c 'cd / && tar xzf /backup/redis-volume.tar.gz' 2>/dev/null || true
            print_success "Redis named volume 数据已恢复"
        else
            # named volume 不存在时尝试创建后恢复（适用于全新环境恢复场景）
            print_info "未找到现有 Redis named volume，尝试创建并恢复..."
            # 从 compose 配置中读取 volume 名称前缀
            local project_name
            project_name=$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]')
            local vol_name="${project_name}_redis-data"
            docker volume create "$vol_name" 2>/dev/null || true
            docker run --rm -v "$vol_name":/data -v "$backup_dir":/backup \
                alpine sh -c 'cd / && tar xzf /backup/redis-volume.tar.gz' 2>/dev/null || true
            print_success "Redis named volume ($vol_name) 已创建并恢复数据"
        fi
    fi

    # 自动补丁: 恢复的 compose.yaml 可能是旧版格式，检测并补充缺失映射
    print_step "检查 compose.yaml 目录映射..."
    patch_compose_volumes

    docker compose up -d
    print_success "恢复完成"

    read -e -p "按 Enter 键返回主菜单..."
}

# 清理函数（用于信号处理）
cleanup() {
    echo ""
    print_info "收到退出信号，正在退出..."
    exit 0
}

# 检测包管理器
detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v apk &> /dev/null; then
        echo "apk"
    else
        echo "unknown"
    fi
}

# 安装 Docker
install_docker() {
    print_step "正在安装 Docker..."
    if curl -fsSL https://get.docker.com | sh; then
        print_success "Docker 安装完成"
        # 启动 Docker 服务
        systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
        systemctl enable docker 2>/dev/null || true
        return 0
    else
        print_error "Docker 安装失败"
        return 1
    fi
}

# 安装 Git
install_git() {
    local pkg_manager=$(detect_package_manager)
    print_step "正在安装 Git..."

    case $pkg_manager in
        apt)
            apt-get update -qq && apt-get install -y -qq git
            ;;
        yum)
            yum install -y -q git
            ;;
        dnf)
            dnf install -y -q git
            ;;
        apk)
            apk add --quiet git
            ;;
        *)
            print_error "无法识别的包管理器，请手动安装 Git"
            return 1
            ;;
    esac

    if command -v git &> /dev/null; then
        print_success "Git 安装完成"
        return 0
    else
        print_error "Git 安装失败"
        return 1
    fi
}

# 环境检查（仅首次运行时执行）
check_environment() {
    echo -e "${BLUE}正在检查运行环境...${NC}"
    echo ""

    # 检查 root
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 权限运行"
        exit 1
    fi
    print_success "Root 权限检查通过"

    # 检查 Docker 是否安装
    if ! command -v docker &> /dev/null; then
        print_warning "未安装 Docker"
        if read_confirm "是否自动安装 Docker？" "y"; then
            if ! install_docker; then
                print_error "Docker 安装失败，请手动安装"
                print_info "安装命令: curl -fsSL https://get.docker.com | sh"
                exit 1
            fi
        else
            print_error "Docker 是必需的，无法继续"
            exit 1
        fi
    else
        print_success "Docker 已安装"
    fi

    # 检查 Docker 服务是否运行
    if ! run_with_spinner "检查 Docker 服务状态" docker ps; then
        print_warning "Docker 服务未运行，尝试启动..."
        systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
        sleep 2
        if ! docker ps &> /dev/null; then
            print_error "Docker 服务无法启动"
            print_info "请手动启动: systemctl start docker"
            exit 1
        fi
        print_success "Docker 服务已启动"
    fi

    # 检查 Docker Compose
    if ! run_with_spinner "检查 Docker Compose" docker compose version; then
        print_error "Docker Compose 不可用"
        print_info "请确保 Docker 版本 >= 20.10 或安装 docker-compose-plugin"
        exit 1
    fi

    # 检查 Git
    if ! command -v git &> /dev/null; then
        print_warning "未安装 Git"
        if read_confirm "是否自动安装 Git？" "y"; then
            if ! install_git; then
                print_error "Git 安装失败，请手动安装"
                exit 1
            fi
        else
            print_error "Git 是必需的，无法继续"
            exit 1
        fi
    else
        print_success "Git 已安装"
    fi

    echo ""
    sleep 0.5
}

# 主程序
main() {
    # 设置信号处理
    trap cleanup SIGINT SIGTERM

    # 首次运行时检查环境
    check_environment

    while true; do
        show_menu

        case $choice in
            1) deploy_xboard ;;
            2) upgrade_xboard ;;
            3) uninstall_xboard ;;
            4) restart_service ;;
            5) view_logs ;;
            6) view_status ;;
            7)
                local backup_name=$(read_input "备份名称（留空自动生成）" "")
                backup_data "$backup_name"
                ;;
            8) restore_data ;;
            0)
                print_info "感谢使用，再见！"
                exit 0
                ;;
            *)
                print_error "无效选项"
                sleep 2
                ;;
        esac
    done
}

# 运行主程序
main
