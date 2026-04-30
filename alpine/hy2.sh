#!/bin/sh
# Hysteria2 Alpine 专版管理脚本 - 完美兼容版
set -e

# 颜色定义
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
CONF="$WORKDIR/config.yaml"
IP4_CACHE=""
IP6_CACHE=""

# 权限校验
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}❌ 请使用 root 运行${NC}"
    exit 1
fi

# 依赖检查
prepare_env() {
    if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}▶ 正在安装必要依赖...${NC}"
        apk add --no-cache wget curl openssl openrc jq
    fi
}

# 架构自动匹配
get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "hysteria-linux-amd64" ;;
        aarch64|arm64) echo "hysteria-linux-arm64" ;;
        armv7l) echo "hysteria-linux-arm" ;;
        *) echo "" ;;
    esac
}

# 高性能 IP 缓存
get_ip_cache() {
    if [ -z "$IP4_CACHE" ] || [ "$IP4_CACHE" = "未检测到" ]; then
        IP4_CACHE=$(curl -s4 --connect-timeout 2 ip.sb || curl -s4 --connect-timeout 2 icanhazip.com || echo "未检测到")
    fi
    if [ -z "$IP6_CACHE" ] || [ "$IP6_CACHE" = "未检测到" ]; then
        IP6_CACHE=$(curl -s6 --connect-timeout 2 ip.sb || curl -s6 --connect-timeout 2 icanhazip.com || echo "未检测到")
    fi
}

# BBR 探测
get_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo -e "${GREEN}开启${NC}"
    else
        echo -e "${RED}未开启/不支持${NC}"
    fi
}

# 服务状态检测
get_service_status() {
    if rc-service hysteria status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未安装/未运行${NC}"
    fi
}

# 自动化防火墙
manage_firewall() {
    local action="$1" port="$2"
    if [ -z "$port" ]; then
        return
    fi
    if command -v ufw >/dev/null 2>&1; then
        if [ "$action" = "add" ]; then
            ufw allow "$port"/udp >/dev/null 2>&1 || true
        else
            ufw delete allow "$port"/udp >/dev/null 2>&1 || true
        fi
    elif command -v iptables >/dev/null 2>&1; then
        if [ "$action" = "add" ]; then
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        else
            iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    fi
}

# 实时日志
view_logs() {
    echo -e "${YELLOW}▶ 正在查看实时日志 (Ctrl+C 退出)...${NC}"
    tail -f /var/log/messages 2>/dev/null | grep hysteria || echo -e "${RED}❌ 暂无日志记录${NC}"
}

# 配置导出
show_config() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 未检测到安装记录${NC}"; return
    fi
    local port pass sni addr
    port=$(grep "listen:" "$CONF" | awk '{print $2}' | tr -d '[:space:]' | sed 's/://g')
    pass=$(grep "password:" "$CONF" | awk '{print $2}' | tr -d '[:space:]')
    
    # 兼容不同 OpenSSL 版本的 CN 提取 (处理有无空格的情况)
    sni=$(openssl x509 -noout -subject -in "$WORKDIR/server.crt" 2>/dev/null | sed 's/.*CN[ =]*//' | tr -d '[:space:]')
    if [ -z "$sni" ]; then
        sni="www.bing.com"
    fi
    
    # 如果检测到绑定了域名，优先使用域名作为链接地址
    if [ "$sni" != "www.bing.com" ] && [ "$sni" != "bing.com" ]; then
        addr="$sni"
    else
        get_ip_cache
        addr="${IP4_CACHE}"
        if [ "$addr" = "未检测到" ]; then
            addr="YOUR_IP"
        fi
    fi

    echo -e "${GREEN}========== Hysteria2 配置详情 ==========${NC}"
    echo -e "端口: ${YELLOW}$port${NC} | 密码: ${YELLOW}$pass${NC}"
    echo -e "SNI:  ${YELLOW}$sni${NC}"
    echo -e "链接: ${CYAN}hy2://$pass@$addr:$port/?sni=$sni&alpn=h3&insecure=1#Alpine_Hy2${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# 动态修改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 尚未安装 Hysteria2${NC}"; return
    fi
    local old_port new_port
    old_port=$(grep "listen:" "$CONF" | awk '{print $2}' | tr -d '[:space:]' | sed 's/://g')
    echo -e "当前端口为: ${YELLOW}$old_port${NC}"
    read -p "请输入新端口 (1-65535): " new_port
    if ! echo "$new_port" | grep -qE '^[0-9]+$' || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}❌ 无效端口${NC}"; return
    fi

    manage_firewall "del" "$old_port"
    sed -i "s/listen: :$old_port/listen: :$new_port/g" "$CONF"
    manage_firewall "add" "$new_port"
    service hysteria restart
    echo -e "${GREEN}✅ 端口已成功更新为 $new_port${NC}"
}

# 动态修改域名
change_domain() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 尚未安装 Hysteria2${NC}"; return
    fi
    local old_sni new_sni
    old_sni=$(openssl x509 -noout -subject -in "$WORKDIR/server.crt" 2>/dev/null | sed 's/.*CN[ =]*//' | tr -d '[:space:]')
    if [ -z "$old_sni" ]; then
        old_sni="www.bing.com"
    fi
    echo -e "当前域名 (SNI) 为: ${YELLOW}$old_sni${NC}"
    read -p "请输入新域名 (回车默认 www.bing.com): " new_sni
    if [ -z "$new_sni" ]; then
        new_sni="www.bing.com"
    fi

    echo -e "${YELLOW}▶ 正在重新生成 ECC 证书...${NC}"
    openssl ecparam -name prime256v1 -out "$WORKDIR/param.pem"
    openssl req -x509 -nodes -newkey ec:"$WORKDIR/param.pem" \
        -keyout "$WORKDIR/server.key" -out "$WORKDIR/server.crt" \
        -subj "/CN=$new_sni" -days 3650 2>/dev/null
    rm -f "$WORKDIR/param.pem"

    sed -i "s|url: .*|url: https://$new_sni/|g" "$CONF"
    
    service hysteria restart || true
    echo -e "${GREEN}✅ 域名已成功更新为 $new_sni${NC}"
}

