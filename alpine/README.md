# Hysteria2 Alpine 专版管理脚本

这是一个专门为 **Alpine Linux** 优化的 Hysteria2 一键管理脚本，支持交互式菜单、多架构自适应、快捷命令以及自动生成节点链接。

> [!NOTE]
> 本脚本参考并改进自原项目：[alpine-hysteria2](https://github.com/zrlhk/alpine-hysteria2)

---

## 🚀 一键安装命令

在你的 Alpine 服务器终端执行以下命令：

```bash
wget -qO hy2.sh https://raw.githubusercontent.com/broykren666/mshell/refs/heads/main/alpine/hy2.sh && chmod +x hy2.sh && ./hy2.sh
```

---

## ✨ 脚本特性

- **交互式菜单**：支持安装、查看、重启、卸载等全生命周期管理。
- **快捷命令**：安装成功后，直接输入 `hy2` 即可唤出菜单。
- **多架构支持**：自动识别 x86_64、ARM64、ARMv7 等架构并匹配二进制文件。
- **自动生成链接**：安装完成后自动检测公网 IP 并生成 `hy2://` 节点链接。
- **高性能配置**：默认使用 ECC (prime256v1) 证书，TLS 握手速度更快。
- **OpenRC 集成**：完美契合 Alpine 的服务管理系统，支持自启动和崩溃自动重启。

## 🛠️ 管理说明

安装完成后，你可以通过以下方式管理服务：

- **打开菜单**: `hy2`
- **查看状态**: `service hysteria status`
- **重启服务**: `service hysteria restart`
- **停止服务**: `service hysteria stop`

## 📄 配置文件路径

- **二进制文件**: `/usr/local/bin/hysteria`
- **配置文件**: `/etc/hysteria/config.yaml`
- **证书文件**: `/etc/hysteria/server.crt` & `server.key`
