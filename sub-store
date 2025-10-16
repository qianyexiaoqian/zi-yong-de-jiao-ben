#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    elif ss -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    return 0
}

# 验证端口号
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 验证访问路径（不含开头的 /）
validate_path() {
    local path=$1
    # 长度至少19个字符，只包含字母数字和 /
    if [ ${#path} -lt 19 ]; then
        return 1
    fi
    if [[ ! "$path" =~ ^[a-zA-Z0-9/]+$ ]]; then
        return 1
    fi
    return 0
}

# 生成随机路径（不含开头的 /）
generate_random_path() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1
}

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    
    if ! command -v docker compose &> /dev/null && ! command -v docker-compose &> /dev/null; then
        print_error "Docker Compose 未安装，请先安装 Docker Compose"
        exit 1
    fi
}

# 获取已部署的实例列表
get_deployed_instances() {
    local instances=()
    if [ -d "/root/sub-store-configs" ]; then
        for config in /root/sub-store-configs/store-*.yaml; do
            if [ -f "$config" ]; then
                local instance_name=$(basename "$config" .yaml)
                instances+=("$instance_name")
            fi
        done
    fi
    echo "${instances[@]}"
}

# 检查实例编号是否已存在
check_instance_exists() {
    local instance_num=$1
    if [ -f "/root/sub-store-configs/store-$instance_num.yaml" ]; then
        return 0  # 存在
    fi
    return 1  # 不存在
}

# 可编辑的输入函数（支持退格删除）
read_editable() {
    local prompt="$1"
    local default="$2"
    local result
    
    if [ -n "$default" ]; then
        # 有默认值时使用 -i 参数
        read -e -p "$prompt" -i "$default" result
    else
        # 无默认值时不使用 -i 参数
        read -e -p "$prompt" result
    fi
    echo "$result"
}

