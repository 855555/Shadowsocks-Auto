#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 配置文件路径
SS_CONFIG_PATH="/etc/shadowsocks/config.json"
STLS_CONFIG_PATH="/etc/systemd/system/shadow-tls.service"

# 获取公网 IP 地址
get_public_ip() {
    public_ip=$(curl -s -m 10 https://api.ipify.org || \
              curl -s -m 10 https://api.ip.sb/ip || \
              curl -s -m 10 https://icanhazip.com)
  
    if [[ -z "$public_ip" ]]; then
        echo "无法获取公网 IP 地址，将使用内网 IP 地址"
        public_ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$public_ip"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：${PLAIN}必须使用 root 用户运行此脚本！"
        exit 1
    fi
}

# 检查并安装工具
check_tool() {
    local tools=("xz" "wget" "curl" "jq")
    local PM

    # 确定包管理器
    if command -v apt &> /dev/null; then
        PM="apt"
    elif command -v yum &> /dev/null; then
        PM="yum"
    elif command -v dnf &> /dev/null; then
        PM="dnf"
    else
        echo -e "${RED}无法确定包管理器，请手动安装以下工具：${tools[*]}${PLAIN}"
        exit 1
    fi

    # 收集需要安装的包
    local pkgs=()
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            case "$PM" in
                apt)
                    case "$tool" in
                        xz) pkgs+=("xz-utils") ;;
                        *) pkgs+=("$tool") ;;
                    esac
                    ;;
                yum|dnf)
                    pkgs+=("$tool")
                    ;;
            esac
            echo -e "${YELLOW}检测到 $tool 未安装，将进行安装${PLAIN}"
        else
            echo -e "${GREEN}$tool 已安装${PLAIN}"
        fi
    done

    # 安装缺失的包
    if [ ${#pkgs[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装缺失工具：${pkgs[*]}...${PLAIN}"
        if [ "$PM" = "apt" ]; then
            apt update && apt install -y "${pkgs[@]}" || {
                echo -e "${RED}安装失败，请检查网络或手动安装${PLAIN}"
                exit 1
            }
        else
            $PM install -y "${pkgs[@]}" || {
                echo -e "${RED}安装失败，请检查网络或手动安装${PLAIN}"
                exit 1
            }
        fi
        echo -e "${GREEN}所有工具安装成功${PLAIN}"
    fi
}

# ===== Shadowsocks 功能 =====

# 安装Shadowsocks服务
install_shadowsocks() {
    echo -e "${BLUE}开始安装 Shadowsocks 服务...${PLAIN}"
    
    # 检查和安装xz工具
    check_tool

    # 获取系统架构 (x86_64, i686, aarch64, armv7, arm)
    ARCH=$(uname -m)

    # 根据系统架构选择对应的下载后缀
    case "$ARCH" in
        x86_64)
            ARCH_SUFFIX="x86_64-unknown-linux-gnu"
            ;;
        i686)
            ARCH_SUFFIX="i686-unknown-linux-musl"
            ;;
        aarch64)
            ARCH_SUFFIX="aarch64-unknown-linux-gnu"
            ;;
        armv7l)
            ARCH_SUFFIX="armv7-unknown-linux-gnueabihf"
            ;;
        armv6l)
            ARCH_SUFFIX="arm-unknown-linux-gnueabihf"
            ;;
        *)
            echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
            exit 1
            ;;
    esac

    # 获取 GitHub 最新 release 的信息
    echo -e "${YELLOW}正在获取 Shadowsocks 最新版本信息...${PLAIN}"
    local api_response
    api_response=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest)
    if [ $? -ne 0 ]; then
        echo -e "${RED}获取 GitHub 最新 release 信息失败${PLAIN}"
        exit 1
    fi
    
    LATEST_TAG=$(echo "$api_response" | grep '"tag_name"' | cut -d '"' -f 4)

    if [ -z "$LATEST_TAG" ]; then
        echo -e "${RED}无法获取最新版本信息${PLAIN}"
        exit 1
    fi

    LATEST_RELEASE_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/$LATEST_TAG/shadowsocks-$LATEST_TAG.$ARCH_SUFFIX.tar.xz"

    # 检查当前安装的版本
    local CURRENT_VERSION
    if command -v ssserver &> /dev/null; then
        CURRENT_VERSION=$(ssserver --version | awk '{print $2}')
        CURRENT_VERSION="v$CURRENT_VERSION"
    else
        CURRENT_VERSION="未安装"
    fi

    # 判断是否需要更新
    if [[ "$CURRENT_VERSION" != "$LATEST_TAG" ]]; then
        if [[ "$CURRENT_VERSION" == "未安装" ]]; then
            echo -e "${YELLOW}Shadowsocks 尚未安装，将安装最新版本: $LATEST_TAG${PLAIN}"
        else
            echo -e "${YELLOW}发现新版本: $LATEST_TAG，当前版本: $CURRENT_VERSION${PLAIN}"
        fi
        echo -e "${BLUE}正在下载最新版本...${PLAIN}"
        wget -q "$LATEST_RELEASE_URL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载失败，请检查网络连接或稍后重试${PLAIN}"
            exit 1
        fi
        echo -e "${BLUE}下载完成，正在安装...${PLAIN}"
        tar -Jxf shadowsocks-*.tar.xz -C /usr/local/bin/ 2>/dev/null
        rm shadowsocks-*.tar.xz
        echo -e "${GREEN}安装/更新完成${PLAIN}"
    else
        echo -e "${GREEN}当前已是最新版本: $CURRENT_VERSION，无需更新${PLAIN}"
    fi

    # 创建配置文件目录
    mkdir -p /etc/shadowsocks

    # 询问用户是否输入自定义端口
    read -p "请输入自定义端口(1024-65535)，或按回车随机生成: " ss_port
    # 检查自定义端口是否合法
    if [[ -z "$ss_port" || ! "$ss_port" =~ ^[0-9]+$ || "$ss_port" -lt 1025 || "$ss_port" -gt 65535 ]]; then
        echo -e "${YELLOW}无效的端口，使用随机生成的端口${PLAIN}"
        ss_port=$(shuf -i 1024-65535 -n 1)
    else
        echo -e "${GREEN}使用自定义端口: $ss_port${PLAIN}"
    fi

    # 询问用户选择加密方法
    echo -e "${BLUE}请选择加密方法（回车则默认为2022-blake3-aes-256-gcm）:${PLAIN}"
    echo "1) 2022-blake3-aes-128-gcm"
    echo "2) 2022-blake3-aes-256-gcm 【推荐】"
    echo "3) 2022-blake3-chacha20-poly1305"
    echo "4) aes-256-gcm"
    echo "5) aes-128-gcm"
    echo "6) chacha20-ietf-poly1305"
    echo "7) none"
    echo "8) aes-128-cfb"
    echo "9) aes-192-cfb"
    echo "10) aes-256-cfb"
    echo "11) aes-128-ctr"
    echo "12) aes-192-ctr"
    echo "13) aes-256-ctr"
    echo "14) camellia-128-cfb"
    echo "15) camellia-192-cfb"
    echo "16) camellia-256-cfb"
    echo "17) rc4-md5"
    echo "18) chacha20-ietf"

    read -p "请输入选项数字 (默认为 2): " encryption_choice
    # 如果用户没有输入，默认选择 2022-blake3-aes-256-gcm
    encryption_choice=${encryption_choice:-2}

    # 根据用户选择设置加密方法和密码
    case $encryption_choice in
        1)
            method="2022-blake3-aes-128-gcm"
            ss_password=$(openssl rand -base64 16)
            ;;
        2)
            method="2022-blake3-aes-256-gcm"
            ss_password=$(openssl rand -base64 32)
            ;;
        3)
            method="2022-blake3-chacha20-poly1305"
            ss_password=$(openssl rand -base64 32)
            ;;
        *)
            case $encryption_choice in
                4) method="aes-256-gcm" ;;
                5) method="aes-128-gcm" ;;
                6) method="chacha20-ietf-poly1305" ;;
                7) method="none" ;;
                8) method="aes-128-cfb" ;;
                9) method="aes-192-cfb" ;;
                10) method="aes-256-cfb" ;;
                11) method="aes-128-ctr" ;;
                12) method="aes-192-ctr" ;;
                13) method="aes-256-ctr" ;;
                14) method="camellia-128-cfb" ;;
                15) method="camellia-192-cfb" ;;
                16) method="camellia-256-cfb" ;;
                17) method="rc4-md5" ;;
                18) method="chacha20-ietf" ;;
                *)
                    echo -e "${YELLOW}无效选项，使用默认方法: 2022-blake3-aes-256-gcm${PLAIN}"
                    method="2022-blake3-aes-256-gcm"
                    ss_password=$(openssl rand -base64 32)
                    ;;
            esac
            read -p "请输入自定义密码 (留空使用默认密码 'yuju.love'): " custom_password
            if [[ -z "$custom_password" ]]; then
                ss_password="yuju.love"
            else
                ss_password="$custom_password"
				
            fi
            ;;
    esac

    # 询问用户是否输入自定义节点名称
    read -p "请输入自定义节点名称 (回车则默认为 Shadowsocks-加密协议): " node_name
    # 如果用户没有输入，使用默认节点名称
    if [[ -z "$node_name" ]]; then
        node_name="Shadowsocks-${method}"
    fi

    # 生成 Shadowsocks 配置文件（无论是否存在，都会覆盖）
    echo -e "${BLUE}正在生成配置文件...${PLAIN}"
    cat <<EOF >/etc/shadowsocks/config.json
{
    "server": "0.0.0.0",
    "server_port": $ss_port,
    "password": "$ss_password",
    "method": "$method",
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF
    echo -e "${GREEN}配置文件已生成${PLAIN}"

    # 生成 systemd 服务文件（无论是否存在，都会覆盖）
    echo -e "${BLUE}正在生成服务文件...${PLAIN}"
    cat <<EOF >/etc/systemd/system/shadowsocks.service
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF
    echo -e "${GREEN}服务文件已生成${PLAIN}"

    # 重新加载 systemd 配置
    systemctl daemon-reload

    # 启动 Shadowsocks 服务
    echo -e "${BLUE}正在启动 Shadowsocks 服务...${PLAIN}"
    systemctl start shadowsocks
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks 服务已成功启动${PLAIN}"
    else
        echo -e "${RED}启动 Shadowsocks 服务失败${PLAIN}"
    fi

    # 启用 Shadowsocks 服务自启动
    echo -e "${BLUE}正在启用 Shadowsocks 服务自启动...${PLAIN}"
    systemctl enable shadowsocks &>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks 服务已设置为开机自启动${PLAIN}"
    else
        echo -e "${RED}设置 Shadowsocks 服务自启动失败${PLAIN}"
    fi

    # 检查 Shadowsocks 服务状态
    local systemctl_status
    systemctl_status=$(systemctl is-active shadowsocks)
    echo -e "${BLUE}Shadowsocks 的服务状态为：${GREEN}$systemctl_status${PLAIN}"
    # 获取ip
    get_public_ip
    # 构建并输出 ss:// 格式的链接
    base64_password=$(echo -n "$method:$ss_password" | base64 -w 0)
    echo -e "${GREEN}Shadowsocks 节点信息: ss://${base64_password}@${public_ip}:$ss_port#$node_name${PLAIN}"
    
    # 记录配置信息供以后使用
    cat <<EOF >/etc/shadowsocks/info.txt
端口: $ss_port
密码: $ss_password
加密方法: $method
节点名称: $node_name
链接: ss://${base64_password}@${public_ip}:$ss_port#$node_name
EOF
    
    echo -e "${GREEN}安装完成！配置信息已保存到 /etc/shadowsocks/info.txt${PLAIN}"
}

