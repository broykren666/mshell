#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_PRIV_KEY="${XRAY_CONFIG_DIR}/private.key"
XRAY_PUB_KEY="${XRAY_CONFIG_DIR}/public.key"
PORT_FILE="${XRAY_CONFIG_DIR}/port.txt"
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
    local deps=("curl" "jq" "openssl" "ca-certificates" "bash" "unzip" "wget")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [[ "${#missing[@]}" -ne 0 ]]; then
        echo -e "${YELLOW}▶ 正在安装必要依赖: ${missing[*]}...${NC}"
        if [[ "$OS" = "alpine" ]]; then
            apk add --no-cache "${missing[@]}"
            update-ca-certificates
        else
            apt update && apt install -y "${missing[@]}"
        fi
    fi
}

# 防火墙管理
manage_firewall() {
    local action="$1"
    local port="$2"
    [[ -z "$port" ]] && return

    if command -v ufw >/dev/null 2>&1; then
        if [[ "$action" = "add" ]]; then
            ufw allow "$port"/tcp >/dev/null 2>&1
        else
            ufw delete allow "$port"/tcp >/dev/null 2>&1
        fi
    elif command -v iptables >/dev/null 2>&1; then
        if [[ "$action" = "add" ]]; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        else
            iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        fi
    fi
}

# 重启服务
restart_service() {
    if [[ "$OS" = "alpine" ]]; then
        rc-service xray restart
    else
        systemctl restart xray
    fi
}

# 查看日志
view_logs() {
    echo -e "${YELLOW}▶ 正在查看实时日志 (按 Ctrl+C 退出)...${NC}"
    if [[ "$OS" = "alpine" ]]; then
        if [[ -f /var/log/xray.log ]]; then
            tail -f /var/log/xray.log
        else
            tail -f /var/log/messages | grep --line-buffered xray || echo -e "${RED}无法读取日志${NC}"
        fi
    else
        journalctl -u xray -f
    fi
}

# BBR 优化尝试
optimize_bbr() {
    echo -e "${YELLOW}▶ 正在检测 BBR 状态...${NC}"
    local current_control
    current_control=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$current_control" == "bbr" ]]; then
        echo -e "${GREEN}✅ BBR 已经开启${NC}"
        return
    fi

    local available
    available=$(sysctl net.ipv4.tcp_available_congestion_control | grep "bbr" || true)
    if [[ -z "$available" ]]; then
        echo -e "${RED}❌ 当前内核不支持 BBR，请先升级内核${NC}"
        return
    fi

    echo -e "${YELLOW}▶ 尝试开启 BBR...${NC}"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt
        virt=$(systemd-detect-virt)
        [[ "$virt" == "openvz" || "$virt" == "lxc" ]] && echo -e "${RED}⚠️ 检测到容器环境 ($virt)，修改可能失败${NC}"
    fi

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    
    if sysctl -p >/dev/null 2>&1; then
        echo -e "${GREEN}✅ BBR 开启成功！${NC}"
    else
        echo -e "${RED}❌ BBR 开启失败，权限不足${NC}"
    fi
}

# 架构检测并下载 Xray
download_xray() {
    local arch=""
    case "$(uname -m)" in
        x86_64|x64|amd64) arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        *) echo -e "${RED}❌ 不支持的架构: $(uname -m)${NC}"; exit 1 ;;
    esac

    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    echo -e "${YELLOW}▶ 正在下载 Xray-core ($arch)...${NC}"
    
    wget -qO /tmp/xray.zip "$url"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}❌ 下载失败，请检查网络${NC}"; exit 1
    fi

    mkdir -p /tmp/xray_temp
    unzip -qo /tmp/xray.zip -d /tmp/xray_temp
    mv -f /tmp/xray_temp/xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf /tmp/xray.zip /tmp/xray_temp
}

