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
- 添加 VLESS Reality / Hysteria2 / AnyTLS 时可选域名，自动接入共享 443
- 独立 Docker Nginx 按 SNI 转发 TCP 节点，并反向代理本机网站
- 共享入口使用 webroot 申请证书、导入已有证书、自动同步续期和平滑重载

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
当前版本在主菜单显示 `脚本版本：2026.11.06.7`。更新脚本本身不会更新镜像、启用共享入口或重启节点。

sing-box 容器日志默认限制为 `10m x 3`（可用 `SINGBOX_LOG_MAX_SIZE` / `SINGBOX_LOG_MAX_FILE` 覆盖）。
已有安装执行 `系统优化 -> 限制 sing-box 容器日志大小`，确认后用当前镜像重建容器，节点会断开几秒；
不确认则只写入 Compose，下次更新镜像时生效。共享 443 的 Nginx 单进程并发上限为 16384，文件句柄 65535。

新安装会检测本机 IPv6 出口：没有则出站解析使用 `ipv4_only`，有则 `prefer_ipv4`，
避免日志中出现大量 `network is unreachable`、部分网站（如 Cloudflare 验证）打不开。
已有安装执行 `系统优化 -> 出站 IPv4/IPv6 解析策略`，配置先校验再重启，失败自动还原。

子菜单选择 `0` 直接返回，不再追加“按回车继续”。操作结果仅暂停一次。
添加入站或网站失败后可输入 `y` 重新填写，或直接回车返回菜单，不会因普通操作失败退出整个脚本。
每次操作仍保留独立的失败中止和原有回滚处理，不会在某一步失败后继续执行后续步骤。
删除入站使用编号列表，显示标签、协议和 TCP/UDP 端口；共享节点还显示公网域名及内部端口。
输入编号后以 `y` 确认删除，输入 `0` 取消。列表只读取当前入站，不使用历史节点信息。

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
docker build -f tests/Dockerfile.shared -t local/sb-shared-tests .
docker run --rm local/sb-shared-tests
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

## 可选域名与共享 443

添加 VLESS Reality、Hysteria2 或 AnyTLS 时，首先会询问：

```text
绑定节点域名（先解析到本机）[填写后共享443；留空独立端口]:
```

- 留空：保持原来的独立端口模式，不安装或启用共享入口。
- 此处填写的是自己的节点域名，不是独立 Reality 模式后面询问的目标网站 SNI。
- 填写域名：自动准备官方 `nginx:stable-alpine` 容器、内部端口、证书和分流规则；节点对外端口固定为 443。
- 域名必须事先直接解析到此服务器，A / AAAA 记录均应正确；普通 CDN 的 HTTP 代理不适用于这些原始节点协议。
- 自动申请证书需要公网能够访问 `80/TCP`。脚本可尝试放行 UFW，但不能自动修改云厂商安全组。

建议使用不同子域名，例如：

| 域名 | 公网入口 | 处理方式 |
| --- | --- | --- |
| `www.example.com` | TCP 443 | Nginx HTTPS 网站反向代理 |
| `reality.example.com` | TCP 443 | Nginx SNI 透传到本机 VLESS Reality |
| `anytls.example.com` | TCP 443 | Nginx SNI 透传到本机 AnyTLS |
| `hy2.example.com` | UDP 443 | 直接进入 sing-box Hysteria2，不经过 Nginx TCP 分流 |

内部 TCP 入站和 HTTPS 握手目标只监听 `127.0.0.1`，内部端口无需在安全组放行。
共享 Reality 的 SNI 使用填写的域名，握手目标是本机 Nginx 对应的真实证书 HTTPS 服务。
脚本生成的节点链接始终使用域名和公网 443，而不是内部端口。
所有入站创建成功后会直接显示本次节点信息与分享链接（Door 显示转发参数），无需再进入查看菜单。
输出包含客户端连接凭据，不包含服务端 Reality 私钥；仍会保存到 `nodes.txt`。
Hy2 与网站可以使用同一个域名，网站先接入或 Hy2 先添加均可；证书会复用。

### 接入正常网站

先让网站应用在宿主机本地 HTTP 端口提供服务，例如 Docker 应用发布为
`127.0.0.1:8080:80`；保留应用本身的持久化数据和运行方式。然后进入：

```text
添加配置 -> 共享 443 / 网站管理 -> 接入 / 修改网站
网站域名：www.example.com
网站本机 HTTP 地址：http://127.0.0.1:8080
```

网站应用、sing-box 和 Nginx 是独立服务；添加网站不会重建应用容器。
停止 sing-box 节点不会停止 Nginx 网站入口。修改分流或更新共享证书使用 Nginx reload，
不会重启网站应用。Nginx 流日志可通过以下命令查看：

```bash
cd /opt/sing-box
docker compose logs --tail 100 singbox-gateway
```

Nginx 透传未启用 PROXY protocol，因此 sing-box 的共享 TCP 入站看到的来源是本机，
原始客户端 IP 在 Nginx 流日志中。请不要把本机测试通过当作公网链路已验证。

