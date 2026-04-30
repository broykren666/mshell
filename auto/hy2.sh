#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
SERVER_NAME="www.bing.com"
TAG="HY2"
WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
CONF="$WORKDIR/config.json"
PORT_FILE="$WORKDIR/port.txt"
PASS_FILE="$WORKDIR/password.txt"
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

    if [[ "${#missing[@]}" -ne 0 ]]; then
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
    local action="$1"
    local port="$2"
    [[ -z "$port" ]] && return

    if command -v ufw >/dev/null 2>&1; then
        if [[ "$action" = "add" ]]; then
            ufw allow "$port"/udp >/dev/null 2>&1
        else
            ufw delete allow "$port"/udp >/dev/null 2>&1
        fi
    elif command -v iptables >/dev/null 2>&1; then
        if [[ "$action" = "add" ]]; then
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
        else
            iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
        fi
    fi
}

# 重启服务
restart_service() {
    if [[ "$OS" = "alpine" ]]; then
        rc-service hysteria restart
    else
        systemctl restart hysteria
    fi
}

# 查看日志
view_logs() {
    echo -e "${YELLOW}▶ 正在查看实时日志 (按 Ctrl+C 退出)...${NC}"
    if [[ "$OS" = "alpine" ]]; then
        if [[ -f /var/log/hysteria.log ]]; then
            tail -f /var/log/hysteria.log
        else
            tail -f /var/log/messages | grep --line-buffered hysteria || echo -e "${RED}无法读取日志${NC}"
        fi
    else
        journalctl -u hysteria -f
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

# 获取并显示信息
show_info() {
    if [[ ! -f "$CONF" ]]; then
        echo -e "${RED}❌ 配置文件不存在${NC}"
        return
    fi

    prepare_env
    local PORT PASSWORD DOMAIN CERT_PATH INSECURE IP4 IP6
    
    # 从配置文件读取信息
    PORT=$(jq -r '.listen' "$CONF" | grep -o '[0-9]\+')
    PASSWORD=$(jq -r '.auth.password' "$CONF")
    local SNI=$(jq -r '.masquerade.proxy.url' "$CONF" | sed 's/https:\/\///')
    
    if [[ -f "$WORKDIR/domain.txt" ]]; then
        DOMAIN=$(cat "$WORKDIR/domain.txt")
    fi

    # 检测是否使用自签证书 (简单判断: 如果证书在 WORKDIR 下则视为自签)
    CERT_PATH=$(jq -r '.tls.cert' "$CONF")
    INSECURE="0"
    [[ "$CERT_PATH" == "$WORKDIR/"* ]] && INSECURE="1"

    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 icanhazip.com || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 icanhazip.com || echo "")

    echo -e "\n${GREEN}========== Hysteria2 配置信息 ==========${NC}"
    [[ -n "$DOMAIN" ]] && echo -e "🌐 绑定域名: ${YELLOW}$DOMAIN${NC}"
    echo -e "🎭 伪装域名: ${YELLOW}$SNI${NC}"
    echo -e "📌 IPv4地址: ${YELLOW}$IP4${NC}"
    echo -e "📌 IPv6地址: ${YELLOW}$IP6${NC}"
    echo -e "🎲 监听端口: ${YELLOW}$PORT${NC}"
    echo -e "🔐 认证密码: ${YELLOW}$PASSWORD${NC}"
    
    local ADDR_V4="${DOMAIN:-$IP4}"
    local ADDR_V6="${DOMAIN:-$IP6}"
    # 如果是 IPv6 且不是域名，需要加方括号
    [[ -z "$DOMAIN" && -n "$IP6" ]] && ADDR_V6="[$IP6]"

    [[ -n "$IP4" || -n "$DOMAIN" ]] && echo -e "\n${GREEN}📎 节点链接 (IPv4/Domain):${NC}\n${YELLOW}hy2://$PASSWORD@$ADDR_V4:$PORT/?sni=$SNI&alpn=h3&insecure=$INSECURE#${TAG}_V4${NC}"
    [[ -n "$IP6" && -z "$DOMAIN" ]] && echo -e "\n${GREEN}📎 节点链接 (IPv6):${NC}\n${YELLOW}hy2://$PASSWORD@$ADDR_V6:$PORT/?sni=$SNI&alpn=h3&insecure=$INSECURE#${TAG}_V6${NC}"
    
    if [[ -z "$IP4" && -z "$IP6" && -z "$DOMAIN" ]]; then
        echo -e "${RED}❌ 无法检测到公网 IP 或域名${NC}"
    fi
    echo -e "${GREEN}===============================================${NC}\n"
}

