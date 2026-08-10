# AI网络护航 / AI Network Guard

[![macOS build](https://github.com/IllegalCreed/ai-network-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/IllegalCreed/ai-network-guard/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/IllegalCreed/ai-network-guard?label=下载)](https://github.com/IllegalCreed/ai-network-guard/releases/latest)

一个面向中国大陆网络环境的 macOS 菜单栏守护工具，帮助 Claude Code、ChatGPT 和其他境外 AI Agent 保持稳定、可解释的网络出口。它会定时访问多个独立的出口探针，查询每个探针看到的 IP、地理位置和网络类型；当任一探针落在中国大陆（CN）或中国香港（HK），或所有探针都不可用时，发送系统通知。

它不承诺“永不封号”，而是尽早发现出口、DNS、WebRTC/UDP 和设备环境的不一致，降低因网络环境异常导致账号触发风控的风险。

关键词：Claude Code、ChatGPT、Anthropic、OpenAI、macOS、网络出口、IP 地理位置、DNS 泄漏、WebRTC 泄漏、AI Agent 账号安全。

> 这是一个网络诊断工具，不是 VPN，也不能保证某个网站一定接受当前 IP。第三方 IP 数据库存在延迟和误判的可能，网络类型会明确标注为“推测”或“数据库标记”。

## 当前版本：v0.3.0

[查看 v0.3.0 Release](https://github.com/IllegalCreed/ai-network-guard/releases/tag/v0.3.0)

当前版本包含：

- 原生 macOS 菜单栏图标（macOS 13+）。
- 通用出口、Cloudflare 出口、Claude 出口三个默认探针。
- 并行检查，显示每个目标的 IP、国家/地区、城市、ASN、运营商和网络类型。
- 识别分流代理：不同目标返回不同 IP 时在摘要中提示。
- CN/HK 风险判定、掉线/探针不可用判定和系统通知。
- 系统网络路径监听：断网或接口切换时立即刷新并发送去重通知。
- 15–600 秒检查间隔、通知开关、复制 IP。
- 10 分钟 IP 地理信息缓存，避免重复请求。
- --probe-once 命令行模式，方便排障和 CI。
- 按需及出口 IP/网络接口变化时自动执行 DNS 泄漏探测，显示远端观察到的解析器。
- WebRTC 常用 UDP/STUN 出口探测，并与 HTTPS 出口 IP 交叉比较。
- DNS/WebRTC 风险与出口异常的去重系统通知。
- 设备环境信息卡片：本机时区、首选语言、macOS 版本和网络接口；本机时区会与 IP 出口定位到的时区做一致性比较。
- 可选的 Agent 防护：出口明确回到 CN/HK 时，优雅关闭 Claude Code 与 ChatGPT；默认关闭。

## 下载

Apple Silicon Mac（arm64）可直接下载：

- [下载 AI-Network-Guard-v0.3.0-macOS-arm64.zip](https://github.com/IllegalCreed/ai-network-guard/releases/download/v0.3.0/AI-Network-Guard-v0.3.0-macOS-arm64.zip)
- [下载 SHA256 校验文件](https://github.com/IllegalCreed/ai-network-guard/releases/download/v0.3.0/AI-Network-Guard-v0.3.0-macOS-arm64.zip.sha256)
- [查看全部版本](https://github.com/IllegalCreed/ai-network-guard/releases)

解压后将 `ExitWatch.app` 拖入“应用程序”文件夹，再点击菜单栏的盾牌图标打开面板。当前发布包由 GitHub Actions 构建，未经过 Apple 公证；首次打开若出现系统提示，请在 Finder 中右键应用并选择“打开”。

Intel Mac 可按下方命令从源码构建。

## 快速运行

需要 macOS 13+、Xcode Command Line Tools、Swift 5.9+ 和 Python 3.9+：

~~~
python3 -m pip install -r requirements-build.txt
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

请求使用系统 URLSession，因此遵循 macOS 当前的系统代理设置。每个 IP 会优先发送到 https://ipwho.is/ 查询国家/地区、时区、ASN 和网络信号；该服务失败时再尝试 https://ipapi.is/。Cloudflare 的 trace 接口会返回连接侧的 ip 和 colo 字段，参考：
https://developers.cloudflare.com/fundamentals/reference/cdn-cgi-endpoint/

## 隐私和限制

- 运行时会向上述探针发送请求；这是检测出口所必需的。
- 只把探针返回的 IP 发送给 ipwho.is（失败时备用 ipapi.is），不采集浏览历史、应用内容或账号信息。
- 设备信息卡片中的时区、语言、系统版本和网络接口均在本机读取，不读取浏览器指纹。
- ipapi.is 的 is_datacenter、is_vpn、is_proxy 等字段是数据库信号，不等价于法律或运营商意义上的“家宽”。
- DNS 泄漏检测使用 bash.ws 的随机域名远端探针；WebRTC 检测通过 RFC 5389 UDP/STUN 获取映射地址，不保证与 Safari、Chrome 或其他浏览器的独立策略完全一致。
- 如果系统代理在远端解析 DNS，bash.ws 看到的会是代理侧解析器；Cloudflare、Google、Quad9、OpenDNS 等已知公共上游会标为“受信任上游”，未知解析器仍会标为“可能”，需要结合代理配置复核。
- 这个版本仍不做完整 IPv6 泄漏或每个应用的独立代理检测；这些能力需要额外的系统网络扩展或逐目标探针。
- 如果某个软件自带代理、QUIC/DoH 或自己的网络栈，它的实际出口仍可能和本工具不同。
- Agent 防护会向当前用户的 Claude Code/ChatGPT 进程发送退出请求，必要时在短暂等待后强制结束；开启前请确认这是你想要的行为。

## 开发

~~~
swift test
swift build
swift run ExitWatch --version
swift run ExitWatch --dns-once
swift run ExitWatch --webrtc-once
swift run ExitWatch --agents-once
~~~

项目采用 Swift Package Manager，核心网络逻辑在 Sources/ExitWatchCore，菜单栏界面在 Sources/ExitWatch。

## CI 与自动发布

- 每次推送或 Pull Request 会在 macOS runner 上运行测试并构建 `.app` artifact。
- 推送 `v*` 标签会自动创建 GitHub Release，上传 Apple Silicon 安装包和 SHA256 校验文件。
- 图标构建依赖固定在 `requirements-build.txt`，本地构建前先安装 Pillow。

## 后续计划

1. 允许在设置中添加/删除目标域名，并为每个目标设置期望地区。
2. 登录时自动启动和更完整的通知抑制策略。
3. 浏览器级 WebRTC 交叉验证与更完整的 IPv6 泄漏探针。
4. 公证签名和自动发布 DMG。