# 获取并显示节点信息
show_info() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}❌ 配置文件不存在${NC}"; return
    fi

    prepare_env
    local UUID PORT SID DEST_DOMAIN PUB_KEY DOMAIN IPV4 IPV6
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
    PORT=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    SID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
    DEST_DOMAIN=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
    PUB_KEY=$(cat "$XRAY_PUB_KEY" 2>/dev/null || echo "")
    DOMAIN=$(cat "$XRAY_CONFIG_DIR/domain.txt" 2>/dev/null || echo "")
    
    if [[ -z "$PUB_KEY" ]]; then
        local priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
        PUB_KEY=$("$XRAY_BIN" x25519 -i "$priv" | grep -i 'Public' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        echo "$PUB_KEY" > "$XRAY_PUB_KEY"
    fi

    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IPV4=$(curl -s4m 5 ip.sb || curl -s4m 5 api.ipify.org || echo "")
    IPV6=$(curl -s6m 5 ip.sb || curl -s6m 5 api6.ipify.org || echo "")

    echo -e "\n${GREEN}========== VLESS-REALITY 配置信息 ==========${NC}"
    [[ -n "$DOMAIN" ]] && echo -e "🌐 连接域名: ${YELLOW}$DOMAIN${NC}"
    echo -e "🌐 IPv4地址: ${YELLOW}$IPV4${NC}"
    echo -e "🌐 IPv6地址: ${YELLOW}$IPV6${NC}"
    echo -e "📌 UUID: ${YELLOW}$UUID${NC}"
    echo -e "🎲 端口: ${YELLOW}$PORT${NC}"
    echo -e "🔑 Public Key: ${YELLOW}$PUB_KEY${NC}"
    echo -e "🆔 Short ID: ${YELLOW}$SID${NC}"
    echo -e "🎭 伪装域名: ${YELLOW}$DEST_DOMAIN${NC}"
    
    local link_suffix="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUB_KEY}&sid=${SID}&type=tcp&headerType=none"
    
    local ADDR_V4="${DOMAIN:-$IPV4}"
    local ADDR_V6="${DOMAIN:-$IPV6}"
    [[ -z "$DOMAIN" && -n "$IPV6" ]] && ADDR_V6="[$IPV6]"

    if [[ -n "$IPV4" || -n "$DOMAIN" ]]; then
        echo -e "\n${GREEN}📎 VLESS 节点链接 (IPv4/Domain):${NC}"
        echo -e "${YELLOW}vless://${UUID}@${ADDR_V4}:${PORT}?${link_suffix}#REALITY_V4${NC}"
    fi
    
    if [[ -n "$IPV6" && -z "$DOMAIN" ]]; then
        echo -e "\n${GREEN}📎 VLESS 节点链接 (IPv6):${NC}"
        echo -e "${YELLOW}vless://${UUID}@${ADDR_V6}:${PORT}?${link_suffix}#REALITY_V6${NC}"
    fi
    echo -e "${GREEN}===============================================${NC}\n"
}

# 修改端口
change_port() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}❌ 请先安装 VLESS-REALITY${NC}"; return
    fi
    prepare_env
    local OLD_PORT NEW_PORT tmp
    OLD_PORT=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    echo -e "当前监听端口为: ${YELLOW}$OLD_PORT${NC}"
    read -p "请输入新端口 (回车10000-65535随机): " NEW_PORT
    
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [[ "$NEW_PORT" -lt 1 ]] || [[ "$NEW_PORT" -gt 65535 ]]; then
        echo -e "${RED}❌ 输入无效${NC}"; return
    fi

    # 更新防火墙
    manage_firewall "del" "$OLD_PORT"
    manage_firewall "add" "$NEW_PORT"

    tmp=$(mktemp)
    jq --argjson p "$NEW_PORT" '.inbounds[0].port = $p' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
    echo "$NEW_PORT" > "$PORT_FILE"
    
    restart_service
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}"
    show_info
}

