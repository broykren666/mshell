#!/bin/bash
set -e

# === 自定义配置 (可在此修改) ===
PORT=${1:-40443}          # 支持运行时传参，默认 40443
SNI="www.bing.com"        # 伪装域名
WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
# ============================

# 1. 安装基础依赖
echo "▶ 正在安装必要依赖..."
apk add --no-cache wget curl git openssh openssl openrc jq

# 2. 架构自动检测
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) FILE="hysteria-linux-amd64" ;;
    aarch64|arm64) FILE="hysteria-linux-arm64" ;;
    armv7l) FILE="hysteria-linux-arm" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

# 3. 密码生成
generate_random_password() {
    openssl rand -base64 16
}
GENPASS=$(generate_random_password)

# 4. 下载 Hysteria2
echo "▶ 正在下载 Hysteria2 ($ARCH)..."
wget -O "$BIN" "https://download.hysteria.network/app/latest/$FILE" --no-check-certificate
chmod +x "$BIN"

# 5. 创建配置目录与生成证书
mkdir -p "$WORKDIR"
echo "▶ 正在生成自签名 ECC 证书..."
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$WORKDIR/server.key" \
    -out "$WORKDIR/server.crt" \
    -subj "/CN=$SNI" -days 3650 2>/dev/null

# 6. 写入 YAML 配置文件
cat << EOF > "$WORKDIR/config.yaml"
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

# 7. 配置 OpenRC 自启动服务
cat << EOF > /etc/init.d/hysteria
#!/sbin/openrc-run
name="hysteria"
description="Hysteria2 Server"
command="$BIN"
command_args="server --config $WORKDIR/config.yaml"
pidfile="/run/\${name}.pid"
command_background="yes"
supervisor="supervise-daemon"

depend() {
    need net
}
EOF

chmod +x /etc/init.d/hysteria

# 8. 启动服务
echo "▶ 正在启动服务..."
rc-update add hysteria default
service hysteria restart || rc-service hysteria start

# 9. 输出配置信息
echo "------------------------------------------------------------------------"
echo "Hysteria2 Alpine 专版安装完成！"
echo "默认端口： $PORT"
echo "连接密码： $GENPASS"
echo "伪装 SNI： $SNI"
echo "配置文件： $WORKDIR/config.yaml"
echo ""
echo "常用命令："
echo "- 状态: service hysteria status"
echo "- 重启: service hysteria restart"
echo "- 停止: service hysteria stop"
echo "------------------------------------------------------------------------"