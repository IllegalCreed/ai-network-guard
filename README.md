# ExitWatch / 出口守望

一个轻量的 macOS 菜单栏 IP 出口监测器。它会定时访问多个独立的出口探针，查询每个探针看到的 IP、地理位置和网络类型；当任一探针落在中国大陆（CN）或中国香港（HK），或所有探针都不可用时，发送系统通知。

> 这是一个网络诊断工具，不是 VPN，也不能保证某个网站一定接受当前 IP。第三方 IP 数据库存在延迟和误判的可能，网络类型会明确标注为“推测”或“数据库标记”。

## 当前版本

v0.1.0 已包含：

- 原生 macOS 菜单栏图标（macOS 13+）。
- 通用出口、Cloudflare 出口、Claude 出口三个默认探针。
- 并行检查，显示每个目标的 IP、国家/地区、城市、ASN、运营商和网络类型。
- 识别分流代理：不同目标返回不同 IP 时在摘要中提示。
- CN/HK 风险判定、掉线/探针不可用判定和系统通知。
- 15–600 秒检查间隔、通知开关、复制 IP。
- 10 分钟 IP 地理信息缓存，避免重复请求。
- --probe-once 命令行模式，方便排障和 CI。

## 快速运行

需要 macOS 13+、Xcode Command Line Tools 和 Swift 5.9+：

~~~
swift run ExitWatch --probe-once
./scripts/build-app.sh
open dist/ExitWatch.app
~~~

首次启动时，应用会请求“通知”权限；点击菜单栏的盾牌图标可以展开面板。应用是菜单栏常驻程序，不会在 Dock 中显示。

## 工作方式

默认探针如下：

| 探针 | 地址 | 作用 |
| --- | --- | --- |
| 通用出口 | api64.ipify.org | 获取普通 HTTPS 请求看到的公共 IP |
| Cloudflare 出口 | 1.1.1.1/cdn-cgi/trace | 获取 Cloudflare 连接看到的 IP 和边缘机房 |
| Claude 出口 | claude.ai/cdn-cgi/trace | 获取访问 Claude 域名时的实际出口 |

请求使用系统 URLSession，因此遵循 macOS 当前的系统代理设置。每个 IP 会发送到 https://ipapi.is/ 查询国家/地区、ASN 和机房/VPN/代理等信号。Cloudflare 的 trace 接口会返回连接侧的 ip 和 colo 字段，参考：
https://developers.cloudflare.com/fundamentals/reference/cdn-cgi-endpoint/

## 隐私和限制

- 运行时会向上述探针发送请求；这是检测出口所必需的。
- 只把探针返回的 IP 发送给 ipapi.is，不采集浏览历史、应用内容或账号信息。
- ipapi.is 的 is_datacenter、is_vpn、is_proxy 等字段是数据库信号，不等价于法律或运营商意义上的“家宽”。
- 这个版本不做 DNS、WebRTC、IPv6 泄漏或每个应用的独立代理检测；这些能力需要额外的系统网络扩展或逐目标探针。
- 如果某个软件自带代理、QUIC/DoH 或自己的网络栈，它的实际出口仍可能和本工具不同。

## 开发

~~~
swift test
swift build
swift run ExitWatch --version
~~~

项目采用 Swift Package Manager，核心网络逻辑在 Sources/ExitWatchCore，菜单栏界面在 Sources/ExitWatch。GitHub Actions 会在 macOS runner 上自动运行测试并上传 .app 构建产物。

## 后续计划

1. 允许在设置中添加/删除目标域名，并为每个目标设置期望地区。
2. 登录时自动启动和更完整的通知抑制策略。
3. 可选的 DNS/WebRTC 泄漏探针。
4. 公证签名和自动发布 DMG。