# 修改域名/伪装目标
change_domain() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}❌ 请先安装 VLESS-REALITY${NC}"; return
    fi
    prepare_env
    
    local OLD_DEST=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
    local OLD_DOMAIN=""
    [[ -f "$XRAY_CONFIG_DIR/domain.txt" ]] && OLD_DOMAIN=$(cat "$XRAY_CONFIG_DIR/domain.txt")
    
    echo -e "当前伪装目标域名 (DEST/SNI): ${YELLOW}$OLD_DEST${NC}"
    [[ -n "$OLD_DOMAIN" ]] && echo -e "当前绑定域名: ${YELLOW}$OLD_DOMAIN${NC}"
    
    echo -e "${CYAN}请选择操作:${NC}"
    echo -e "1. 仅修改伪装目标域名 (DEST/SNI)"
    echo -e "2. 修改绑定域名"
    read -p "请输入选择 [1-2] (回车取消): " DOMAIN_OPTS
    
    if [[ "$DOMAIN_OPTS" == "1" ]]; then
        read -p "请输入新的伪装目标域名 (回车取消): " NEW_DEST
        [[ -z "$NEW_DEST" ]] && return
        
        local tmp=$(mktemp)
        jq --arg dest "$NEW_DEST" '.inbounds[0].streamSettings.realitySettings.serverNames = [$dest] | .inbounds[0].streamSettings.realitySettings.dest = ($dest + ":443")' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
        
        restart_service
        echo -e "${GREEN}✅ 伪装目标域名已更改为 $NEW_DEST${NC}"
        show_info
    elif [[ "$DOMAIN_OPTS" == "2" ]]; then
        read -p "请输入新的绑定域名 (回车清空绑定域名): " NEW_DOMAIN
        if [[ -z "$NEW_DOMAIN" ]]; then
            rm -f "$XRAY_CONFIG_DIR/domain.txt"
        else
            echo "$NEW_DOMAIN" > "$XRAY_CONFIG_DIR/domain.txt"
        fi
        echo -e "${GREEN}✅ 绑定域名已更新${NC}"
        show_info
    fi
}