# 更改端口
change_port() {
    if [[ ! -f "$CONF" ]]; then
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return
    fi
    prepare_env
    local OLD_PORT NEW_PORT
    OLD_PORT=$(jq -r '.listen' "$CONF" | sed 's/://g')
    echo -e "当前端口为: ${YELLOW}$OLD_PORT${NC}"
    read -p "请输入新端口 (回车10000-65535随机): " NEW_PORT
    
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [[ "$NEW_PORT" -lt 1 ]] || [[ "$NEW_PORT" -gt 65535 ]]; then
        echo -e "${RED}❌ 输入无效${NC}"; return
    fi

    # 更新防火墙
    manage_firewall "del" "$OLD_PORT"
    manage_firewall "add" "$NEW_PORT"

    # 使用 jq 修改并回写
    jq --arg p ":$NEW_PORT" '.listen = $p' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    echo "$NEW_PORT" > "$PORT_FILE"
    
    restart_service
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}"
    show_info
}

# 更改伪装域名/绑定域名
change_domain() {
    if [[ ! -f "$CONF" ]]; then
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return
    fi
    prepare_env
    
    local OLD_SNI=$(jq -r '.masquerade.proxy.url' "$CONF" | sed 's/https:\/\///')
    local OLD_DOMAIN=""
    [[ -f "$WORKDIR/domain.txt" ]] && OLD_DOMAIN=$(cat "$WORKDIR/domain.txt")
    
    echo -e "当前伪装域名 (SNI): ${YELLOW}$OLD_SNI${NC}"
    [[ -n "$OLD_DOMAIN" ]] && echo -e "当前绑定域名: ${YELLOW}$OLD_DOMAIN${NC}"
    
    echo -e "${CYAN}请选择操作:${NC}"
    echo -e "1. 仅修改伪装域名 (SNI)"
    echo -e "2. 修改绑定域名和自签证书"
    read -p "请输入选择 [1-2] (回车取消): " DOMAIN_OPTS
    
    if [[ "$DOMAIN_OPTS" == "1" ]]; then
        read -p "请输入新的伪装域名 (回车取消): " NEW_SNI
        [[ -z "$NEW_SNI" ]] && return
        
        jq --arg sni "https://$NEW_SNI" '.masquerade.proxy.url = $sni' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
        
        # 判断如果是自签证书，可能需要重新生成
        local CERT_PATH=$(jq -r '.tls.cert' "$CONF")
        if [[ "$CERT_PATH" == "$WORKDIR/"* ]]; then
            echo -e "${YELLOW}▶ 更新自签证书以匹配新 SNI...${NC}"
            openssl req -x509 -nodes -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=$NEW_SNI" 2>/dev/null
        fi
        
        restart_service
        echo -e "${GREEN}✅ 伪装域名已更改为 $NEW_SNI${NC}"
        show_info
    elif [[ "$DOMAIN_OPTS" == "2" ]]; then
        read -p "请输入新的绑定域名 (回车清空绑定域名): " NEW_DOMAIN
        if [[ -z "$NEW_DOMAIN" ]]; then
            rm -f "$WORKDIR/domain.txt"
        else
            echo "$NEW_DOMAIN" > "$WORKDIR/domain.txt"
            # 同样更新 SNI 并生成新证书
            jq --arg sni "https://$NEW_DOMAIN" '.masquerade.proxy.url = $sni' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
            
            local CERT_PATH=$(jq -r '.tls.cert' "$CONF")
            if [[ "$CERT_PATH" == "$WORKDIR/"* ]]; then
                echo -e "${YELLOW}▶ 生成对应新域名的自签证书...${NC}"
                openssl req -x509 -nodes -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=$NEW_DOMAIN" 2>/dev/null
            fi
        fi
        restart_service
        echo -e "${GREEN}✅ 域名配置已更新${NC}"
        show_info
    fi
}

