#!/bin/bash

# 检查并安装xz工具
check_xz() {
    if ! command -v xz &> /dev/null; then
        echo "检测到 xz 工具未安装，正在安装..."
        if command -v apt &> /dev/null; then
            apt update && apt install -y xz-utils
        elif command -v yum &> /dev/null; then
            yum install -y xz
        elif command -v dnf &> /dev/null; then
            dnf install -y xz
        else
            echo "无法确定包管理器，请手动安装 xz 工具"
            exit 1
        fi
        
        if [ $? -ne 0 ]; then
            echo "xz 工具安装失败，请检查网络连接或手动安装"
            exit 1
        fi
        echo "xz 工具安装成功"
    else
        echo "xz 工具已安装"
    fi
}

# 在脚本开始时执行 xz 检查
check_xz

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
        echo "不支持的架构: $ARCH"
        exit 1
        ;;
esac

# 获取 GitHub 最新 release 的信息
get_latest_release_info() {
    local api_response
    api_response=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest)
    if [ $? -ne 0 ]; then
        echo "获取 GitHub 最新 release 信息失败"
        exit 1
    fi
    echo "$api_response"
}

RELEASE_INFO=$(get_latest_release_info)
LATEST_TAG=$(echo "$RELEASE_INFO" | grep '"tag_name"' | cut -d '"' -f 4)

if [ -z "$LATEST_TAG" ]; then
    echo "无法获取最新版本信息"
    exit 1
fi

LATEST_RELEASE_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/$LATEST_TAG/shadowsocks-$LATEST_TAG.$ARCH_SUFFIX.tar.xz"

# 检查当前安装的版本
get_current_version() {
    if command -v ssserver &> /dev/null; then
        local version
        version=$(ssserver --version | awk '{print $2}')
        echo "v$version"
    else
        echo "未安装"
    fi
}

CURRENT_VERSION=$(get_current_version)

# 判断是否需要更新
if [[ "$CURRENT_VERSION" != "$LATEST_TAG" ]]; then
    if [[ "$CURRENT_VERSION" == "未安装" ]]; then
        echo "Shadowsocks 尚未安装，将安装最新版本: $LATEST_TAG"
    else
        echo "发现新版本: $LATEST_TAG，当前版本: $CURRENT_VERSION"
    fi
    echo "正在下载最新版本..."
    wget -q "$LATEST_RELEASE_URL"
    if [ $? -ne 0 ]; then
        echo "下载失败，请检查网络连接或稍后重试"
        exit 1
    fi
    echo "下载完成，正在安装..."
    tar -Jxf shadowsocks-*.tar.xz -C /usr/local/bin/ 2>/dev/null
    rm shadowsocks-*.tar.xz
    echo "安装/更新完成"
else
    echo "当前已是最新版本: $CURRENT_VERSION，无需更新"
fi

# 创建配置文件目录
mkdir -p /etc/shadowsocks

# 询问用户是否输入自定义端口
read -p "请输入自定义端口(1024-65535)，或按回车随机生成: " custom_port

# 检查自定义端口是否合法
if [[ -z "$custom_port" || ! "$custom_port" =~ ^[0-9]+$ || "$custom_port" -lt 1025 || "$custom_port" -gt 65535 ]]; then
    echo "无效的端口，使用随机生成的端口"
    custom_port=$(shuf -i 1024-65535 -n 1)
else
    echo "使用自定义端口: $custom_port"
fi

# 询问用户选择加密方法
echo "请选择加密方法（回车则默认为2022-blake3-aes-256-gcm）:"
echo "1) 2022-blake3-aes-128-gcm"
echo "2) 2022-blake3-aes-256-gcm 【推荐】"
echo "3) 2022-blake3-chacha20-poly1305"
echo "4) aes-256-gcm"
echo "5) aes-128-gcm"
echo "6) chacha20-ietf-poly1305"
echo "7) xchacha20-ietf-poly1305"
echo "8) none"
echo "9) aes-128-cfb"
echo "10) aes-192-cfb"
echo "11) aes-256-cfb"
echo "12) aes-128-ctr"
echo "13) aes-192-ctr"
echo "14) aes-256-ctr"
echo "15) camellia-128-cfb"
echo "16) camellia-192-cfb"
echo "17) camellia-256-cfb"
echo "18) rc4-md5"
echo "19) chacha20-ietf"