# 查看Shadowsocks服务状态
check_shadowsocks_status() {
    if ! command -v ssserver &> /dev/null; then
        echo -e "${RED}Shadowsocks 未安装${PLAIN}"
        return 1
    fi
    
    echo -e "${BLUE}Shadowsocks 版本: ${PLAIN}$(ssserver --version)"
    echo -e "${BLUE}服务状态: ${PLAIN}$(systemctl is-active shadowsocks)"
    
}
# 查看Shadowsocks配置文件
check_shadowsocks_config() {
    if [ -f "/etc/shadowsocks/info.txt" ]; then
        echo -e "${BLUE}配置信息: ${PLAIN}"
        cat /etc/shadowsocks/info.txt
    else
        echo -e "${BLUE}未检测到配置信息 ${PLAIN}"
	fi
}
# 修改Shadowsocks配置文件
modify_shadowsocks_config() {
    if ! command -v ssserver &> /dev/null; then
        echo -e "${RED}Shadowsocks 未安装，请先安装！${PLAIN}"
        return 1
    fi
    
    if [ ! -f "$SS_CONFIG_PATH" ]; then
        echo -e "${RED}配置文件不存在，请重新安装 Shadowsocks！${PLAIN}"
        return 1
    fi
    
    # 显示当前配置
    echo -e "${BLUE}当前配置: ${PLAIN}"
    local current_port=$(jq -r '.server_port' "$SS_CONFIG_PATH")
    local current_method=$(jq -r '.method' "$SS_CONFIG_PATH")
    local current_password=$(jq -r '.password' "$SS_CONFIG_PATH")
    
    echo -e "${GREEN}端口: $current_port${PLAIN}"
    echo -e "${GREEN}加密方法: $current_method${PLAIN}"
    echo -e "${GREEN}密码: $current_password${PLAIN}"
    
    # 询问是否修改端口
    read -p "是否修改端口？(y/n，默认n): " change_port
    local new_port=$current_port
    
    if [[ "$change_port" == "y" || "$change_port" == "Y" ]]; then
        read -p "请输入新端口(1024-65535): " new_port
        # 验证端口合法性
        if [[ -z "$new_port" || ! "$new_port" =~ ^[0-9]+$ || "$new_port" -lt 1024 || "$new_port" -gt 65535 ]]; then
            echo -e "${RED}无效的端口，使用原端口${PLAIN}"
            new_port=$current_port
        fi
    fi
    
    # 询问是否修改加密方法
    read -p "是否修改加密方法？(y/n，默认n): " change_method
    local new_method=$current_method
    
    if [[ "$change_method" == "y" || "$change_method" == "Y" ]]; then
        echo -e "${BLUE}请选择新的加密方法:${PLAIN}"
        echo "1) 2022-blake3-aes-128-gcm"
        echo "2) 2022-blake3-aes-256-gcm 【推荐】"
        echo "3) 2022-blake3-chacha20-poly1305"
        echo "4) aes-256-gcm"
        echo "5) aes-128-gcm"
        echo "6) chacha20-ietf-poly1305"
        echo "7) none"
        echo "8) aes-128-cfb"
        echo "9) aes-192-cfb"
        echo "10) aes-256-cfb"
        echo "11) aes-128-ctr"
        echo "12) aes-192-ctr"
        echo "13) aes-256-ctr"
        echo "14) camellia-128-cfb"
        echo "15) camellia-192-cfb"
        echo "16) camellia-256-cfb"
        echo "17) rc4-md5"
        echo "18) chacha20-ietf"
        
        read -p "请输入选项数字: " encryption_choice
        
        case $encryption_choice in
            1) new_method="2022-blake3-aes-128-gcm" ;;
            2) new_method="2022-blake3-aes-256-gcm" ;;
            3) new_method="2022-blake3-chacha20-poly1305" ;;
            4) new_method="aes-256-gcm" ;;
            5) new_method="aes-128-gcm" ;;
            6) new_method="chacha20-ietf-poly1305" ;;
            7) new_method="none" ;;
            8) new_method="aes-128-cfb" ;;
            9) new_method="aes-192-cfb" ;;
            10) new_method="aes-256-cfb" ;;
            11) new_method="aes-128-ctr" ;;
            12) new_method="aes-192-ctr" ;;
            13) new_method="aes-256-ctr" ;;
            14) new_method="camellia-128-cfb" ;;
            15) new_method="camellia-192-cfb" ;;
            16) new_method="camellia-256-cfb" ;;
            17) new_method="rc4-md5" ;;
            18) new_method="chacha20-ietf" ;;
            *)
                echo -e "${YELLOW}无效选项，使用原方法${PLAIN}"
                new_method=$current_method
                ;;
        esac
    fi
    
    # 询问是否修改密码
    read -p "是否修改密码？(y/n，默认n): " change_password
    local new_password=$current_password
    
    if [[ "$change_password" == "y" || "$change_password" == "Y" ]]; then
	    # 根据加密方法自动生成或设置密码
	    if [[ "$new_method" == "2022-blake3-aes-256-gcm" || "$new_method" == "2022-blake3-chacha20-poly1305" ]]; then
		    new_password=$(openssl rand -base64 32)
		    echo -e "${GREEN}已生成随机密码: $new_password${PLAIN}"
	    elif [[ "$new_method" == "2022-blake3-aes-128-gcm" ]]; then
		    new_password=$(openssl rand -base64 16)
		    echo -e "${GREEN}已生成随机密码: $new_password${PLAIN}"
	    else
		    read -p "请输入新密码 (留空为默认密码 yuju.love): " custom_password
		    if [[ -z "$custom_password" ]]; then
			    new_password="yuju.love"
			    echo -e "${GREEN}使用默认密码: $new_password${PLAIN}"
		    else
			    new_password="$custom_password"
		    fi
	    fi
    fi
    
    # 询问用户是否修改节点名称
    local current_node_name=""
    if [ -f "/etc/shadowsocks/info.txt" ]; then
        current_node_name=$(grep "节点名称:" "/etc/shadowsocks/info.txt" | cut -d ' ' -f 2-)
    else
        current_node_name="Shadowsocks-${current_method}"
    fi
    
    echo -e "${GREEN}当前节点名称: $current_node_name${PLAIN}"
    read -p "是否修改节点名称？(y/n，默认n): " change_node_name
    local new_node_name=$current_node_name
    
    if [[ "$change_node_name" == "y" || "$change_node_name" == "Y" ]]; then
        read -p "请输入新的节点名称: " custom_node_name
        if [[ -n "$custom_node_name" ]]; then
            new_node_name="$custom_node_name"
        fi
    fi
    
    # 更新配置文件
    echo -e "${BLUE}正在更新配置文件...${PLAIN}"
    cat <<EOF >$SS_CONFIG_PATH
{
    "server": "0.0.0.0",
    "server_port": $new_port,
    "password": "$new_password",
    "method": "$new_method",
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF
    # 获取ip
	get_public_ip
    # 更新保存的配置信息
    base64_password=$(echo -n "$new_method:$new_password" | base64 -w 0)
    
    cat <<EOF >/etc/shadowsocks/info.txt
端口: $new_port
密码: $new_password
加密方法: $new_method
节点名称: $new_node_name
链接: ss://${base64_password}@${public_ip}:$new_port#$new_node_name
EOF
    
    echo -e "${GREEN}配置已更新！${PLAIN}"
    
    # 重启服务
    echo -e "${BLUE}正在重启 Shadowsocks 服务...${PLAIN}"
    systemctl restart shadowsocks
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks 服务已成功重启！${PLAIN}"
        echo -e "${GREEN}新的节点链接: ss://${base64_password}@${public_ip}:$new_port#$new_node_name${PLAIN}"
    else
        echo -e "${RED}重启 Shadowsocks 服务失败！${PLAIN}"
    fi
}

