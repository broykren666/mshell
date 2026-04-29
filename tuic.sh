#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
WORK_DIR="/usr/local/tuic"
BIN="${WORK_DIR}/tuic-server"
CONF="${WORK_DIR}/config.json"
SERVICE_NAME="tuic"
PORT_FILE="${WORK_DIR}/port.txt"
### =====================

GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 环境判断
if command -v apk >/dev/null 2>&1; then
    OS="alpine"
elif command -v apt >/dev/null 2>&1; then
    OS="debian"
else
    echo -e "${RED}❌ 仅支持 Alpine / Debian / Ubuntu${NC}"
    exit 1
fi

# 依赖检查与安装
prepare_env() {
    local deps=("curl" "jq" "openssl" "ca-certificates" "bash")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${YELLOW}▶ 正在安装必要依赖: ${missing[*]}...${NC}"
        if [ "$OS" = "alpine" ]; then
            apk add --no-cache "${missing[@]}"
        else
            apt update && apt install -y "${missing[@]}"
        fi
    fi
}

# 防火墙管理
manage_firewall() {
    local action=$1
    local port=$2
    [[ -z "$port" ]] && return

    if command -v ufw >/dev/null 2>&1; then
        if [ "$action" = "add" ]; then
            ufw allow "$port"/udp >/dev/null 2>&1
        else
            ufw delete allow "$port"/udp >/dev/null 2>&1
        fi
    elif command -v iptables >/dev/null 2>&1; then
        if [ "$action" = "add" ]; then
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
        else
            iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
        fi
    fi
}

# 重启服务
restart_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service ${SERVICE_NAME} restart
    else
        systemctl restart ${SERVICE_NAME}
    fi
}

# 获取并显示配置信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 配置文件不存在${NC}"
        return
    fi

    prepare_env
    SERVER_ADDR=$(jq -r '.server' "$CONF")
    PORT=$(echo $SERVER_ADDR | rev | cut -d: -f1 | rev | sed 's/\]//g')
    UUID=$(jq -r '.users | keys[0]' "$CONF")
    PASS=$(jq -r ".users.\"$UUID\"" "$CONF")
    
    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 icanhazip.com || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 icanhazip.com || echo "")

    echo -e "\n${GREEN}========== TUIC 配置信息 ==========${NC}"
    echo -e "🌐 IPv4地址: ${YELLOW}$IP4${NC}"
    echo -e "🌐 IPv6地址: ${YELLOW}$IP6${NC}"
    echo -e "📌 UUID: ${YELLOW}$UUID${NC}"
    echo -e "🔐 密码: ${YELLOW}$PASS${NC}"
    echo -e "🎲 端口: ${YELLOW}$PORT${NC}"
    
    if [[ -n "$IP4" ]]; then
        echo -e "\n${GREEN}📎 TUIC 节点链接 (IPv4):${NC}"
        echo -e "${YELLOW}tuic://$UUID:$PASS@$IP4:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V4${NC}"
    fi
    
    if [[ -n "$IP6" ]]; then
        echo -e "\n${GREEN}📎 TUIC 节点链接 (IPv6):${NC}"
        echo -e "${YELLOW}tuic://$UUID:$PASS@[$IP6]:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V6${NC}"
    fi
    echo -e "${GREEN}===============================================${NC}\n"
}

# 修改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 TUIC${NC}"; return
    fi
    prepare_env
    OLD_ADDR=$(jq -r '.server' "$CONF")
    OLD_PORT=$(echo $OLD_ADDR | rev | cut -d: -f1 | rev | sed 's/\]//g')
    HOST=$(echo $OLD_ADDR | rev | cut -d: -f2- | rev)
    
    echo -e "当前监听端口为: ${YELLOW}$OLD_PORT${NC}"
    read -p "请输入新端口 (回车10000-65535随机): " NEW_PORT
    
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}❌ 输入无效${NC}"; return
    fi

    # 更新防火墙
    manage_firewall "del" "$OLD_PORT"
    manage_firewall "add" "$NEW_PORT"

    tmp=$(mktemp)
    jq --arg addr "${HOST}:${NEW_PORT}" '.server = $addr' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    echo "$NEW_PORT" > "$PORT_FILE"
    
    restart_service
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}"
    show_info
}

# 安装 TUIC
install_tuic() {
    prepare_env
    
    mkdir -p "$WORK_DIR"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) TUIC_ARCH="x86_64" ;;
        aarch64|arm64) TUIC_ARCH="aarch64" ;;
        *) echo "❌ 不支持架构: $ARCH"; exit 1 ;;
    esac

    echo -e "${YELLOW}▶ 下载 TUIC Server ($ARCH)...${NC}"
    URL="https://github.com/Itsusinn/tuic/releases/latest/download/tuic-server-${TUIC_ARCH}-linux-musl"
    if ! curl -L -o $BIN "$URL"; then
        echo -e "${RED}❌ 下载失败，请检查网络${NC}"; exit 1
    fi
    chmod +x $BIN

    read -p "请输入认证密码 (回车生成随机强密码): " PASS
    [[ -z "$PASS" ]] && PASS=$(openssl rand -hex 12)
    echo -e "${YELLOW}🔑 使用密码: ${PASS}${NC}"

    read -p "请输入监听端口 (回车10000-65535随机): " PORT
    [[ -z "$PORT" ]] && PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        PORT=$(( ( RANDOM % 55535 ) + 10000 ))
        echo -e "${YELLOW}输入无效，已分配随机端口: $PORT${NC}"
    fi

    echo "$PORT" > "$PORT_FILE"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    BIND_ADDR="0.0.0.0"
    ip -6 addr | grep -q "global" && BIND_ADDR="[::]"

    cat > $CONF <<EOF
{
  "server": "${BIND_ADDR}:${PORT}",
  "users": {
    "${UUID}": "${PASS}"
  },
  "congestion_control": "bbr",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "tls": {
    "certificate": "${WORK_DIR}/cert.pem",
    "private_key": "${WORK_DIR}/key.pem",
    "alpn": ["h3"]
  }
}
EOF

    echo -e "${YELLOW}▶ 生成自签证书...${NC}"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/cert.pem" \
        -subj "/CN=www.bing.com" -days 3650 -nodes 2>/dev/null

    # 配置防火墙
    manage_firewall "add" "$PORT"

    # 服务部署
    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run
