# singbox-docker

Docker 版 sing-box 多入站管理脚本。核心运行使用 SagerNet 官方 sing-box 镜像，交互管理思路参考 233boy/sing-box 的一键脚本体验。

> 仅供学习、测试和合法网络管理用途。使用者需要自行遵守所在地法律、云厂商规则和上游项目许可证。

## 功能

- 初始化 Docker / Docker Compose 运行环境
- 使用官方稳定最新版镜像，默认 `ghcr.io/sagernet/sing-box:latest`
- 添加 VLESS Reality 入站
- 添加 Hysteria2 入站，支持自签证书或 Let's Encrypt 真实证书
- 添加 AnyTLS 入站，支持自签证书或 Let's Encrypt 真实证书
- 添加 Door 端口转发入站
- 删除入站、查看配置、检查配置、备份恢复
- 查看 Hysteria2 自签证书 `pinSHA256` hex 链接
- 查看并启用宿主机 BBR
- 支持通过 `SING_BOX_IMAGE` 或 `SING_BOX_VERSION` 覆盖镜像
- 配置先校验再应用，应用失败时恢复原配置并尝试恢复旧服务
- 普通重启保留容器；镜像升级单独执行，失败时按旧镜像 ID 恢复
- 已校验的原子备份、管理操作互斥锁、按 TCP/UDP 分别检查端口

## 快速使用

