#!/bin/bash

# 颜色定义
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'

WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
CONF="$WORKDIR/config.yaml"
IP4_CACHE=""
IP6_CACHE=""

# 必须以 root 运行
[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 依赖安装
prepare_env() {
    echo -e "${YELLOW}▶ 正在安装/检查必要依赖...${NC}"
    apk add --no-cache wget curl openssl openrc jq
}

# 架构检测
get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "hysteria-linux-amd64" ;;
        aarch64|arm64) echo "hysteria-linux-arm64" ;;
        armv7l) echo "hysteria-linux-arm" ;;
        *) echo "";;
    esac
}

# IP 缓存获取
get_ip_cache() {
    if [[ -z "$IP4_CACHE" ]]; then
        IP4_CACHE=$(curl -s4 --connect-timeout 2 ip.sb || curl -s4 --connect-timeout 2 icanhazip.com || echo "未检测到")
    fi
    if [[ -z "$IP6_CACHE" ]]; then
        IP6_CACHE=$(curl -s6 --connect-timeout 2 ip.sb || curl -s6 --connect-timeout 2 icanhazip.com || echo "未检测到")
    fi
}

# BBR 状态检测
get_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}开启${NC}"
    else
        echo -e "${RED}未开启${NC}"
    fi
}

# 防火墙管理
manage_firewall() {
    local action="$1"
    local port="$2"
    [[ -z "$port" ]] && return

    if command -v ufw >/dev/null 2>&1; then
        [[ "$action" == "add" ]] && ufw allow "$port"/udp >/dev/null 2>&1 || ufw delete allow "$port"/udp >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        [[ "$action" == "add" ]] && iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
    fi
}

# 查看实时日志
view_logs() {
    echo -e "${YELLOW}▶ 正在查看实时日志 (按 Ctrl+C 退出)...${NC}"
    tail -f /var/log/messages | grep hysteria || echo -e "${RED}无法读取日志${NC}"
}

# 查看配置
show_config() {
    if [[ ! -f "$CONF" ]]; then
        echo -e "${RED}❌ 配置文件不存在，请先安装${NC}"
        return
    fi
    local port pass sni
    port=$(grep "listen:" "$CONF" | awk '{print $2}' | sed 's/://g')
    pass=$(grep "password:" "$CONF" | awk '{print $2}')
    sni=$(grep "/CN=" "$WORKDIR/server.crt" 2>/dev/null | awk -F'=' '{print $2}' || echo "www.bing.com")
    
    get_ip_cache
    local connect_addr="${IP4_CACHE}"
    [[ "$connect_addr" == "未检测到" ]] && connect_addr="YOUR_IP"

    echo -e "${GREEN}========== 当前 Hysteria2 配置 ==========${NC}"
    echo -e "监听端口: ${YELLOW}$port${NC}"
    echo -e "认证密码: ${YELLOW}$pass${NC}"
    echo -e "伪装 SNI: ${YELLOW}$sni${NC}"
    echo -e ""
    echo -e "📎 节点链接: ${CYAN}hy2://$pass@$connect_addr:$port/?sni=$sni&alpn=h3&insecure=1#Alpine_Hy2${NC}"
    echo -e "${GREEN}=========================================${NC}"
}

# 修改端口
change_port() {
    if [[ ! -f "$CONF" ]]; then
        echo -e "${RED}❌ 配置文件不存在${NC}"; return
    fi
    local old_port new_port
    old_port=$(grep "listen:" "$CONF" | awk '{print $2}' | sed 's/://g')
    echo -e "当前监听端口为: ${YELLOW}$old_port${NC}"
    read -p "请输入新端口 (1-65535): " new_port
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 ]] || [[ "$new_port" -gt 65535 ]]; then
        echo -e "${RED}无效输入${NC}"; return
    fi

    manage_firewall "del" "$old_port"
    sed -i "s/listen: :$old_port/listen: :$new_port/g" "$CONF"
    manage_firewall "add" "$new_port"
    service hysteria restart
    echo -e "${GREEN}✅ 端口已成功修改为 $new_port${NC}"
}