# 安装新实例
install_instance() {
    clear
    echo "=================================="
    echo "    Sub-Store 实例安装向导"
    echo "=================================="
    echo ""
    
    # 获取建议的实例编号
    local instances=($(get_deployed_instances))
    local suggested_num=1
    if [ ${#instances[@]} -gt 0 ]; then
        print_info "已存在 ${#instances[@]} 个实例"
        suggested_num=$((${#instances[@]} + 1))
    fi
    
    # 输入实例编号
    local instance_num
    while true; do
        echo ""
        instance_num=$(read_editable "请输入实例编号（建议: $suggested_num）: ")
        
        if [ -z "$instance_num" ]; then
            print_error "实例编号不能为空"
            continue
        fi
        
        if ! [[ "$instance_num" =~ ^[0-9]+$ ]]; then
            print_error "实例编号必须是数字"
            continue
        fi
        
        if check_instance_exists "$instance_num"; then
            print_error "实例编号 $instance_num 已存在，请选择其他编号"
            continue
        fi
        
        break
    done
    
    print_success "实例编号: $instance_num"
    echo ""
    
    # 输入后端 API 端口（这是实际使用的端口）
    local api_port
    local default_api_port=3001
    while true; do
        api_port=$(read_editable "请输入后端 API 端口（回车使用默认 $default_api_port）: ")
        
        if [ -z "$api_port" ]; then
            api_port=$default_api_port
            print_info "使用默认端口: $api_port"
        fi
        
        if ! validate_port "$api_port"; then
            print_error "端口号无效，请输入 1-65535 之间的数字"
            continue
        fi
        
        if ! check_port "$api_port"; then
            print_error "端口 $api_port 已被占用，请选择其他端口"
            continue
        fi
        
        break
    done
    
    # 输入 HTTP-META 端口
    local http_port
    local default_http_port=9876
    while true; do
        http_port=$(read_editable "请输入 HTTP-META 端口（回车使用默认 $default_http_port）: ")
        
        if [ -z "$http_port" ]; then
            http_port=$default_http_port
            print_info "使用默认端口: $http_port"
        fi
        
        if ! validate_port "$http_port"; then
            print_error "端口号无效，请输入 1-65535 之间的数字"
            continue
        fi
        
        if ! check_port "$http_port"; then
            print_error "端口 $http_port 已被占用，请选择其他端口"
            continue
        fi
        
        if [ "$http_port" == "$api_port" ]; then
            print_error "HTTP-META 端口不能与后端 API 端口相同"
            continue
        fi
        
        break
    done
    
    # 输入访问路径
    local access_path
    while true; do
        local random_path=$(generate_random_path)
        echo ""
        print_info "访问路径会自动以 / 开头，你只需输入路径内容即可"
        print_info "建议使用随机生成的安全路径"
        echo ""
        
        # 显示随机路径作为参考
        echo "随机生成的安全路径: $random_path"
        access_path=$(read_editable "请输入访问路径（回车使用上面的随机路径）: ")
        
        # 如果用户不输入，使用随机路径
        if [ -z "$access_path" ]; then
            access_path="$random_path"
            print_success "使用随机路径: /$access_path"
        else
            # 移除可能的开头斜杠
            access_path="${access_path#/}"
            
            if ! validate_path "$access_path"; then
                print_error "路径格式无效！要求："
                echo "  - 至少 19 个字符"
                echo "  - 只能包含字母、数字和斜杠"
                echo "  - 会自动添加开头的 /"
                continue
            fi
        fi
        
        break
    done
    
    # 保存不带 / 的路径用于显示
    local display_path="$access_path"
    # 添加开头的斜杠用于配置
    access_path="/$access_path"
    
    # 输入数据存储目录
    local data_dir
    local default_data_dir="/root/data-sub-store-$instance_num"
    
    echo ""
    print_info "数据存储目录（直接回车使用默认: $default_data_dir）"
    data_dir=$(read_editable "请输入数据存储目录: ")
    
    if [ -z "$data_dir" ]; then
        data_dir="$default_data_dir"
        print_info "使用默认目录: $data_dir"
    fi
    
    # 检查目录是否已存在
    if [ -d "$data_dir" ]; then
        echo ""
        print_warning "目录 $data_dir 已存在"
        local use_existing
        use_existing=$(read_editable "是否使用现有目录？(y/n): ")
        if [[ ! "$use_existing" =~ ^[Yy]$ ]]; then
            print_warning "请重新运行脚本并选择其他目录"
            return
        fi
    fi
    
    # 确认信息
    echo ""
    echo "=================================="
    echo "          配置确认"
    echo "=================================="
    echo "实例编号: $instance_num"
    echo "容器名称: sub-store-$instance_num"
    echo "后端 API 端口: $api_port （实际访问端口）"
    echo "HTTP-META 端口: $http_port"
    echo "安全路径: $display_path"
    echo "数据目录: $data_dir"
    echo "=================================="
    echo ""
    
    local confirm
    confirm=$(read_editable "确认以上配置并开始安装？(y/n): ")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "安装已取消"
        return
    fi
    
    # 创建配置目录
    mkdir -p /root/sub-store-configs
    
    # 创建数据目录
    print_info "创建数据目录..."
    mkdir -p "$data_dir"
    
    # 生成配置文件
    local config_file="/root/sub-store-configs/store-$instance_num.yaml"
    print_info "生成配置文件: $config_file"
    
    cat > "$config_file" <<EOF
services:
  sub-store-$instance_num:
    image: xream/sub-store:http-meta
    container_name: sub-store-$instance_num
    restart: always
    network_mode: host
    environment:
      SUB_STORE_BACKEND_API_HOST: 127.0.0.1
      SUB_STORE_BACKEND_API_PORT: $api_port
      SUB_STORE_BACKEND_MERGE: true
      SUB_STORE_FRONTEND_BACKEND_PATH: $access_path
      PORT: $http_port
      HOST: 127.0.0.1
    volumes:
      - $data_dir:/opt/app/data
EOF
    
    # 启动容器
    print_info "启动 Sub-Store 实例..."
    if docker compose -f "$config_file" up -d; then
        echo ""
        print_success "=========================================="
        print_success "  Sub-Store 实例安装成功！"
        print_success "=========================================="
        echo ""
        print_info "实例信息："
        echo "  - 实例编号: $instance_num"
        echo "  - 容器名称: sub-store-$instance_num"
        echo "  - 实际访问地址: http://127.0.0.1:$api_port"
        echo "  - 安全路径: $display_path"
        echo "  - HTTP-META 端口: $http_port"
        echo "  - 数据目录: $data_dir"
        echo "  - 配置文件: $config_file"
        echo ""
        print_warning "请使用 nginx 反向代理域名指向，直接访问是不可被访问的。"
        echo ""
        print_info "常用命令："
        echo "  - 查看日志: docker logs sub-store-$instance_num"
        echo "  - 停止服务: docker compose -f $config_file down"
        echo "  - 重启服务: docker compose -f $config_file restart"
        echo ""
    else
        print_error "启动失败，请检查配置和日志"
        return 1
    fi
}

# 更新实例
update_instance() {
    clear
    echo "=================================="
    echo "    Sub-Store 实例更新"
    echo "=================================="
    echo ""
    
    local instances=($(get_deployed_instances))
    
    if [ ${#instances[@]} -eq 0 ]; then
        print_warning "没有已部署的实例"
        return
    fi
    
    print_info "已部署的实例："
    for i in "${!instances[@]}"; do
        local instance_name="${instances[$i]}"
        local instance_num=$(echo "$instance_name" | sed 's/store-//')
        local container_name="sub-store-$instance_num"
        
        # 检查容器状态
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            echo -e "  $((i+1)). ${instance_name} ${GREEN}[运行中]${NC}"
        else
            echo -e "  $((i+1)). ${instance_name} ${RED}[已停止]${NC}"
        fi
    done
    echo "  $((${#instances[@]}+1)). 更新所有实例"
    echo ""
    
    local choice
    choice=$(read_editable "请选择要更新的实例编号（输入 0 取消）: ")
    
    if [ "$choice" == "0" ]; then
        print_warning "已取消更新"
        return
    fi
    
    # 更新所有实例
    if [ "$choice" == "$((${#instances[@]}+1))" ]; then
        echo ""
        print_info "准备更新所有实例..."
        local confirm
        confirm=$(read_editable "确认更新所有 ${#instances[@]} 个实例？(y/n): ")
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_warning "已取消更新"
            return
        fi
        
        print_info "拉取最新镜像..."
        docker pull xream/sub-store:http-meta
        
        for instance in "${instances[@]}"; do
            local config_file="/root/sub-store-configs/${instance}.yaml"
            local instance_num=$(echo "$instance" | sed 's/store-//')
            
            echo ""
            print_info "更新实例: $instance"
            docker compose -f "$config_file" down
            docker compose -f "$config_file" up -d
            print_success "实例 $instance 更新完成"
        done
        
        echo ""
        print_success "所有实例更新完成！"
        return
    fi
    
    # 更新单个实例
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#instances[@]} ]; then
        print_error "无效的选择"
        return
    fi
    
    local instance_name="${instances[$((choice-1))]}"
    local config_file="/root/sub-store-configs/${instance_name}.yaml"
    local instance_num=$(echo "$instance_name" | sed 's/store-//')
    
    echo ""
    print_info "准备更新实例: $instance_name"
    local confirm
    confirm=$(read_editable "确认更新？(y/n): ")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "已取消更新"
        return
    fi
    
    print_info "拉取最新镜像..."
    docker pull xream/sub-store:http-meta
    
    print_info "停止容器..."
    docker compose -f "$config_file" down
    
    print_info "启动更新后的容器..."
    docker compose -f "$config_file" up -d
    
    print_success "实例 $instance_name 更新完成！"
}

# 卸载实例
uninstall_instance() {
    clear
    echo "=================================="
    echo "    Sub-Store 实例卸载"
    echo "=================================="
    echo ""
    
    local instances=($(get_deployed_instances))
    
    if [ ${#instances[@]} -eq 0 ]; then
        print_warning "没有已部署的实例"
        return
    fi
    
    print_info "已部署的实例："
    for i in "${!instances[@]}"; do
        local instance_name="${instances[$i]}"
        local instance_num=$(echo "$instance_name" | sed 's/store-//')
        local container_name="sub-store-$instance_num"
        
        # 检查容器状态
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            echo -e "  $((i+1)). ${instance_name} ${GREEN}[运行中]${NC}"
        else
            echo -e "  $((i+1)). ${instance_name} ${RED}[已停止]${NC}"
        fi
    done
    echo ""
    
    local choice
    choice=$(read_editable "请选择要卸载的实例编号（输入 0 取消）: ")
    
    if [ "$choice" == "0" ]; then
        print_warning "已取消卸载"
        return
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#instances[@]} ]; then
        print_error "无效的选择"
        return
    fi
    
    local instance_name="${instances[$((choice-1))]}"
    local config_file="/root/sub-store-configs/${instance_name}.yaml"
    local instance_num=$(echo "$instance_name" | sed 's/store-//')
    
    echo ""
    print_warning "将要卸载实例: $instance_name"
    
    local delete_data
    delete_data=$(read_editable "是否同时删除数据目录？(y/n): ")
    echo ""
    
    local confirm
    confirm=$(read_editable "确认卸载？(y/n): ")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "已取消卸载"
        return
    fi
    
    print_info "停止并删除容器..."
    docker compose -f "$config_file" down
    
    if [[ "$delete_data" =~ ^[Yy]$ ]]; then
        # 从配置文件中提取数据目录
        local data_dir=$(grep -A 1 "volumes:" "$config_file" | tail -n 1 | awk -F':' '{print $1}' | xargs)
        if [ -n "$data_dir" ] && [ -d "$data_dir" ]; then
            print_info "删除数据目录: $data_dir"
            rm -rf "$data_dir"
        fi
    fi
    
    print_info "删除配置文件..."
    rm -f "$config_file"
    
    print_success "实例 $instance_name 已成功卸载"
}

# 列出所有实例
list_instances() {
    clear
    echo "=================================="
    echo "    已部署的 Sub-Store 实例"
    echo "=================================="
    echo ""
    
    local instances=($(get_deployed_instances))
    
    if [ ${#instances[@]} -eq 0 ]; then
        print_warning "没有已部署的实例"
        return
    fi
    
    for instance in "${instances[@]}"; do
        local config_file="/root/sub-store-configs/${instance}.yaml"
        local instance_num=$(echo "$instance" | sed 's/store-//')
        local container_name="sub-store-$instance_num"
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "实例编号: $instance_num"
        
        # 检查容器状态
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            print_success "  状态: 运行中"
        else
            print_error "  状态: 已停止"
        fi
        
        # 提取配置信息
        if [ -f "$config_file" ]; then
            local http_port=$(grep "PORT:" "$config_file" | awk '{print $2}')
            local api_port=$(grep "SUB_STORE_BACKEND_API_PORT:" "$config_file" | awk '{print $2}')
            local access_path=$(grep "SUB_STORE_FRONTEND_BACKEND_PATH:" "$config_file" | awk '{print $2}')
            # 移除开头的斜杠用于显示
            local display_path="${access_path#/}"
            local data_dir=$(grep -A 1 "volumes:" "$config_file" | tail -n 1 | awk -F':' '{print $1}' | xargs)
            
            echo "  容器名称: $container_name"
            echo "  实际访问地址: http://127.0.0.1:$api_port"
            echo "  安全路径: $display_path"
            echo "  HTTP-META 端口: $http_port"
            echo "  数据目录: $data_dir"
            echo "  配置文件: $config_file"
        fi
        
        echo ""
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo "=================================="
        echo "   Sub-Store 一键部署脚本"
        echo "=================================="
        echo ""
        echo "1. 安装新实例"
        echo "2. 更新实例"
        echo "3. 卸载实例"
        echo "4. 查看已部署实例"
        echo "5. 退出"
        echo ""
        
        local choice
        choice=$(read_editable "请选择操作 [1-5]: ")
        
        case $choice in
            1)
                install_instance
                read -p "按回车键继续..."
                ;;
            2)
                update_instance
                read -p "按回车键继续..."
                ;;
            3)
                uninstall_instance
                read -p "按回车键继续..."
                ;;
            4)
                list_instances
                read -p "按回车键继续..."
                ;;
            5)
                print_info "退出脚本"
                exit 0
                ;;
            *)
                print_error "无效的选择，请输入 1-5"
                sleep 2
                ;;
        esac
    done
}

# 脚本入口
clear
echo "=================================="
echo "   Sub-Store 一键部署脚本"
echo "=================================="
echo ""

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then 
    print_error "请使用 root 用户运行此脚本"
    exit 1
fi

# 检查 Docker
print_info "检查 Docker 环境..."
check_docker
print_success "Docker 环境检查通过"
echo ""

sleep 1

# 进入主菜单
main_menu
