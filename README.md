# Nginx 网站与 SNI 分流管理

`setup.sh` 安装 VPS 依赖与 `npctl`；`nginx_proxy_control.sh` 管理网站、证书及 Nginx Stream SNI 分流。本工具不安装、读取、修改或重启 sing-box，不修改 DNS。

更新时请取得完整仓库，然后运行 `sudo bash setup.sh`，选择 **9. 安全更新 npctl**。选项 8 检测到现有 `nginx.conf` 时也改用安全更新；不会重写现有主配置、网站或 SNI 映射。辅助文件 `npctl_stream.sh`、`npctl_stream_config.py` 随管理命令安装到 `/usr/local/lib/npctl/`，不要仅下载单个入口脚本。

## 启用并迁移已有网站

运行 `sudo npctl` → **5. SNI 分流管理** → **1. 启用**。工具先执行 `nginx -t/-T`，检测实际加载的配置、端口、站点链接及 Stream 模块，列出将迁移的 npctl 网站，说明客户端 IP 的影响，确认后执行事务。**没有现成网站也可以使用**：此时「启用」会引导添加首个节点，选择「同机回落」或「纯中转」。纯中转不要求本机有网站、节点域名证书或 Certbot。

- 公网 IPv4/IPv6 TCP 443 由独立的 `stream {}` 配置监听；通过 `ssl_preread` 读取 SNI，以 `map`、`upstream`、`proxy_pass` 转发原始 TLS。
- 普通 npctl HTTPS 网站（包括暂未启用的网站）改为 `127.0.0.1:8443`。HTTP 80、ACME、HTTPS 跳转、证书引用、WebSocket、HTTP/2、反代、snippets、缓存及上传限制保持原内容。明确标记的「落地机本地 HTTPS」站点一直保持本地 8443，不参与公网监听迁移。
- 没有匹配节点的 SNI 转发至本地 HTTPS 8443，由 Nginx 按原来的 `server_name` 提供网站。没有 SNI 的 TLS 连接也使用此默认目标；证书依然必须与访问的域名匹配。纯中转机器没有本地 HTTPS 服务时，该默认目标拒绝连接，未匹配 SNI 不会转发到任意节点。
- 非 npctl 的已加载 443/8443 配置、第三方 Stream、不明监听选项或其他进程占用端口会阻止迁移。请先手动处理，工具不会覆盖第三方配置。
- 新建普通网站自动使用当前模式的 HTTPS 监听地址。站点启停、证书更换和上传限制管理继续可用。

Stream 没有终止客户端 TLS。此模式不使用 PROXY protocol，也不伪造客户端 IP。HTTP 后端将看到本地连接 IP，网站访问日志、`X-Real-IP` / `X-Forwarded-For`、IP ACL、限速、Fail2Ban 的客户端 IP 识别会受影响。启用前请评估已有策略。

Debian/Ubuntu 缺少模块时会安装 `libnginx-mod-stream`，安装前确认不会连带替换 Nginx 软件包；安装期间临时阻止软件包钩子操作 Nginx 服务，结束后恢复原来的系统服务策略。若需要先升级 Nginx，会明确停止并要求先使用更新菜单。模块可用性检查失败时不会迁移网站。

## 添加多个 REALITY 节点映射

菜单 **5 → 2. 添加节点**，分别输入 SNI、已有的本地入口端口，再选择部署方式：**1. 同机 REALITY + 本机 HTTPS 回落**（默认）或 **2. 纯中转**。本地入口可以是 REALITY，也可以是转发到落地机的 direct。**无需提前启用 SNI，也无需手动创建网站**；尚未启用时会展示网站迁移清单及影响，确认后在同一事务中完成必要的网站准备、HTTPS 监听迁移、Stream 启用与节点映射，只在最终检查通过后重载一次。取消或失败会撤销本轮配置变更，不留下半启用状态；已申请的证书继续保留。例如添加：

| SNI | Stream 目标 |
| --- | --- |
| `node1.cetaceang.de` | `127.0.0.1:34138` |
| `node2.cetaceang.de` | `127.0.0.1:39149` |
| `blog.cetaceang.de` / 其他 SNI | `127.0.0.1:8443` |

映射拒绝重复 SNI、重复本地端口、不合法域名及 80/443/8443 循环目标。**同机模式**会复用该域名已有的 npctl 网站；没有网站时提供创建独立静态 HTTPS 回落网站的选项，可以取消而不创建映射。首先复用有效且覆盖 SNI 的本机证书，包括 Cloudflare 通配证书；缺少证书时进入现有证书选择/申请流程，可使用 Webroot 或 Cloudflare DNS。证书必须未过期并覆盖该 SNI，不能跳过验证。**纯中转模式**跳过该域名的本机网站和证书流程，只添加 SNI 映射；对应的 HTTPS 回落由运行 REALITY 的落地机提供。