# 安装
install_hy2() {
    prepare_env
    
    mkdir -p "$WORKDIR"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FILE="hysteria-linux-amd64" ;;
        aarch64|arm64) FILE="hysteria-linux-arm64" ;;
        armv7l|armhf) FILE="hysteria-linux-arm" ;;
        *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac

    echo -e "${YELLOW}▶ 下载 Hysteria2 ($ARCH)...${NC}"
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/$FILE"
    chmod +x "$BIN"

    read -p "请输入认证密码 (回车生成随机强密码): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 12)
    echo -e "${YELLOW}🔑 使用密码: ${PASSWORD}${NC}"
    
    read -p "请输入监听端口 (回车10000-65535随机): " PORT
    [[ -z "$PORT" ]] && PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
        PORT=$(( ( RANDOM % 55535 ) + 10000 ))
        echo -e "${YELLOW}输入无效，已分配随机端口: $PORT${NC}"
    fi

    echo "$PASSWORD" > "$PASS_FILE"
    echo "$PORT" > "$PORT_FILE"

    read -p "请输入绑定的域名 (可选, 直接回车使用 IP): " DOMAIN
    read -p "请输入伪装域名 (回车默认 www.bing.com): " CUSTOM_SNI
    [[ -z "$CUSTOM_SNI" ]] && CUSTOM_SNI="$SERVER_NAME"

    local USE_CUSTOM_CERT="n"
    local CERT_FILE_PATH="$WORKDIR/cert.pem"
    local KEY_FILE_PATH="$WORKDIR/key.pem"

    if [[ -n "$DOMAIN" ]]; then
        echo "$DOMAIN" > "$WORKDIR/domain.txt"
        read -p "是否使用自己的 SSL 证书? (y/n, 默认生成自签证书): " USE_CUSTOM_CERT
        if [[ "$USE_CUSTOM_CERT" == "y" || "$USE_CUSTOM_CERT" == "Y" ]]; then
            read -p "请输入证书文件路径 (.crt/.pem): " CUSTOM_CERT
            read -p "请输入私钥文件路径 (.key): " CUSTOM_KEY
            if [[ -f "$CUSTOM_CERT" && -f "$CUSTOM_KEY" ]]; then
                CERT_FILE_PATH="$CUSTOM_CERT"
                KEY_FILE_PATH="$CUSTOM_KEY"
            else
                echo -e "${RED}❌ 证书文件不存在，将降级为生成自签证书${NC}"
                USE_CUSTOM_CERT="n"
            fi
        fi
    else
        rm -f "$WORKDIR/domain.txt"
    fi

    if [[ "$USE_CUSTOM_CERT" != "y" && "$USE_CUSTOM_CERT" != "Y" ]]; then
        echo -e "${YELLOW}▶ 生成自签证书...${NC}"
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=${DOMAIN:-$CUSTOM_SNI}" 2>/dev/null
        CERT_FILE_PATH="$WORKDIR/cert.pem"
        KEY_FILE_PATH="$WORKDIR/key.pem"
    fi

    # 使用 jq 构建初始 JSON 配置
    jq -n \
        --arg port ":$PORT" \
        --arg cert "$CERT_FILE_PATH" \
        --arg key "$KEY_FILE_PATH" \
        --arg pass "$PASSWORD" \
        --arg sni "${DOMAIN:-$CUSTOM_SNI}" \
        '{
            "listen": $port,
            "tls": {
                "cert": $cert,
                "key": $key,
                "alpn": ["h3"]
            },
            "auth": {
                "type": "password",
                "password": $pass
            },
            "masquerade": {
                "type": "proxy",
                "proxy": {
                    "url": ("https://" + $sni),
                    "rewriteHost": true
                }
            }
        }' > "$CONF"

    # 配置防火墙
    manage_firewall "add" "$PORT"

    # 服务部署
    if [[ "$OS" = "alpine" ]]; then
        cat > /etc/init.d/hysteria <<EOF