# 启动Shadowsocks服务
start_shadowsocks() {
    if ! command -v ssserver &> /dev/null; then
        echo -e "${RED}Shadowsocks 未安装，请先安装！${PLAIN}"
        return 1
    fi
    
    echo -e "${BLUE}正在启动 Shadowsocks 服务...${PLAIN}"
    systemctl start shadowsocks
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks 服务已成功启动！${PLAIN}"
        return 0
    else
        echo -e "${RED}启动 Shadowsocks 服务失败！${PLAIN}"
        return 1
    fi
}

# 停止Shadowsocks服务
stop_shadowsocks() {
    if ! systemctl is-active shadowsocks &>/dev/null; then
        echo -e "${YELLOW}Shadowsocks 服务当前未运行${PLAIN}"
        return 0
    fi
    
    echo -e "${BLUE}正在停止 Shadowsocks 服务...${PLAIN}"
    systemctl stop shadowsocks
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks 服务已成功停止！${PLAIN}"
        return 0
    else
        echo -e "${RED}停止 Shadowsocks 服务失败！${PLAIN}"
        return 1
    fi
}

# 重启Shadowsocks服务
restart_shadowsocks() {
    if ! command -v ssserver &> /dev/null; then
        echo -e "${RED}Shadowsocks 未安装，请先安装！${PLAIN}"
        return 1
    fi
    
    echo -e "${BLUE}正在重启 Shadowsocks 服务...${PLAIN}"
    systemctl restart shadowsocks
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks 服务已成功重启！${PLAIN}"
        return 0
    else
        echo -e "${RED}重启 Shadowsocks 服务失败！${PLAIN}"
        return 1
    fi
}