节点域名应解析到公网入口 VPS。Cloudflare 需为 **仅 DNS（灰云）**。以下示例适用于 REALITY 和 HTTPS 回落在同一台机器的情况，请在独立的 sing-box 管理脚本中自行设置：

```text
客户端 server = node1.cetaceang.de
客户端 port = 443
客户端 servername = node1.cetaceang.de
服务端 REALITY SNI = node1.cetaceang.de
服务端 REALITY handshake = 127.0.0.1:8443
```

菜单 **5 → 3** 显示每个映射的目标和部署方式；同机节点显示本机证书及网站状态，纯中转节点明确显示无需本机节点证书、HTTPS 回落在落地机。**5 → 4** 删除映射，保留网站和证书。**5 → 5** 可查看、创建/复用或删除本功能的静态回落网站。回落页面位于 `/var/www/npctl-fallback/<域名>/index.html`，可自行替换内容。同机节点仍引用的网站不可禁用/删除；纯中转映射不阻止删除独立的本机回落网站，证书继续保留。证书管理仍保护所有 npctl 网站引用的证书。

### 线路机 direct 中转，落地机提供 HTTPS 回落

两台机器分别更新完整仓库并运行 `sudo bash setup.sh` → **9. 安全更新 npctl**。已有 Nginx 配置会保留。落地机如尚未安装 Nginx/Certbot，先使用正常安装流程准备服务和依赖；下面的「本地 HTTPS」操作自身只新增本地站点，不占用公网 80/443。

1. **线路机**：添加 SNI 节点时选择 **2. 纯中转**，本地端口输入现有 direct 入口的实际端口。已有映射使用 **5 → 8. 修改节点部署方式** 改成纯中转，无需删除重建。现有端口、direct 转发、网站及证书均保留；不自动操作 sing-box。
2. **落地机**：选择 **5 → 5. HTTPS 回落网站 → 4. 创建落地机本地 HTTPS 8443**，输入节点 SNI。复用或申请有效证书后，创建仅监听 `127.0.0.1:8443` 的 HTTPS 静态站点。无需启用 SNI/Stream，无需添加节点映射，也无需开放公网 8443；不会给该站点创建公网 HTTP 80 或 HTTPS 443 监听。重复操作复用已有本地站点，不重复创建。
3. **证书**：域名仍指向线路机。落地机优先复用本机有效证书或使用现有 Cloudflare DNS 验证功能；直接在落地机使用 HTTP-01 通常收不到验证请求。证书自动续期及 Nginx deploy hook 沿用原机制。线路机只透传时不需要该节点域名证书，已有其他 HTTPS 网站继续使用原证书。
4. **REALITY**：在落地机的 sing-box 管理工具中设置 handshake 地址 `127.0.0.1`、端口 `8443`，SNI 为节点域名。`127.0.0.1` 始终指运行 REALITY 的机器；不得填会经线路机转回 REALITY 的节点公网 443。

线路机保留 `客户端 → Nginx Stream:443 → 本机 direct 入口 → 落地机 VLESS`；落地机增加 `REALITY handshake → 本机 Nginx HTTPS:8443`。本项目不验证或更改 direct 的实际远端目标，也不读取落地机的 sing-box 配置。

旧节点缺少部署方式元数据时仍按同机模式读取，不自动切换。原 `nodes.tsv` 的两列格式保持不变，纯中转模式单独记录于 `node-modes.tsv`；端口编辑、删除、备份和回滚会保留或同步处理此元数据。切换为纯中转不会自动删除已有回落网站或证书；全部节点均为纯中转时，可按需删除最后一个本地静态回落网站。切回同机模式需重新验证本机证书、准备网站，通过校验后才生效。

本地专用站点含 `# Managed by npctl local-only HTTPS fallback` 标记；启用、禁用 SNI 时始终保留本地 8443。已有同域名普通网站不会被该入口强制转换或覆盖。独立的落地机未登记本机 SNI 映射时，npctl 无法知道该站点是否正被 sing-box 使用，删除或禁用前请自行确认。

### 修改已有节点的后端端口

菜单 **5 → 7. 修改节点后端端口**，输入已有 SNI 及新端口，例如将 `node1.cetaceang.de` 的 `39149` 改为 `34138`。工具保留 SNI、证书、回落网站和其他映射，备份后生成新的 Stream upstream，只有校验通过才重载；失败自动恢复。新端口不能与其他映射重复，也不能是 80、443 或 8443。SNI 已禁用时也可以修改保留的映射，不会自动启用分流。

该操作只更新 Nginx 转发目标，sing-box 的实际入站监听需在其管理脚本中另行修改。公网端口仍为 443，本地 HTTPS 回落仍为 8443；客户端端口和 REALITY handshake 无需因为节点后端端口变化而修改。

