# MShell 一键管理脚本说明文档

这是一个专为 Linux 服务器设计的自动化部署与管理工具集，支持 Hysteria2、TUIC 和 VLESS-Reality 协议。脚本针对安全、稳定性和易用性进行了深度优化。

---

## 🔗 项目来源

* **原项目**: [a88wyzz/Alpine-Debian-Ubuntu-Hy2](https://github.com/a88wyzz/Alpine-Debian-Ubuntu-Hy2)

---

## 🚀 快速开始

> 注：Alpine 用户如果提示命令不存在，请先执行 `apk add --no-cache wget bash`

### 1. Hysteria2 (Hy2)

```bash
wget -O hy2.sh https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/hy2.sh && chmod +x hy2.sh && ./hy2.sh
```

### 2. TUIC

```bash
wget -O tuic.sh https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/tuic.sh && chmod +x tuic.sh && ./tuic.sh
```

### 3. VLESS-Reality

```bash
wget -O reality.sh https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/reality.sh && chmod +x reality.sh && ./reality.sh
```
*注：Alpine 用户如果提示命令不存在，请先执行 `apk add --no-cache wget bash`*
*安装后可直接输入 `real` 进入管理菜单。*

---

## ✨ 优化版核心特性

- **安全强密码/密钥**：支持手动自定义或自动生成强随机密码/UUID/密钥对，极大增强安全性。
- **防火墙深度同步**：同时支持 `UFW` 和 `iptables`。在**安装**、**更改端口**或**卸载**时，脚本会自动添加或清理冗余规则（Hy2/TUIC 为 UDP，Reality 为 TCP）。
- **智能依赖预检**：自动补齐 `jq`, `curl`, `openssl`, `unzip`, `ca-certificates` 等工具，确保在各平台上稳健运行。
- **快捷键支持**：自动创建全局命令（`hy2`, `tuic`, `real`），安装后即可通过短命令一键唤起管理菜单。
- **高可用保活**：
  - **Debian/Ubuntu**: 使用 `systemd` 并配置 `Restart=always` 监控。
  - **Alpine**: 使用 `supervise-daemon` 实现进程级保活。
- **多架构支持**：完美适配 x86_64, ARM64 (aarch64)。

---

## 🛠 菜单选项说明

1. **安装协议**：自动化下载内核、生成配置及自签证书。
2. **查看配置节点链接**：显示详细配置信息并生成通用节点链接。
3. **更改监听端口**：一键修改服务端口并同步防火墙规则。
4. **重启服务**：手动重启服务端。
5. **卸载协议**：彻底清理服务、配置、防火墙规则及快捷键。

---

## 📋 系统要求

- **操作系统**：Debian 11+, Ubuntu 20.04+, Alpine Linux。
- **权限**：必须以 `root` 用户运行。

---

**由 Gemini CLI 协助进行代码审查与功能增强。**