# 卸载Shadowsocks服务
uninstall_shadowsocks() {
    echo -e "${YELLOW}警告: 此操作将完全卸载 Shadowsocks 服务及其配置文件！${PLAIN}"
    read -p "是否继续？(y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${GREEN}已取消卸载${PLAIN}"
        return 0
    fi
    
    echo -e "${BLUE}正在卸载 Shadowsocks 服务...${PLAIN}"
    
    # 停止 Shadowsocks 服务
    if systemctl is-active shadowsocks &>/dev/null; then
        echo -e "${BLUE}停止 Shadowsocks 服务...${PLAIN}"
        systemctl stop shadowsocks
    fi
    
    # 禁用 Shadowsocks 服务自启动
    if systemctl is-enabled shadowsocks &>/dev/null; then
        echo -e "${BLUE}禁用 Shadowsocks 服务自启动...${PLAIN}"
        systemctl disable shadowsocks &>/dev/null
    fi
    
    # 删除 Shadowsocks 服务文件并重新加载 systemd 配置
    if [ -f "/etc/systemd/system/shadowsocks.service" ]; then
        echo -e "${BLUE}删除 Shadowsocks 服务文件...${PLAIN}"
        rm /etc/systemd/system/shadowsocks.service
        systemctl daemon-reload
    fi
    
    # 删除 Shadowsocks 相关配置文件及目录和可执行文件
    echo -e "${BLUE}删除 Shadowsocks 相关文件...${PLAIN}"
    if [ -d "/etc/shadowsocks" ]; then
        rm -rf /etc/shadowsocks
    fi
    
    if command -v ssserver &> /dev/null; then
        rm /usr/local/bin/ssserver
    fi
    
    if command -v sslocal &> /dev/null; then
        rm /usr/local/bin/sslocal
    fi
    
    if command -v ssurl &> /dev/null; then
        rm /usr/local/bin/ssurl
    fi
    
    if command -v ssmanager &> /dev/null; then
        rm /usr/local/bin/ssmanager
    fi
    
    echo -e "${GREEN}Shadowsocks 服务已成功卸载！${PLAIN}"
}