## 禁用与回滚

菜单 **5 → 6. 禁用** 将普通网站恢复到启用前的 443 监听指令，恢复普通新网站的默认公网 443 监听，移除主配置中的本工具 Stream include。本地专用 HTTPS 回落保持 127.0.0.1:8443。映射、部署方式、网站、内容和证书继续保留，随后可重新启用。重复启用/禁用不会生成重复配置。

每次 SNI 变更前都在 `/var/backups/npctl/sni-<时间>-<随机>/` 保存本次涉及文件的原内容、权限、符号链接及“原本不存在”的信息。修改完成后只有 `nginx -t` 通过才 reload；校验失败自动恢复文件；reload 失败恢复文件并尝试校验、重载旧配置。任何站点失败都会撤销整个事务。

成功或失败的提示包含对应备份路径。手动恢复到该次操作前：

```bash
sudo bash /var/backups/npctl/sni-具体备份目录/rollback.sh
```

回滚逐文件恢复，不覆盖整个 `/etc/nginx`，不删除证书；回滚较旧备份会撤销该次操作涉及文件后来的编辑，请选择正确备份。主配置只增加一条明确标记的顶层 include；Stream 配置及映射元数据位于 `/etc/nginx/npctl-stream/`，目录的 `.owner` 标记声明本项目与元数据版本；同路径存在未标记文件时停止操作。

## 验证与测试

在自己的服务器上手动验证正常网站与本地握手网站（替换域名/IP）：

```bash
sudo nginx -t
sudo ss -ltnp '( sport = :443 or sport = :8443 )'
curl --resolve blog.cetaceang.de:443:服务器IP https://blog.cetaceang.de/
curl --resolve node1.cetaceang.de:8443:127.0.0.1 https://node1.cetaceang.de:8443/
openssl s_client -connect 127.0.0.1:8443 -servername node1.cetaceang.de -verify_hostname node1.cetaceang.de </dev/null
sudo certbot renew --dry-run
```

分机部署时，公网 443 测试在线路机进行，本地 8443 的 curl/OpenSSL 测试在运行 REALITY 的落地机进行。节点域名的公网 443 正在转发至 REALITY 后端，网页回落还依赖该后端正确设置 handshake。普通网站应继续通过公网 443 访问；本地 8443 不需要开放防火墙。现有 Certbot deploy hook 在续期成功后执行 `nginx -t && systemctl reload nginx`；HTTP 80 Webroot 与 Cloudflare DNS 续期方式不变。

仓库的隔离自动测试：

```bash
for script in setup.sh nginx_proxy_control.sh npctl_stream.sh; do bash -n "$script" || exit 1; done
shellcheck --severity=warning --extended-analysis=false setup.sh nginx_proxy_control.sh npctl_stream.sh
python3 -m unittest discover -s tests -v
```

测试在临时目录生成网站、映射和证书，模拟服务操作、端口与 Certbot，覆盖多站迁移、证书/SNI、映射生命周期、普通网站管理、幂等、setup 保留及失败回滚。CI 分别用 mawk、GNU awk 执行全部回归；本机可设置 `NPCTL_TEST_AWK=mawk` 或 `NPCTL_TEST_AWK=gawk`（也支持可执行文件绝对路径）选择 awk 实现。证书测试还覆盖旧 OpenSSL 在域名不匹配时仍返回成功退出码的行为。

也可指定独立解包且 ABI 匹配的 Nginx/Stream 模块执行真实 `nginx -t/-T`；设置 `NPCTL_TEST_NETNS=1` 将校验放在独立网络命名空间中，需本机可无交互使用 `sudo unshare -n`：

```bash
NPCTL_TEST_NETNS=1 \
NPCTL_TEST_NGINX=/临时目录/usr/sbin/nginx \
NPCTL_TEST_STREAM_MODULE=/临时目录/usr/lib/nginx/modules/ngx_stream_module.so \
python3 -m unittest discover -s tests -v
```

指定上述真实工具后，测试还会在独立网络命名空间中临时运行 Nginx 与模拟 TLS 后端，验证实际 SNI 分流、证书主机名、本地 HTTPS 回落、HTTP 80 跳转、ACME 文件、WebSocket 101 和 HTTP/2 ALPN。新增覆盖无网站/证书的纯中转流程、混合部署、已有节点模式切换、模式元数据持久化与失败回滚；真实 Nginx 测试还验证纯中转仅监听公网 443、落地机独立 HTTPS 8443 可与已有公网 443 服务共存。这些测试不会连接生产服务器、申请真实证书或启动 sing-box；真实公网 DNS、ACME 签发/续期、代理客户端连通及浏览器行为仍需部署后验证。