### 证书与边界

- 自动申请时先启动 HTTP-01 验证入口，再使用 Certbot webroot；后续续期不需要停止 Nginx，也不使用独占 80 的 standalone。
- 可以导入宿主机上的完整证书链和未加密私钥。脚本检查域名、有效期和密钥匹配，但导入证书的公共 CA 信任仍由证书提供方保证。
- Certbot deploy hook 和 systemd 五分钟同步任务会同步证书。导入证书的原管理工具仍负责申请、续期；同步任务不会替它申请证书。
- 没有运行 systemd 的系统需将 `sb --sync-shared-certificates` 接入原工具的续期后任务，并确保已有 `certbot renew` 定时任务。
- 若 80/TCP、443/TCP 已被非本脚本管理的网站或节点占用，脚本会拒绝自动接管。先规划将原网站入口迁移到本机其他 HTTP 端口，再接入；不要直接覆盖原 Nginx 配置。
- 若发现本脚本管理的旧 standalone 证书，会列出证书并询问是否迁移为 webroot；默认取消。确认证书归属需要活动入站、匹配的证书指纹和原部署钩子，不自动接管其他工具管理的证书。
- 一个 IP 的 UDP 443 只能有一个独立 Hy2 监听。第二个共享 Hy2 入站会被拒绝；普通 Nginx SNI 模块不分流 QUIC，也不能与网站 HTTP/3 同时独占 UDP 443。
- TCP 分流依赖可见的 TLS SNI。VLESS / AnyTLS 节点和网站使用不同子域名，保证网站不依赖节点运行；普通非 TLS Door 转发不支持这种域名共享方式。不要为生成的共享 TCP 节点额外开启隐藏真实 SNI 的 ECH。
- 共享路由、Nginx 配置和证书保存在 `config` 内，包含在已有备份中。删除共享节点同步删除其路由，若同域名还配置了网站，会保留网站。
- 本功能不修改 Docker daemon、数据根目录或全局网络路由，也不能保证修复公网路径上的间歇性断连。

### 旧证书迁移

更新脚本后，重新添加入站并填写新域名即可，无需删除旧域名或旧节点。
也可以不新建节点，直接进入：

```text
添加配置 -> 共享 443 / 网站管理 -> 迁移旧证书续期到共享入口
```

同一菜单的“查看证书续期方式”列出当前 Certbot 证书及验证目录，不显示账号或私钥。
独立迁移成功后，原节点的连接域名和端口不变；只是续期改为经过共享验证入口。
例如旧证书为 `tulionsn.fun`，新节点使用 `wakisome.fun`：

1. 确认新旧域名仍解析到本服务器，公网 `80/TCP` 可达。
2. 在添加入站时填写新域名；脚本列出可确认归属的旧证书后，输入 `y` 同意迁移。
3. 脚本启动共享验证入口，调用 Certbot `reconfigure` 测试续期。所有迁移和新配置成功后，继续使用新生成的节点链接。

迁移需要 Python 3 和 Certbot 2.3 或更新版本。缺少 Python 时可从系统优化初始化依赖。
旧版 Certbot 不会退回到强制生产续期，避免重复签发和触发限额。
迁移不更换现有正式证书或私钥，不删除证书，不修改原部署钩子。
使用的是 Certbot 官方测试续期机制，验证成功才保存新的续期方式，详见
[Certbot reconfigure 文档](https://eff-certbot.readthedocs.io/en/stable/using.html#modifying-the-renewal-configuration-of-existing-certificates)。

续期文件、原配置及钩子的私有备份保留在
`/opt/sing-box/backup/certbot-migration-时间-随机值/`，含敏感信息，不要公开。
后续步骤失败时恢复原续期文件、配置和服务；检测到并发变更或 Certbot 正忙时不会强行覆盖，
会保留备份和验证入口并明确提示人工核对。新申请的证书不会因后续配置失败而被删除；
若它仍依赖验证入口，入口会保留，修复原因后可重新添加配置。

归属不明、证书不匹配、未知的验证前后钩子或安装插件仍会阻止自动迁移。
脚本不会停止占用 80/443 的外部网站。已有外部网站应先规划入口迁移，或使用原证书管理器的 DNS 验证后导入证书。
遇到端口冲突时会显示宿主机监听进程和本配置使用该 TCP 端口的入站摘要。
**迁移证书不等于迁移已有网站或释放端口。** 若 443 已被网站或独立入站占用，须先确认归属，
再规划改用本机后端端口或独立端口；不要直接停止未知服务。即便改为 DNS 验证，也不能让两个服务同时独占 TCP 443。
迁移后须持续保留 `80/TCP` 和验证目录。若恢复旧备份或卸载会移除证书依赖的验证入口，
脚本会拒绝操作，要求先把相关续期迁移到其他可用 webroot 或 DNS 验证。

本地回归使用模拟 Certbot CLI 验证失败恢复，不连接真实 CA；实际服务器执行迁移时仍须通过公开 HTTP-01 测试续期。

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