# ===== ShadowTLS 功能 =====

# 安装ShadowTLS服务
install_shadowtls() {
    echo -e "${BLUE}开始安装 ShadowTLS 服务...${PLAIN}"

    # 检查是否已安装
    if [ -f "/usr/bin/shadow-tls-x86_64-unknown-linux-musl" ] || systemctl is-active shadow-tls &>/dev/null; then
        echo -e "${YELLOW}ShadowTLS 已安装，如需重新安装请先卸载${PLAIN}"
        return 1
    fi

    # 获取系统架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)   ARCH_SUFFIX="x86_64-unknown-linux-musl" ;;
        aarch64)  ARCH_SUFFIX="aarch64-unknown-linux-musl" ;;
        armv7l)   ARCH_SUFFIX="armv7-unknown-linux-musleabihf" ;;
        *)        echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return 1 ;;
    esac

    # 获取最新版本
    LATEST_VERSION=$(wget -qO- https://api.github.com/repos/ihciah/shadow-tls/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}获取 ShadowTLS 版本失败${PLAIN}"
        return 1
    fi

    # 下载二进制文件
    echo -e "${YELLOW}正在下载 ShadowTLS ${LATEST_VERSION}...${PLAIN}"
    wget -q "https://github.com/ihciah/shadow-tls/releases/download/${LATEST_VERSION}/shadow-tls-${ARCH_SUFFIX}" -O /usr/bin/shadow-tls
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络${PLAIN}"
        return 1
    fi
    chmod +x /usr/bin/shadow-tls

    # 获取 Shadowsocks 端口（如果已安装）
    local ss_port="9000"
    if [ -f "$SS_CONFIG_PATH" ]; then
        ss_port=$(grep '"server_port":' "$SS_CONFIG_PATH" | awk '{print $2}' | tr -d ',')
        echo -e "${GREEN}检测到 Shadowsocks 端口: $ss_port${PLAIN}"
    else
        read -p "请输入Shadowsocks服务端口（默认9000）: " ss_port
        ss_port=${ss_port:-9000}
    fi

    # 生成随机密码
    local stls_password=$(openssl rand -base64 16 | tr -d '=+/')

    # 交互式配置
    read -p "输入ShadowTLS监听端口（默认9527）: " listen_port
    local listen_port=${listen_port:-9527}

    read -p "输入TLS混淆域名（默认www.bing.com）: " tls_domain
    local tls_domain=${tls_domain:-www.bing.com}

    # 创建服务文件
    cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/shadow-tls --v3 server --listen 0.0.0.0:${listen_port} --password ${stls_password} --server 127.0.0.1:${ss_port} --tls ${tls_domain}:443
Environment=MONOIO_FORCE_LEGACY_DRIVER=1

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable shadow-tls --now

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}ShadowTLS 启动成功！${PLAIN}"

        # 保存配置信息
        mkdir -p /etc/shadowtls
        cat <<EOF >/etc/shadowtls/info.txt