# 安装 Hysteria2
install_hy2() {
    prepare_env
    local FILE
    FILE=$(get_arch)
    [[ -z "$FILE" ]] && { echo -e "${RED}❌ 不支持的架构${NC}"; return; }

    echo -e "${YELLOW}▶ 正在下载 Hysteria2...${NC}"
    wget -O "$BIN" "https://download.hysteria.network/app/latest/$FILE" --no-check-certificate
    chmod +x "$BIN"

    mkdir -p "$WORKDIR"
    
    read -p "请输入绑定的域名 (可选，直接回车使用 IP): " DOMAIN
    read -p "请输入监听端口 (默认40443): " PORT
    PORT=${PORT:-40443}
    [[ ! "$PORT" =~ ^[0-9]+$ ]] && PORT=40443
    
    local GENPASS
    GENPASS=$(openssl rand -base64 16)
    
    get_ip_cache
    local CONNECT_ADDR="${DOMAIN:-$IP4_CACHE}"
    [[ "$CONNECT_ADDR" == "未检测到" ]] && CONNECT_ADDR="YOUR_IP"
    local SNI="${DOMAIN:-www.bing.com}"

    echo -e "${YELLOW}▶ 正在生成自签名证书 (SNI: $SNI)...${NC}"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$WORKDIR/server.key" \
        -out "$WORKDIR/server.crt" \
        -subj "/CN=$SNI" -days 3650 2>/dev/null

    cat << EOF > "$CONF"
listen: :$PORT
tls:
  cert: $WORKDIR/server.crt
  key: $WORKDIR/server.key
auth:
  type: password
  password: $GENPASS
masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF

    cat << EOF > /etc/init.d/hysteria
#!/sbin/openrc-run
name="hysteria"
command="$BIN"
command_args="server --config $CONF"
pidfile="/run/\${name}.pid"
command_background="yes"
supervisor="supervise-daemon"
depend() { need net; }
EOF
    chmod +x /etc/init.d/hysteria
    manage_firewall "add" "$PORT"
    rc-update add hysteria default
    service hysteria restart

    ln -sf "$(readlink -f "$0")" /usr/local/bin/hy2
    chmod +x /usr/local/bin/hy2

    echo -e "${GREEN}✅ 安装成功！${NC}"
    show_config
    echo -e "${CYAN}💡 以后可输入 ${YELLOW}hy2${CYAN} 快速打开此菜单${NC}"
}

# 卸载
uninstall_hy2() {
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    local port
    port=$(grep "listen:" "$CONF" 2>/dev/null | awk '{print $2}' | sed 's/://g')
    manage_firewall "del" "$port"
    service hysteria stop 2>/dev/null || true
    rc-update del hysteria default 2>/dev/null || true
    rm -f /etc/init.d/hysteria 2>/dev/null
    rm -rf "$WORKDIR" 2>/dev/null
    rm -f "$BIN" 2>/dev/null
    rm -f /usr/local/bin/hy2 2>/dev/null
    echo -e "${GREEN}✅ 卸载完成${NC}"
}

# 菜单循环
while true; do
    clear
    get_ip_cache
    echo -e "${GREEN}===============================================${NC}"
    echo -e "      Hysteria2 Alpine 专版管理脚本"
    echo -e "  IPv4: ${YELLOW}$IP4_CACHE${NC}  IPv6: ${YELLOW}$IP6_CACHE${NC}"
    echo -e "  BBR 状态: $(get_bbr_status)"
    echo -e "${GREEN}===============================================${NC}"
    echo -e "  ${CYAN}[1]${NC} 安装 Hysteria2"
    echo -e "  ${CYAN}[2]${NC} 查看配置信息 (节点链接)"
    echo -e "  ${CYAN}[3]${NC} 修改监听端口"
    echo -e "  ${CYAN}[4]${NC} 查看实时日志"
    echo -e "  ${CYAN}[5]${NC} 重启服务"
    echo -e "  ${CYAN}[6]${NC} 查看服务状态"
    echo -e "  ${CYAN}[7]${NC} 卸载 Hysteria2"
    echo -e "  ${CYAN}[0]${NC} 退出脚本"
    echo -e "${GREEN}===============================================${NC}"
    read -p "请输入数字选择 [0-7]: " choice

    case $choice in
        1) install_hy2 ;;
        2) show_config ;;
        3) change_port ;;
        4) view_logs ;;
        5) service hysteria restart; echo -e "${GREEN}服务已重启${NC}" ;;
        6) service hysteria status ;;
        7) uninstall_hy2 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${NC}" ;;
    esac
    echo -e "\n按任意键返回主菜单..."
    read -n 1 -s -r
done