description="TUIC Server"
command="${BIN}"
command_args="-c ${CONF}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
supervisor="supervise-daemon"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/${SERVICE_NAME}
        rc-update add ${SERVICE_NAME} default
    else
        cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=TUIC Server
After=network.target
[Service]
ExecStart=${BIN} -c ${CONF}
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}
    fi

    # 配置快捷命令
    SCRIPT_PATH=$(readlink -f "$0")
    ln -sf "$SCRIPT_PATH" /usr/local/bin/tuic
    chmod +x /usr/local/bin/tuic

    restart_service
    echo -e "${GREEN}✅ TUIC 安装并配置完成${NC}"
    echo -e "${CYAN}💡 快捷键已创建，下次可直接输入 ${YELLOW}tuic${CYAN} 进入此菜单${NC}"
    show_info
}

# 卸载
uninstall_tuic() {
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    
    # 清理快捷命令
    rm -f /usr/local/bin/tuic
    # 清理防火墙
    if [ -f "$PORT_FILE" ]; then
        OLD_PORT=$(cat "$PORT_FILE")
        manage_firewall "del" "$OLD_PORT"
    fi

    if [ "$OS" = "alpine" ]; then
        rc-service ${SERVICE_NAME} stop || true
        rc-update del ${SERVICE_NAME} || true
        rm -f /etc/init.d/${SERVICE_NAME}
    else
        systemctl stop ${SERVICE_NAME} || true
        systemctl disable ${SERVICE_NAME} || true
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
    fi
    rm -rf "$WORK_DIR"
    echo -e "${GREEN}✅ 卸载成功${NC}"
}

# 更新脚本
update_script() {
    echo -e "${YELLOW}▶ 正在从 GitHub 检查更新...${NC}"
    local url="https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/tuic.sh"
    local tmp_file="/tmp/tuic_update.sh"
    
    if curl -sL -o "$tmp_file" "$url"; then
        if grep -q "#!/usr/bin/env bash" "$tmp_file"; then
            mv "$tmp_file" "$(readlink -f "$0")"
            chmod +x "$(readlink -f "$0")"
            echo -e "${GREEN}✅ 脚本已更新为最新版本，正在重新启动...${NC}"
            sleep 1
            exec bash "$(readlink -f "$0")"
        else
            echo -e "${RED}❌ 更新失败：下载内容无效${NC}"
            rm -f "$tmp_file"
        fi
    else
        echo -e "${RED}❌ 网络连接失败，请检查网络后再试${NC}"
    fi
}

while true; do
# 状态检测逻辑
if [ "$OS" = "alpine" ]; then
    if rc-service ${SERVICE_NAME} status 2>/dev/null | grep -q "started"; then
        STATUS="${GREEN}正在运行${NC}"
    else
        STATUS="${RED}未安装或未运行${NC}"
    fi
else
    if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
        STATUS="${GREEN}正在运行${NC}"
    else
        STATUS="${RED}未安装或未运行${NC}"
    fi
fi

# 菜单
clear
echo -e "${GREEN}===============================================${NC}"
echo -e "  TUIC 一键管理脚本"
echo -e "  当前系统: $OS"
echo -e "  TUIC状态： $STATUS"
echo -e "${GREEN}===============================================${NC}"
echo -e "  ${CYAN}[1]${NC}  安装 TUIC"
echo -e "  ${CYAN}[2]${NC}  查看配置节点链接"
echo -e "  ${CYAN}[3]${NC}  更改监听端口"
echo -e "  ${CYAN}[4]${NC}  重启服务"
echo -e "  ${CYAN}[5]${NC}  卸载 TUIC"
echo -e "  ${CYAN}[6]${NC}  更新管理脚本"
echo -e "  ${CYAN}[0]${NC}  退出脚本"
echo -e "${GREEN}===============================================${NC}"
echo -ne "请输入数字选择 [0-6]: "
read choice

case $choice in
        1)
            install_tuic
            ;;
        2)
            show_info
            ;;
        3)
            change_port
            ;;
        4)
            restart_service && echo -e "${GREEN}服务已重启${NC}"
            ;;
        5)
            uninstall_tuic
            ;;
        6)
            update_script
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入，请重新选择${NC}"
            sleep 1
            ;;
    esac

    echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
    clear
done