一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/MISThelio/singbox-docker/main/install.sh -o install.sh
sudo SCRIPT_URL=https://raw.githubusercontent.com/MISThelio/singbox-docker/main/singbox-docker.sh bash install.sh
```

从源码目录安装：

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

## 菜单结构

```text
1. 添加配置
2. 删除入站
3. 配置查看 / 检查
4. 启动 sing-box
5. 重启 sing-box
6. 停止 sing-box
7. 查看日志
8. 更新管理
9. 系统优化
10. 安装/修复快捷命令 sb
11. 卸载
```

`初始化/修复 sing-box Docker 环境` 位于 `系统优化` 子菜单中。添加入站、删除入站、更新镜像等操作会按需初始化基础环境。

## 升级已有安装

运行 `sb`，选择 `更新管理 -> 更新脚本自身`，然后退出菜单并重新执行 `sb`。
本次修复版本在主菜单显示 `脚本版本：2026.11.05.1`。更新脚本本身不会更新镜像或重启节点。

`启动/重启 sing-box` 使用已有容器及其实际镜像。需要升级核心或切换镜像时，使用
`更新管理 -> 更新 sing-box 镜像`；该操作才会拉取镜像并替换容器。
对已有安装设置 `SING_BOX_IMAGE` / `SING_BOX_VERSION` 后，也需要执行这个镜像更新选项才能切换运行版本。

升级失败时会恢复原配置，并使用升级前记录的镜像 ID 恢复服务；恢复后的 Compose
可能暂时固定为旧镜像 ID，下一次镜像更新仍按指定版本（默认 `latest`）执行。
如果自动恢复也失败，脚本会保留 `.deployment.*` 目录并显示路径，便于继续排查。
正常退出和 HUP/INT/TERM 中断会触发恢复，断电或 SIGKILL 无法执行退出处理。

Compose 镜像修改使用 Compose 自己解析配置，再写回兼容 YAML 的 JSON 格式，保留其他服务。
需要支持 `config --format json --no-interpolate --no-env-resolution --no-path-resolution` 的 Compose 插件；
不支持时会在停止服务前报错。日志和版本查询按 Compose 服务识别容器，不依赖容器名称。

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

运行镜像默认使用 `latest` 稳定标签，方便菜单里的镜像更新自动跟随官方稳定版；源码构建仍需要指定真实 release tag。
Dockerfile 显式启用 `with_quic,with_utls`，包含 Hysteria2 所需的 QUIC 支持。

## 开发验证

安装 Bash、jq、tar、iproute2、util-linux 和 Docker Compose 后执行：

```bash
bash -n singbox-docker.sh
bash -n install.sh
bash tests/regression.sh
shellcheck -S error singbox-docker.sh tests/regression.sh
bash tests/docker-lifecycle.sh
docker build -t local/sing-box:review .
docker run --rm local/sing-box:review version
```

回归测试使用临时目录和模拟 Docker 操作；Compose 配置解析测试不需要 Docker daemon。
`tests/docker-lifecycle.sh` 另需 Docker daemon 和 `alpine:3.22`，使用独立的临时 Compose 项目测试真实容器恢复，结束后自动清理。

## Hysteria2 证书

添加 Hysteria2 时可以选择两种证书模式：

- 自签证书：快速创建，客户端需要开启 insecure，或使用菜单生成的 `pinSHA256` hex 链接。
- Let's Encrypt 真实证书：推荐，需要域名已解析到服务器，并放行 `80/tcp` 用于 HTTP-01 验证。

真实证书模式会把证书复制到 `/opt/sing-box/config/cert-标签/`，并安装 certbot 续期 hook，续期后自动重启 sing-box 容器。

## AnyTLS

AnyTLS 从 sing-box `1.12.0` 开始支持。本脚本会生成 AnyTLS 入站配置，并在菜单中显示 AnyTLS URI 和 sing-box 客户端出站 JSON。

不同客户端对 AnyTLS URI 的支持程度不一致；如果导入失败，请使用菜单里的 sing-box 客户端出站配置手动添加。

## 注意

- 脚本需要 root 权限运行，会安装依赖、安装或启用 Docker，并写入 `/opt/sing-box`。
- VLESS Reality 通常只需要放行 TCP 端口。
- Hysteria2 需要放行 UDP 端口；可以与相同端口号的 VLESS TCP 入站共存。
- AnyTLS 需要放行 TCP 端口。
- Hysteria2 如果选择 Let's Encrypt 真实证书，请额外在系统防火墙和云安全组放行 `80/tcp`，并确保 80 端口没有被其他服务占用。
- Hysteria2 默认使用自签证书；部分 Xray-core 新版客户端已移除 `allowInsecure`，请优先使用菜单里的 `查看 Hysteria2 链接/证书 pin` 获取十六进制 `pinSHA256` 链接，或在客户端手动填写 `pinnedPeerCertSha256`。
- BBR 是宿主机 Linux 内核参数，不是 sing-box 或 Docker 容器配置；它主要影响 TCP，对 Hysteria2 的 UDP 流量基本无效。
- 如果使用云服务器，请同时检查系统防火墙和云厂商安全组。
- 脚本不会覆盖已存在的 `/opt/sing-box/docker-compose.yml`，避免误覆盖用户修改。

## 安全提示

- 不要公开 `/opt/sing-box/config/config.json`、`/opt/sing-box/nodes.txt`、证书目录或完整节点链接。
- 节点链接里的 UUID、密码、Reality key、证书 pin 都应视为敏感信息。
- 提交 issue 或日志时请先打码服务器 IP、域名、密码、UUID 和私钥。
- Hysteria2 自签证书建议使用 `pinSHA256`；长期使用 `insecure/allowInsecure` 风险更高，且部分客户端会逐步移除相关兼容。

## 免责声明

本项目不提供任何网络服务，也不内置任何可用节点。脚本只负责在用户自己的服务器上生成和管理 sing-box 配置。

运行脚本可能修改系统环境、安装软件包、启动 Docker 容器、开放监听端口、生成证书或调整内核参数。请在理解脚本行为后使用。因使用、修改、分发本项目导致的账号、服务器、网络、数据或合规风险，由使用者自行承担。

## 许可证

本项目使用 GPL-3.0 许可证发布，详见 [LICENSE](LICENSE)。

## 上游

- https://github.com/SagerNet/sing-box
- https://github.com/233boy/sing-box

使用或分发时请同时遵守上游项目许可证要求。上游来源说明见 [NOTICE](NOTICE)。
