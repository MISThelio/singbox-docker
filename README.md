# singbox-docker

Docker 版 sing-box 多入站管理脚本。核心运行使用 SagerNet 官方 sing-box 镜像，交互管理思路参考 233boy/sing-box 的一键脚本体验。

## 功能

- 初始化 Docker / Docker Compose 运行环境
- 使用固定版本镜像，默认 `ghcr.io/sagernet/sing-box:v1.13.14`
- 添加 VLESS Reality 入站
- 添加 Hysteria2 入站，支持自签证书或 Let's Encrypt 真实证书
- 添加 AnyTLS 入站，支持自签证书或 Let's Encrypt 真实证书
- 添加 Door 端口转发入站
- 删除入站、查看配置、检查配置、备份恢复
- 查看 Hysteria2 自签证书 `pinSHA256` hex 链接
- 查看并启用宿主机 BBR
- 支持通过 `SING_BOX_IMAGE` 或 `SING_BOX_VERSION` 覆盖镜像

## 快速使用

```bash
cd singbox-docker
chmod +x install.sh singbox-docker.sh
sudo ./install.sh
```

安装后可使用：

```bash
sudo sb
```

远程安装时需要先提供脚本地址：

```bash
sudo SCRIPT_URL=https://raw.githubusercontent.com/MISThelio/singbox-docker/main/singbox-docker.sh ./install.sh
```

## 目录

默认运行目录是 `/opt/sing-box`：

- `/opt/sing-box/config/config.json`：sing-box 配置
- `/opt/sing-box/data`：运行数据
- `/opt/sing-box/nodes.txt`：节点信息
- `/opt/sing-box/backup`：配置备份
- `/opt/sing-box/docker-compose.yml`：Compose 文件

## 指定版本

```bash
sudo SING_BOX_VERSION=v1.13.14 ./singbox-docker.sh
```

或指定完整镜像：

```bash
sudo SING_BOX_IMAGE=ghcr.io/sagernet/sing-box:v1.13.14 ./singbox-docker.sh
```

## 从源码构建镜像

如需基于 SagerNet/sing-box 源码构建本地镜像：

```bash
docker build --build-arg SING_BOX_VERSION=v1.13.14 -t local/sing-box:v1.13.14 .
sudo SING_BOX_IMAGE=local/sing-box:v1.13.14 ./singbox-docker.sh
```

## Hysteria2 证书

添加 Hysteria2 时可以选择两种证书模式：

- 自签证书：快速创建，客户端需要开启 insecure，或使用菜单生成的 `pinSHA256` hex 链接。
- Let's Encrypt 真实证书：推荐，需要域名已解析到服务器，并放行 `80/tcp` 用于 HTTP-01 验证。

真实证书模式会把证书复制到 `/opt/sing-box/config/cert-标签/`，并安装 certbot 续期 hook，续期后自动重启 sing-box 容器。

## AnyTLS

AnyTLS 从 sing-box `1.12.0` 开始支持。本脚本会生成 AnyTLS 入站配置，并在菜单中显示 AnyTLS URI 和 sing-box 客户端出站 JSON。

不同客户端对 AnyTLS URI 的支持程度不一致；如果导入失败，请使用菜单里的 sing-box 客户端出站配置手动添加。

## 注意

- VLESS Reality 通常只需要放行 TCP 端口。
- Hysteria2 需要放行 UDP 端口，脚本也会提示 TCP/UDP 安全组。
- AnyTLS 需要放行 TCP 端口。
- Hysteria2 如果选择 Let's Encrypt 真实证书，请额外在系统防火墙和云安全组放行 `80/tcp`，并确保 80 端口没有被其他服务占用。
- Hysteria2 默认使用自签证书；部分 Xray-core 新版客户端已移除 `allowInsecure`，请优先使用菜单里的 `查看 Hysteria2 链接/证书 pin` 获取十六进制 `pinSHA256` 链接，或在客户端手动填写 `pinnedPeerCertSha256`。
- BBR 是宿主机 Linux 内核参数，不是 sing-box 或 Docker 容器配置；它主要影响 TCP，对 Hysteria2 的 UDP 流量基本无效。
- 如果使用云服务器，请同时检查系统防火墙和云厂商安全组。
- 脚本不会覆盖已存在的 `/opt/sing-box/docker-compose.yml`，避免误覆盖用户修改。

## 上游

- https://github.com/SagerNet/sing-box
- https://github.com/233boy/sing-box

使用或分发时请遵守上游项目许可证要求。
