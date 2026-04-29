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

# 必须以 root 运行
[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

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

# 安装 Hysteria2
install_hy2() {
    echo -e "${YELLOW}▶ 正在安装必要依赖...${NC}"
    apk add --no-cache wget curl openssl openrc jq

    local FILE
    FILE=$(get_arch)
    [[ -z "$FILE" ]] && { echo -e "${RED}❌ 不支持的架构${NC}"; return; }

    echo -e "${YELLOW}▶ 正在下载 Hysteria2...${NC}"
    wget -O "$BIN" "https://download.hysteria.network/app/latest/$FILE" --no-check-certificate
    chmod +x "$BIN"

    mkdir -p "$WORKDIR"
    read -p "请输入监听端口 (默认40443): " PORT
    PORT=${PORT:-40443}
    
    local GENPASS
    GENPASS=$(openssl rand -base64 16)
    local SNI="www.bing.com"

    # 生成证书
    echo -e "${YELLOW}▶ 正在生成自签名证书...${NC}"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$WORKDIR/server.key" \
        -out "$WORKDIR/server.crt" \
        -subj "/CN=$SNI" -days 3650 2>/dev/null

    # 写入配置
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

    # 写入服务
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
    rc-update add hysteria default
    service hysteria restart

    # 创建快捷命令
    ln -sf "$(readlink -f "$0")" /usr/local/bin/hy2
    chmod +x /usr/local/bin/hy2

    # 获取 IP
    local IP
    IP=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 icanhazip.com || echo "YOUR_IP")

    echo -e "${GREEN}✅ 安装成功！${NC}"
    echo -e "📎 节点链接：${YELLOW}hy2://$GENPASS@$IP:$PORT/?sni=$SNI&alpn=h3&insecure=1#Alpine_Hy2${NC}"
    echo -e "${CYAN}💡 以后可输入 ${YELLOW}hy2${CYAN} 快速打开此菜单${NC}"
}

# 卸载
uninstall_hy2() {
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
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
    echo -e "${GREEN}===============================================${NC}"
    echo -e "      Hysteria2 Alpine 专版管理脚本"
    echo -e "${GREEN}===============================================${NC}"
    echo -e "  ${CYAN}[1]${NC} 安装 Hysteria2"
    echo -e "  ${CYAN}[2]${NC} 重启服务"
    echo -e "  ${CYAN}[3]${NC} 查看状态"
    echo -e "  ${CYAN}[4]${NC} 卸载 Hysteria2"
    echo -e "  ${CYAN}[0]${NC} 退出脚本"
    echo -e "${GREEN}===============================================${NC}"
    read -p "请输入数字选择 [0-4]: " choice

    case $choice in
        1)
            install_hy2
            ;;
        2)
            service hysteria restart
            echo -e "${GREEN}服务已重启${NC}"
            ;;
        3)
            service hysteria status
            ;;
        4)
            uninstall_hy2
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入${NC}"
            ;;
    esac
    echo -e "\n按任意键返回主菜单..."
    read -n 1 -s -r
done