#!/sbin/openrc-run
name="hysteria"
command="$BIN"
command_args="server -c $CONF"
command_background=true
pidfile="/run/hysteria.pid"
supervisor="supervise-daemon"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
EOF
        chmod +x /etc/init.d/hysteria
        rc-update add hysteria default
    else
        cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target
[Service]
ExecStart=$BIN server -c $CONF
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria
    fi
    
    # 配置快捷命令
    local SCRIPT_PATH=$(readlink -f "$0")
    if [[ "$SCRIPT_PATH" != "/usr/local/bin/hy2" ]]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/hy2
        chmod +x /usr/local/bin/hy2
    fi

    restart_service
    echo -e "${GREEN}✅ Hysteria2 安装完成 ${NC}"
    echo -e "${CYAN}💡 快捷键已创建，下次可直接输入 ${YELLOW}hy2${CYAN} 进入此菜单${NC}"
    show_info
    }

# 卸载
uninstall_hy2() {
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    
    # 清理快捷命令
    rm -f /usr/local/bin/hy2
    # 清理防火墙
    if [[ -f "$PORT_FILE" ]]; then
        local OLD_PORT
        OLD_PORT=$(cat "$PORT_FILE")
        manage_firewall "del" "$OLD_PORT"
    fi

    if [[ "$OS" = "alpine" ]]; then
        rc-service hysteria stop || true
        rc-update del hysteria || true
        rm -f /etc/init.d/hysteria
    else
        systemctl stop hysteria || true
        systemctl disable hysteria || true
        rm -f /etc/systemd/system/hysteria.service
        systemctl daemon-reload
    fi
    rm -rf "$WORKDIR"
    rm -f "$BIN"
    echo -e "${GREEN}✅ 卸载成功${NC}"
}

# 更新脚本
update_script() {
    echo -e "${YELLOW}▶ 正在从 GitHub 检查更新...${NC}"
    local url="https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/hy2.sh"
    local tmp_file="/tmp/hy2_update.sh"
    
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
    if rc-service hysteria status 2>/dev/null | grep -q "started"; then
        STATUS="${GREEN}正在运行${NC}"
    else
        STATUS="${RED}未安装或未运行${NC}"
    fi
else
    if systemctl is-active --quiet hysteria 2>/dev/null; then
        STATUS="${GREEN}正在运行${NC}"
    else
        STATUS="${RED}未安装或未运行${NC}"
    fi
fi

# 菜单
clear
echo -e "${GREEN}===============================================${NC}"
echo -e "  Hysteria2 一键管理脚本"
echo -e "  当前系统: ${CYAN}$OS${NC}"
echo -e "  IPv4 地址: ${YELLOW}$IP4_MAIN${NC}"
echo -e "  IPv6 地址: ${YELLOW}$IP6_MAIN${NC}"
echo -e "  Hy2 状态： $STATUS"
echo -e "${GREEN}===============================================${NC}"
echo -e "  ${CYAN}[1]${NC}  安装 Hysteria2"
echo -e "  ${CYAN}[2]${NC}  查看配置节点链接"
echo -e "  ${CYAN}[3]${NC}  更改监听端口"
echo -e "  ${CYAN}[4]${NC}  修改伪装域名/绑定域名"
echo -e "  ${CYAN}[5]${NC}  查看实时日志"
echo -e "  ${CYAN}[6]${NC}  优化 BBR 加速"
echo -e "  ${CYAN}[7]${NC}  重启服务"
echo -e "  ${CYAN}[8]${NC}  卸载 Hysteria2"
echo -e "  ${CYAN}[9]${NC}  更新管理脚本"
echo -e "  ${CYAN}[0]${NC}  退出脚本"
echo -e "${GREEN}===============================================${NC}"
echo -ne "请输入数字选择 [0-9]: "
read choice

case $choice in
        1)
            install_hy2
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
            uninstall_hy2
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