# 安装 REALITY
install_reality() {
    prepare_env
    download_xray
    
    mkdir -p "$XRAY_CONFIG_DIR"
    
    local key_pair priv_key pub_key SID DEST_DOMAIN
    # 生成密钥对
    key_pair=$("$XRAY_BIN" x25519 2>&1)
    priv_key=$(echo "${key_pair}" | grep -i 'Private' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    pub_key=$(echo "${key_pair}" | grep -i 'Public' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    
    # 兼容性处理
    if [[ -z "$priv_key" ]]; then
        priv_key=$(echo "${key_pair}" | awk '/Private/{print $2}' | tr -d '[:space:]')
        pub_key=$(echo "${key_pair}" | awk '/Public/{print $2}' | tr -d '[:space:]')
    fi

    echo "$priv_key" > "$XRAY_PRIV_KEY"
    echo "$pub_key" > "$XRAY_PUB_KEY"

    read -p "请输入监听端口 (回车10000-65535随机): " PORT
    [[ -z "$PORT" ]] && PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
        PORT=$(( ( RANDOM % 55535 ) + 10000 ))
        echo -e "${YELLOW}输入无效，已分配随机端口: $PORT${NC}"
    fi

    echo "$PORT" > "$PORT_FILE"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SID=$(openssl rand -hex 8)

    read -p "请输入连接域名 (可选, 直接回车使用 IP): " DOMAIN
    if [[ -n "$DOMAIN" ]]; then
        echo "$DOMAIN" > "$XRAY_CONFIG_DIR/domain.txt"
    else
        rm -f "$XRAY_CONFIG_DIR/domain.txt"
    fi

    # 伪装目标
    read -p "请输入伪装目标域名 (回车默认 www.shopify.com): " DEST_DOMAIN
    [[ -z "$DEST_DOMAIN" ]] && DEST_DOMAIN="www.shopify.com"

    # 生成配置
    jq -n \
        --argjson port "$PORT" --arg uuid "$UUID" \
        --arg priv "$priv_key" --arg sid "$SID" \
        --arg dest "$DEST_DOMAIN" \
        '
        {
          "log": {"loglevel": "warning"},
          "inbounds": [{
            "port": $port,
            "protocol": "vless",
            "settings": {
              "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
              "decryption": "none"
            },
            "streamSettings": {
              "network": "tcp",
              "security": "reality",
              "realitySettings": {
                "show": false,
                "dest": ($dest + ":443"),
                "xver": 0,
                "serverNames": [$dest],
                "privateKey": $priv,
                "shortIds": [$sid]
              }
            }
          }],
          "outbounds": [{"protocol": "freedom", "tag": "direct"}]
        }
        ' > "$XRAY_CONFIG"

    # 配置防火墙
    manage_firewall "add" "$PORT"

    # 服务部署
    if [[ "$OS" = "alpine" ]]; then
        cat <<EOF > /etc/init.d/xray
#!/sbin/openrc-run
description="Xray Service"
command="$XRAY_BIN"
command_args="run -config $XRAY_CONFIG"
command_background="yes"
pidfile="/run/xray.pid"
supervisor="supervise-daemon"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default >/dev/null 2>&1
    else
        cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=root
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
    fi
    
    # 配置快捷命令
    local SCRIPT_PATH=$(readlink -f "$0")
    if [[ "$SCRIPT_PATH" != "/usr/local/bin/real" ]]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/real
        chmod +x /usr/local/bin/real
    fi

    restart_service
    echo -e "${GREEN}✅ VLESS-REALITY 安装完成${NC}"
    echo -e "${CYAN}💡 快捷键已创建，下次可直接输入 ${YELLOW}real${CYAN} 进入此菜单${NC}"
    show_info
}

# 卸载
uninstall_reality() {
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    
    # 清理快捷命令
    rm -f /usr/local/bin/real
    # 清理防火墙
    if [[ -f "$PORT_FILE" ]]; then
        local OLD_PORT
        OLD_PORT=$(cat "$PORT_FILE")
        manage_firewall "del" "$OLD_PORT"
    fi

    if [[ "$OS" = "alpine" ]]; then
        rc-service xray stop || true
        rc-update del xray || true
        rm -f /etc/init.d/xray
    else
        systemctl stop xray || true
        systemctl disable xray || true
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload
    fi
    rm -rf "$XRAY_BIN" "$XRAY_CONFIG_DIR"
    echo -e "${GREEN}✅ 卸载成功${NC}"
}

# 更新脚本
update_script() {
    echo -e "${YELLOW}▶ 正在从 GitHub 检查更新...${NC}"
    local url="https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/reality.sh"
    local tmp_file="/tmp/reality_update.sh"
    
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

# 获取 IP 用于菜单显示
echo -e "${YELLOW}正在检测系统环境...${NC}"
IP4_MAIN=$(curl -s4 --connect-timeout 2 ip.sb || curl -s4 --connect-timeout 2 icanhazip.com || echo "未检测到")
IP6_MAIN=$(curl -s6 --connect-timeout 2 ip.sb || curl -s6 --connect-timeout 2 icanhazip.com || echo "未检测到")

while true; do
# 状态检测逻辑
if [[ "$OS" = "alpine" ]]; then
    if rc-service xray status 2>/dev/null | grep -q "started"; then
        STATUS="${GREEN}正在运行${NC}"
    else
        STATUS="${RED}未安装或未运行${NC}"
    fi
else
    if systemctl is-active --quiet xray 2>/dev/null; then
        STATUS="${GREEN}正在运行${NC}"
    else
        STATUS="${RED}未安装或未运行${NC}"
    fi
fi

# 菜单
clear
echo -e "${GREEN}===============================================${NC}"
echo -e "  VLESS-REALITY 一键管理脚本"
echo -e "  当前系统: ${CYAN}$OS${NC}"
echo -e "  IPv4 地址: ${YELLOW}$IP4_MAIN${NC}"
echo -e "  IPv6 地址: ${YELLOW}$IP6_MAIN${NC}"
echo -e "  Xray 状态： $STATUS"
echo -e "${GREEN}===============================================${NC}"
echo -e "  ${CYAN}[1]${NC}  安装 VLESS-REALITY"
echo -e "  ${CYAN}[2]${NC}  查看配置节点链接"
echo -e "  ${CYAN}[3]${NC}  更改监听端口"
echo -e "  ${CYAN}[4]${NC}  修改伪装域名/绑定域名"
echo -e "  ${CYAN}[5]${NC}  查看实时日志"
echo -e "  ${CYAN}[6]${NC}  优化 BBR 加速"
echo -e "  ${CYAN}[7]${NC}  重启服务"
echo -e "  ${CYAN}[8]${NC}  卸载 VLESS-REALITY"
echo -e "  ${CYAN}[9]${NC}  更新管理脚本"
echo -e "  ${CYAN}[0]${NC}  退出脚本"
echo -e "${GREEN}===============================================${NC}"
echo -ne "请输入数字选择 [0-9]: "
read choice

case $choice in
        1)
            install_reality
            ;;
        2)
            show_info
            ;;
        3)
            change_port
            ;;
        4)
            change_domain
            ;;
        5)
            view_logs
            ;;
        6)
            optimize_bbr
            ;;
        7)
            restart_service && echo -e "${GREEN}服务已重启${NC}"
            ;;
        8)
            uninstall_reality
            ;;
        9)
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