监听端口: $listen_port
密码: $stls_password
目标服务: 127.0.0.1:$ss_port
TLS域名: $tls_domain
EOF
        echo -e "${GREEN}配置信息已保存至 /etc/shadowtls/info.txt${PLAIN}"

    # 构建并输出 ss:// 格式的链接
    local current_port=$(jq -r '.server_port' "$SS_CONFIG_PATH")
    local current_method=$(jq -r '.method' "$SS_CONFIG_PATH")
    local current_password=$(jq -r '.password' "$SS_CONFIG_PATH")
    local current_node_name=$(grep "节点名称:" "/etc/shadowsocks/info.txt" | cut -d ' ' -f 2-)
	local public_ip=$(get_public_ip)
    base64_password=$(echo -n "$current_method:$current_password" | base64 -w 0)
	shadow_tls_config="{\"version\":\"3\",\"password\":\"${stls_password}\",\"host\":\"${tls_domain}\",\"port\":\"${listen_port}\",\"address\":\"${public_ip}\"}"
	shadow_tls_base64=$(echo -n "${shadow_tls_config}" | base64 | tr -d '\n')
	final_url="ss://${base64_password}@${public_ip}:${current_port}?shadow-tls=${shadow_tls_base64}#$current_node_name${PLAIN}"
    echo -e "${GREEN}Shadowsocks 节点信息: ${final_url}"
	# 将链接写入文件
    echo "$final_url" > /etc/shadowsocks/latest_link.txt
    echo -e "\n${YELLOW}链接已保存至：/etc/shadowsocks/latest_link.txt${PLAIN}"
    else
        echo -e "${RED}ShadowTLS 启动失败！${PLAIN}"
        return 1
    fi
}

# 查看ShadowTLS服务状态
check_shadowtls_status() {
    if [ ! -f "/usr/bin/shadow-tls" ]; then
        echo -e "${RED}ShadowTLS 未安装${PLAIN}"
        return 1
    fi

    echo -e "${BLUE}ShadowTLS 版本: ${PLAIN}$(/usr/bin/shadow-tls --version | awk '{print $2}')"
    echo -e "${BLUE}服务状态: ${PLAIN}$(systemctl is-active shadow-tls)"
}

# 查看ShadowTLS配置文件
check_shadowtls_config() {
    if [ -f "/etc/shadowtls/info.txt" ]; then
        echo -e "${BLUE}配置信息: ${PLAIN}"
        cat /etc/shadowtls/info.txt
    else
        echo -e "${BLUE}未检测到配置信息 ${PLAIN}"
	fi
}