read -p "请输入选项数字 (默认为 2): " encryption_choice

# 如果用户没有输入，默认选择 2022-blake3-aes-256-gcm
encryption_choice=${encryption_choice:-2}

# 根据用户选择设置加密方法和密码
case $encryption_choice in
    1)
        method="2022-blake3-aes-128-gcm"
        password=$(openssl rand -base64 16)
        ;;
    2)
        method="2022-blake3-aes-256-gcm"
        password=$(openssl rand -base64 32)
        ;;
    3)
        method="2022-blake3-chacha20-poly1305"
        password=$(openssl rand -base64 32)
        ;;
    *)
        case $encryption_choice in
            4) method="aes-256-gcm" ;;
            5) method="aes-128-gcm" ;;
            6) method="chacha20-ietf-poly1305" ;;
            7) method="xchacha20-ietf-poly1305" ;;
            8) method="none" ;;
            9) method="aes-128-cfb" ;;
            10) method="aes-192-cfb" ;;
            11) method="aes-256-cfb" ;;
            12) method="aes-128-ctr" ;;
            13) method="aes-192-ctr" ;;
            14) method="aes-256-ctr" ;;
            15) method="camellia-128-cfb" ;;
            16) method="camellia-192-cfb" ;;
            17) method="camellia-256-cfb" ;;
            18) method="rc4-md5" ;;
            19) method="chacha20-ietf" ;;
            *)
                echo "无效选项，使用默认方法: 2022-blake3-aes-256-gcm"
                method="2022-blake3-aes-256-gcm"
                password=$(openssl rand -base64 32)
                ;;
        esac
        read -p "请输入自定义密码 (留空使用默认密码 'yuju.love'): " custom_password
        if [[ -z "$custom_password" ]]; then
            password="yuju.love"
        else
            password="$custom_password"
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
echo "正在生成配置文件..."
cat <<EOF >/etc/shadowsocks/config.json
{
    "server": "0.0.0.0",
    "server_port": $custom_port,
    "password": "$password",
    "method": "$method",
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF
echo "配置文件已生成"

# 生成 systemd 服务文件（无论是否存在，都会覆盖）
echo "正在生成服务文件..."
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
echo "服务文件已生成"

# 检查 Shadowsocks 服务是否已经存在
service_exists() {
    systemctl list-unit-files | grep -Fq "shadowsocks.service"
}

# 重启或启动 Shadowsocks 服务
restart_or_start_service() {
    if service_exists; then
        echo "重启 Shadowsocks 服务..."
        systemctl restart shadowsocks
        if [ $? -eq 0 ]; then
            echo "Shadowsocks 服务已成功重启"
        else
            echo "重启 Shadowsocks 服务失败"
        fi
    else
        echo "首次启动 Shadowsocks 服务..."
        systemctl start shadowsocks
        if [ $? -eq 0 ]; then
            echo "Shadowsocks 服务已成功启动"
        else
            echo "启动 Shadowsocks 服务失败"
        fi
    fi
}

# 重新加载 systemd 配置
systemctl daemon-reload

# 重启或启动 Shadowsocks 服务
restart_or_start_service

# 启用 Shadowsocks 服务自启动
echo "正在启用 Shadowsocks 服务自启动..."
enable_result=$(systemctl enable shadowsocks 2>&1)
if [ $? -eq 0 ]; then
    echo "Shadowsocks 服务已设置为开机自启动"
else
    echo "设置 Shadowsocks 服务自启动失败: $enable_result"
fi

# 检查 Shadowsocks 服务状态
systemctl_status=$(systemctl is-active shadowsocks)
echo "Shadowsocks 的服务状态为：$systemctl_status"

# 获取公网 IP 地址的函数
get_public_ip() {
    # 尝试多个服务来确保能获取到 IP
    public_ip=$(curl -s -m 10 https://api.ipify.org || \
                curl -s -m 10 https://api.ip.sb/ip || \
                curl -s -m 10 https://icanhazip.com)
    
    if [[ -z "$public_ip" ]]; then
        echo "无法获取公网 IP 地址，将使用内网 IP 地址"
        public_ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$public_ip"
}

public_ip=$(get_public_ip)

# 构建并输出 ss:// 格式的链接
base64_password=$(echo -n "$method:$password" | base64 -w 0)
echo "Shadowsocks 节点信息: ss://${base64_password}@${public_ip}:$custom_port#$node_name"