# 安装流程
install_hy2() {
    prepare_env
    local FILE arch PORT GENPASS SNI CONNECT_ADDR
    FILE=$(get_arch)
    if [ -z "$FILE" ]; then
        echo -e "${RED}❌ 不支持的架构${NC}"
        return
    fi

    echo -e "${YELLOW}▶ 正在下载最新版 Hysteria2...${NC}"
    wget -O "$BIN" "https://download.hysteria.network/app/latest/$FILE" --no-check-certificate
    chmod +x "$BIN"

    mkdir -p "$WORKDIR"
    read -p "请输入域名 (回车跳过): " DOMAIN
    read -p "请输入端口 (默认40443): " PORT
    PORT=${PORT:-40443}
    if ! echo "$PORT" | grep -qE '^[0-9]+$'; then
        PORT=40443
    fi
    
    GENPASS=$(openssl rand -base64 16)
    get_ip_cache
    SNI="${DOMAIN:-www.bing.com}"

    echo -e "${YELLOW}▶ 生成 ECC 证书...${NC}"
    openssl ecparam -name prime256v1 -out "$WORKDIR/param.pem"
    openssl req -x509 -nodes -newkey ec:"$WORKDIR/param.pem" \
        -keyout "$WORKDIR/server.key" -out "$WORKDIR/server.crt" \
        -subj "/CN=$SNI" -days 3650 2>/dev/null
    rm -f "$WORKDIR/param.pem"

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
    url: https://$SNI/
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
    service hysteria restart || true

    ln -sf "$(readlink -f "$0")" /usr/local/bin/hy2
    chmod +x /usr/local/bin/hy2

    echo -e "${GREEN}✅ 安装圆满完成！${NC}"
    echo -e "${CYAN}💡 快捷启动命令已创建：在任何位置输入 ${YELLOW}hy2${CYAN} 即可打开本菜单${NC}"
    show_config
}

# 完整卸载
uninstall_hy2() {
    echo -e "${YELLOW}▶ 正在彻底清理 Hysteria2...${NC}"
    local port
    port=$(grep "listen:" "$CONF" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]' | sed 's/://g')
    if [ -n "$port" ]; then
        manage_firewall "del" "$port"
    fi
    service hysteria stop 2>/dev/null || true
    rc-update del hysteria default 2>/dev/null || true
    rm -f /etc/init.d/hysteria /usr/local/bin/hy2 "$BIN" 2>/dev/null
    rm -rf "$WORKDIR" 2>/dev/null
    echo -e "${GREEN}✅ 卸载干净了${NC}"
}

# 更新脚本
update_script() {
    echo -e "${YELLOW}▶ 正在从 GitHub 检查更新...${NC}"
    local url="https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/alpine/hy2.sh"
    local tmp_file="/tmp/hy2_update.sh"
    
    if curl -sL -o "$tmp_file" "$url"; then
        if grep -q "#!/bin/sh" "$tmp_file"; then
            mv "$tmp_file" "$(readlink -f "$0")"
            chmod +x "$(readlink -f "$0")"
            echo -e "${GREEN}✅ 脚本已更新为最新版本，正在重新启动...${NC}"
            sleep 1
            exec sh "$(readlink -f "$0")"
        else
            echo -e "${RED}❌ 更新失败：下载内容无效${NC}"
            rm -f "$tmp_file"
        fi
    else
        echo -e "${RED}❌ 网络连接失败，请检查网络后再试${NC}"
    fi
}

# 主菜单循环
while true; do
    clear
    get_ip_cache
    echo -e "${GREEN}===============================================${NC}"
    echo -e "      Hysteria2 Alpine 专版管理脚本"
    echo -e "  IPv4: ${YELLOW}$IP4_CACHE${NC}  IPv6: ${YELLOW}$IP6_CACHE${NC}"
    echo -e "  状态: $(get_service_status)  |  BBR: $(get_bbr_status)"
    echo -e "${GREEN}===============================================${NC}"
    echo -e "  ${CYAN}[1]${NC} 安装 Hysteria2"
    echo -e "  ${CYAN}[2]${NC} 查看配置信息 (链接)"
    echo -e "  ${CYAN}[3]${NC} 修改监听端口"
    echo -e "  ${CYAN}[4]${NC} 修改绑定域名"
    echo -e "  ${CYAN}[5]${NC} 实时日志"
    echo -e "  ${CYAN}[6]${NC} 重启服务"
    echo -e "  ${CYAN}[7]${NC} 彻底卸载"
    echo -e "  ${CYAN}[8]${NC} 更新管理脚本"
    echo -e "  ${CYAN}[0]${NC} 退出脚本"
    echo -e "${GREEN}===============================================${NC}"
    read -p "选择操作 [0-8]: " choice
    case "$choice" in
        1) install_hy2 ;;
        2) show_config ;;
        3) change_port ;;
        4) change_domain ;;
        5) view_logs ;;
        6) service hysteria restart; echo -e "${GREEN}已重启${NC}" ;;
        7) uninstall_hy2 ;;
        8) update_script ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误${NC}" ;;
    esac
    echo -e "\n按任意键返回..."
    read -r tmp
done