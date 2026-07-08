# 安全说明

## 敏感文件

不要公开真实服务器上生成的文件，尤其是：

- `/opt/sing-box/config/config.json`
- `/opt/sing-box/nodes.txt`
- `/opt/sing-box/config/cert-*`
- 导出的客户端链接、UUID、密码、私钥或证书

节点链接通常包含连接凭据，请像对待密码一样保存。

## 提交问题时如何打码

反馈问题时请隐藏：

- 服务器 IP 和域名
- UUID 和密码
- Reality 公钥、私钥和 short ID
- Hysteria2 或 AnyTLS 完整链接
- 证书内容和私钥

通常保留端口、协议名称和已打码日志，就足够排查基础问题。

## 运行风险

脚本可能会安装 Docker、在 `/opt/sing-box` 下创建文件、启动或重启容器、开放协议监听端口，并在启用 BBR 时修改 Linux 内核参数。

在生产服务器上运行前，请先阅读脚本内容。请只在你有权管理、且允许运行相关网络服务的系统上使用。
