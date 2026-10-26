# Nginx 网站与 SNI 分流管理

`setup.sh` 安装 VPS 依赖与 `npctl`；`nginx_proxy_control.sh` 管理网站、证书及 Nginx Stream SNI 分流。本工具不安装、读取、修改或重启 sing-box，不修改 DNS。

更新时请取得完整仓库，然后运行 `sudo bash setup.sh`，选择 **9. 安全更新 npctl**。选项 8 检测到现有 `nginx.conf` 时也改用安全更新；不会重写现有主配置、网站或 SNI 映射。辅助文件 `npctl_stream.sh`、`npctl_stream_config.py` 随管理命令安装到 `/usr/local/lib/npctl/`，不要仅下载单个入口脚本。

## 启用并迁移已有网站

运行 `sudo npctl` → **5. SNI 分流管理** → **1. 启用**。工具先执行 `nginx -t/-T`，检测实际加载的配置、端口、站点链接及 Stream 模块，列出将迁移的 npctl 网站，说明客户端 IP 的影响，确认后执行事务。

- 公网 IPv4/IPv6 TCP 443 由独立的 `stream {}` 配置监听；通过 `ssl_preread` 读取 SNI，以 `map`、`upstream`、`proxy_pass` 转发原始 TLS。
- 所有现有 npctl HTTPS 网站（包括暂未启用的网站）改为 `127.0.0.1:8443`。HTTP 80、ACME、HTTPS 跳转、证书引用、WebSocket、HTTP/2、反代、snippets、缓存及上传限制保持原内容。
- 没有匹配节点的 SNI 转发至本地 HTTPS 8443，由 Nginx 按原来的 `server_name` 提供网站。没有 SNI 的 TLS 连接也使用此默认目标；证书依然必须与访问的域名匹配。
- 非 npctl 的已加载 443/8443 配置、第三方 Stream、不明监听选项或其他进程占用端口会阻止迁移。请先手动处理，工具不会覆盖第三方配置。
- 新建普通网站自动使用当前模式的 HTTPS 监听地址。站点启停、证书更换和上传限制管理继续可用。

Stream 没有终止客户端 TLS。此模式不使用 PROXY protocol，也不伪造客户端 IP。HTTP 后端将看到本地连接 IP，网站访问日志、`X-Real-IP` / `X-Forwarded-For`、IP ACL、限速、Fail2Ban 的客户端 IP 识别会受影响。启用前请评估已有策略。

Debian/Ubuntu 缺少模块时会安装 `libnginx-mod-stream`，安装前确认不会连带替换 Nginx 软件包；安装期间临时阻止软件包钩子操作 Nginx 服务，结束后恢复原来的系统服务策略。若需要先升级 Nginx，会明确停止并要求先使用更新菜单。模块可用性检查失败时不会迁移网站。

## 添加多个 REALITY 节点映射

菜单 **5 → 2. 添加节点**，分别输入 SNI 和 sing-box 已有的本地端口。例如添加：

| SNI | Stream 目标 |
| --- | --- |
| `node1.cetaceang.de` | `127.0.0.1:34138` |
| `node2.cetaceang.de` | `127.0.0.1:39149` |
| `blog.cetaceang.de` / 其他 SNI | `127.0.0.1:8443` |

映射拒绝重复 SNI、重复本地端口、不合法域名及 80/443/8443 循环目标。工具会复用该域名已有的 npctl 网站；没有网站时提供创建独立静态 HTTPS 回落网站的选项，可以取消而不创建映射。首先复用有效且覆盖 SNI 的本机证书，包括 Cloudflare 通配证书；缺少证书时进入现有证书选择/申请流程，可使用 Webroot 或 Cloudflare DNS。证书必须未过期并覆盖该 SNI，不能跳过验证。

节点域名应解析到 VPS。Cloudflare 需为 **仅 DNS（灰云）**。请在独立的 sing-box 管理脚本中自行设置：

```text
客户端 server = node1.cetaceang.de
客户端 port = 443
客户端 servername = node1.cetaceang.de
服务端 REALITY SNI = node1.cetaceang.de
服务端 REALITY handshake = 127.0.0.1:8443
```

菜单 **5 → 3** 显示每个映射的目标、证书是否有效并覆盖 SNI、回落网站是否存在和启用。**5 → 4** 删除映射，保留网站和证书。**5 → 5** 可查看、创建/复用或删除本功能的静态回落网站。回落页面位于 `/var/www/npctl-fallback/<域名>/index.html`，可自行替换内容。仍被节点引用的网站不可禁用/删除；证书管理会保护所有 npctl 网站引用的证书。

## 禁用与回滚

菜单 **5 → 6. 禁用** 将网站恢复到启用前的 443 监听指令，恢复新网站的默认公网 443 监听，移除主配置中的本工具 Stream include。映射、网站、内容和证书继续保留，随后可重新启用。重复启用/禁用不会生成重复配置。

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

节点域名的公网 443 正在转发至 REALITY 后端，网页回落还依赖该后端正确设置 handshake。普通网站应继续通过公网 443 访问；本地 8443 不需要开放防火墙。现有 Certbot deploy hook 在续期成功后执行 `nginx -t && systemctl reload nginx`；HTTP 80 Webroot 与 Cloudflare DNS 续期方式不变。

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

指定上述真实工具后，测试还会在独立网络命名空间中临时运行 Nginx 与两个模拟 TLS 后端，验证实际 SNI 分流、证书主机名、本地 HTTPS 回落、HTTP 80 跳转、ACME 文件、WebSocket 101 和 HTTP/2 ALPN。这些测试不会连接生产服务器、申请真实证书或启动 sing-box；真实公网 DNS、ACME 签发/续期、代理客户端连通及浏览器行为仍需部署后验证。
