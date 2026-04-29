# MShell 一键管理脚本说明文档

这是一个专为 Linux 服务器设计的自动化部署与管理工具集，支持 Hysteria2 和 TUIC 协议。脚本针对安全、稳定性和易用性进行了深度优化。

---

## 🔗 项目来源

* **原项目地址**: [a88wyzz/Alpine-Debian-Ubuntu-Hy2](https://github.com/a88wyzz/Alpine-Debian-Ubuntu-Hy2)

---

## 🚀 快速开始

### 1. Hysteria2 (Hy2)
在你的服务器上执行以下命令进行安装：
```bash
wget -O hy2.sh https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/hy2.sh && chmod +x hy2.sh && ./hy2.sh
```
*注：Alpine 用户如果提示命令不存在，请先执行 `apk add --no-cache wget bash`*

### 2. TUIC
在你的服务器上执行以下命令进行安装：
```bash
wget -O tuic.sh https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/tuic.sh && chmod +x tuic.sh && ./tuic.sh
```
*注：Alpine 用户如果提示命令不存在，请先执行 `apk add --no-cache wget bash`*

---

## ✨ 优化版核心特性

- **安全强密码**：默认生成 24 位强随机密码（12字节十六进制），支持手动自定义，极大增强防爆破能力。
- **防火墙深度同步**：同时支持 `UFW` 和 `iptables`。在**安装**、**更改端口**或**卸载**时，脚本会自动添加或清理冗余规则，保持服务器网络整洁。
- **智能依赖预检**：自动补齐 `jq`, `curl`, `openssl`, `ca-certificates` 等工具，避免在纯净系统上运行报错。
- **快捷键支持**：自动创建全局命令（`hy2` 或 `tuic`），安装一次后，随时随地一键管理。
- **高可用保活**：
  - **Debian/Ubuntu**: 使用 `systemd` 并配置 `Restart=always` 及高并发文件限制优化。
  - **Alpine**: 使用 `supervise-daemon` 实现进程监控与自动重启。
- **多架构支持**：适配 x86_64, ARM64 (aarch64)。Hy2 额外支持 ARMv7 (32位)。

---

## 🛠 菜单选项说明

1. **安装协议**：开始全新安装。流程中可自定义端口和密码（回车即使用推荐的安全值）。
2. **查看配置节点链接**：显示 IP、端口、密码/UUID，并生成可直接导入客户端的节点链接。
3. **更改监听端口**：修改服务端口，并同步更新防火墙策略。
4. **重启服务**：手动重启服务端以应用更改或清理连接。
5. **卸载协议**：彻底清理服务、配置、防火墙规则及快捷键。

---

## 📋 系统要求

- **操作系统**：Debian 11+, Ubuntu 20.04+, Alpine Linux。
- **权限**：必须以 `root` 用户运行。
- **网络**：建议使用 10000 以上的高位端口以规避部分运营商的 UDP 限制。

---

**由 Gemini CLI 协助进行代码审查与功能增强。**