# 修改ShadowTLS配置
modify_shadowtls_config() {
    if [ ! -f "/usr/bin/shadow-tls" ]; then
        echo -e "${RED}ShadowTLS 未安装${PLAIN}"
        return 1
    fi
    
    # 获取当前配置
    echo -e "${YELLOW}当前配置信息："
    cat /etc/shadowtls/info.txt
    echo -e "${PLAIN}"
    
    # 从服务文件中正确提取当前值
    service_content=$(cat /etc/systemd/system/shadow-tls.service)
    current_listen_port=$(echo "$service_content" | grep -oP 'listen 0.0.0.0:\K[0-9]+')
    current_stls_password=$(echo "$service_content" | grep -oP 'password \K[^ ]+')
    current_ss_port=$(echo "$service_content" | grep -oP 'server 127.0.0.1:\K[0-9]+')
    current_tls_domain=$(echo "$service_content" | grep -oP 'tls \K[^:]+(?=:443)')
    
    # 如果无法从服务文件读取，尝试从info.txt读取
    if [ -z "$current_listen_port" ] || [ -z "$current_stls_password" ] || [ -z "$current_ss_port" ] || [ -z "$current_tls_domain" ]; then
        if [ -f "/etc/shadowtls/info.txt" ]; then
            info_content=$(cat /etc/shadowtls/info.txt)
            [ -z "$current_listen_port" ] && current_listen_port=$(echo "$info_content" | grep -oP '监听端口: \K.+')
            [ -z "$current_stls_password" ] && current_stls_password=$(echo "$info_content" | grep -oP '密码: \K.+')
            [ -z "$current_ss_port" ] && current_ss_port=$(echo "$info_content" | grep -oP '目标服务端口: \K.+')
            [ -z "$current_tls_domain" ] && current_tls_domain=$(echo "$info_content" | grep -oP 'TLS域名: \K.+')
        fi
    fi
    
    # 依次询问是否修改各项
    echo -e "是否修改监听端口? 当前值: ${current_listen_port} (留空则不修改)"
    read -p "新监听端口: " new_listen_port
    listen_port=${new_listen_port:-$current_listen_port}
    
    echo -e "是否修改密码? 当前值: ${current_stls_password} (留空则不修改，输入 'random' 则随机生成)"
    read -p "新密码: " new_stls_password
    if [ "$new_stls_password" = "random" ]; then
        stls_password=$(openssl rand -base64 16 | tr -d '=+/')
    elif [ -n "$new_stls_password" ]; then
        stls_password=$new_stls_password
    else
        stls_password=$current_stls_password
    fi
    
    echo -e "是否修改目标服务端口? 当前值: ${current_ss_port} (留空则不修改)"
    read -p "新目标服务端口: " new_ss_port
    ss_port=${new_ss_port:-$current_ss_port}
    
    echo -e "是否修改TLS域名? 当前值: ${current_tls_domain} (留空则不修改)"
    read -p "新TLS域名: " new_tls_domain
    tls_domain=${new_tls_domain:-$current_tls_domain}
    
    # 更新服务文件
    cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/shadow-tls --v3 server --listen 0.0.0.0:${listen_port} --password ${stls_password} --server 127.0.0.1:${ss_port} --tls ${tls_domain}:443
Environment=MONOIO_FORCE_LEGACY_DRIVER=1

[Install]
WantedBy=multi-user.target
EOF

    # 更新配置信息文件
    cat > /etc/shadowtls/info.txt <<EOF
监听端口: ${listen_port}
密码: ${stls_password}
目标服务端口: ${ss_port}
TLS域名: ${tls_domain}
EOF

    systemctl daemon-reload
    systemctl restart shadow-tls
    
    echo -e "${GREEN}ShadowTLS 配置已更新并重启服务${PLAIN}"
}

# ShadowTLS服务控制
shadowtls_control() {
    local action=$1
    case $action in
        start)
            systemctl start shadow-tls
            [ $? -eq 0 ] && echo -e "${GREEN}ShadowTLS 已启动${PLAIN}" || echo -e "${RED}启动失败${PLAIN}" ;;
        stop)
            systemctl stop shadow-tls
            [ $? -eq 0 ] && echo -e "${GREEN}ShadowTLS 已停止${PLAIN}" || echo -e "${RED}停止失败${PLAIN}" ;;
        restart)
            systemctl restart shadow-tls
            [ $? -eq 0 ] && echo -e "${GREEN}ShadowTLS 已重启${PLAIN}" || echo -e "${RED}重启失败${PLAIN}" ;;
    esac
}

# 卸载ShadowTLS
uninstall_shadowtls() {
    echo -e "${YELLOW}此操作将完全卸载 ShadowTLS${PLAIN}"
    read -p "确认卸载？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    systemctl stop shadow-tls
    systemctl disable shadow-tls
    rm -f /usr/bin/shadow-tls
    rm -f /etc/systemd/system/shadow-tls.service
    systemctl daemon-reload
    rm -rf /etc/shadowtls
    echo -e "${GREEN}ShadowTLS 已卸载${PLAIN}"
}

# ===== 主菜单功能 =====

# 一键安装
# 输出当前节点链接
ss_links() {
    # 检查 Shadowsocks 是否安装
    if [ ! -f "$SS_CONFIG_PATH" ]; then
        echo -e "${RED}Shadowsocks 未安装，请先安装！${PLAIN}"
        return 1
    fi
    
    # 读取 Shadowsocks 配置
    ss_port=$(jq -r '.server_port' "$SS_CONFIG_PATH")
    ss_password=$(jq -r '.password' "$SS_CONFIG_PATH")
    method=$(jq -r '.method' "$SS_CONFIG_PATH")
    public_ip=$(get_public_ip)
    # 获取节点名称
    node_name=$(grep "节点名称:" "/etc/shadowsocks/info.txt" | cut -d ' ' -f 2-)
    
    # 生成基础 ss:// 信息
    base64_password=$(echo -n "${method}:${ss_password}" | base64 -w 0)
    
    # 检查 ShadowTLS 是否安装并正在运行
    if systemctl is-active --quiet shadow-tls && [ -f "$STLS_CONFIG_PATH" ]; then
        # 读取 ShadowTLS 配置
        stls_port=$(grep "监听端口:" /etc/shadowtls/info.txt | awk '{print $2}')
        stls_password=$(grep "密码:" /etc/shadowtls/info.txt | awk '{print $2}')
        tls_domain=$(grep "TLS域名:" /etc/shadowtls/info.txt | awk '{print $2}')
        
        if [ -n "$stls_port" ] && [ -n "$stls_password" ] && [ -n "$tls_domain" ]; then
            # 构建 ShadowTLS 参数
            shadow_tls_config="{\"version\":\"3\",\"password\":\"${stls_password}\",\"host\":\"${tls_domain}\"}"
            shadow_tls_base64=$(echo -n "$shadow_tls_config" | base64 -w 0 | tr -d '\n')
            
            # 组合最终链接 (注意: ShadowTLS链接使用stls_port而不是ss_port)
            final_url="ss://${base64_password}@${public_ip}:${ss_port}?shadow-tls=${shadow_tls_base64}#${node_name}"
            
            echo -e "${GREEN}当前节点链接 (ShadowTLS)：${PLAIN}"
            echo -e "${BLUE}${final_url}${PLAIN}"
        else
            echo -e "${YELLOW}ShadowTLS配置信息不完整，使用普通链接。${PLAIN}"
            # 普通 Shadowsocks 链接
            final_url="ss://${base64_password}@${public_ip}:${ss_port}#${node_name}"
            echo -e "${GREEN}当前节点链接 (普通)：${PLAIN}"
            echo -e "${BLUE}${final_url}${PLAIN}"
        fi
    else
        # 普通 Shadowsocks 链接
        final_url="ss://${base64_password}@${public_ip}:${ss_port}#${node_name}"
        echo -e "${GREEN}当前节点链接 (普通)：${PLAIN}"
        echo -e "${BLUE}${final_url}${PLAIN}"
    fi
    
    # 添加暂停
    read -n 1 -s -r -p "按任意键返回主菜单..."
}
# 完全卸载
install_all() {
    check_root
	install_shadowsocks
	install_shadowtls
	# 添加暂停
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

uninstall_all() {
    check_root
    uninstall_shadowsocks
    uninstall_shadowtls
    echo -e "${YELLOW}正在删除本脚本...${PLAIN}"
    rm -f "$0"
    echo -e "${GREEN}所有组件及脚本已卸载！${PLAIN}"
    exit 0
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}================================${PLAIN}"
        echo -e "          Shadowsocks/ShadowTLS 管理脚本"
        echo -e "${BLUE}================================${PLAIN}"
        echo -e "  1) Shadowsocks 服务管理"
        echo -e "  2) ShadowTLS 服务管理"
        echo -e "  3) 一键安装 Shadowsocks+ShadowTLS"
        echo -e "  4) 输出当前节点链接"
        echo -e "  9) 完全卸载（包含本脚本）"
        echo -e "  0) 退出脚本"
        echo -e "${BLUE}================================${PLAIN}"
        
        read -p "请输入选项: " main_choice
        case $main_choice in
            1) ss_submenu ;;
            2) stls_submenu ;;
            3) install_all ;;
            4) ss_links ;;
            9) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
    done
}

# Shadowsocks子菜单
ss_submenu() {
    while true; do
        clear
        echo -e "${BLUE}=== Shadowsocks 服务管理 ===${PLAIN}"
        echo -e "  1) 安装Shadowsocks服务"
        echo -e "  2) 查看Shadowsocks服务状态"
        echo -e "  3) 查看Shadowsocks配置文件"
        echo -e "  4) 修改Shadowsocks配置文件"
        echo -e "  5) 启动Shadowsocks服务"
        echo -e "  6) 停止Shadowsocks服务"
        echo -e "  7) 重启Shadowsocks服务"
        echo -e "  9) 卸载Shadowsocks服务"
        echo -e "  0) 返回主菜单"
        
        read -p "请输入选项: " choice
        case $choice in
            1) install_shadowsocks ;;
            2) check_shadowsocks_status ;;
            3) check_shadowsocks_config ;;
            4) modify_shadowsocks_config ;;
            5) start_shadowsocks ;;
            6) stop_shadowsocks ;;
            7) restart_shadowsocks ;;
            9) uninstall_shadowsocks ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        if [[ "$choice" != "0" ]]; then
            read -n 1 -s -r -p "按任意键继续..."
        fi
    done
}

# ShadowTLS子菜单
stls_submenu() {
    while true; do
        clear
        echo -e "${BLUE}=== ShadowTLS 服务管理 ===${PLAIN}"
        echo -e "  1) 安装ShadowTLS服务"
        echo -e "  2) 查看ShadowTLS服务状态"
        echo -e "  3) 查看ShadowTLS配置文件"
        echo -e "  4) 修改ShadowTLS配置文件"
        echo -e "  5) 启动ShadowTLS服务"
        echo -e "  6) 停止ShadowTLS服务"
        echo -e "  7) 重启ShadowTLS服务"
        echo -e "  9) 卸载ShadowTLS服务"
        echo -e "  0) 返回主菜单"
        
        read -p "请输入选项: " choice
        case $choice in
            1) install_shadowtls ;;
            2) check_shadowtls_status ;;
            3) check_shadowtls_config ;;
            4) modify_shadowtls_config ;;
            5) shadowtls_control start ;;
            6) shadowtls_control stop ;;
            7) shadowtls_control restart ;;
            9) uninstall_shadowtls ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        if [[ "$choice" != "0" ]]; then
            read -n 1 -s -r -p "按任意键继续..."
        fi
    done
}

# 脚本入口
check_root
main_menu
