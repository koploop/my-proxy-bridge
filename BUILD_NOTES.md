# ProxyBridge 构建与排障记录

> 本文记录把本工程(基于 [InterceptSuite/ProxyBridge](https://github.com/InterceptSuite/ProxyBridge) 修改的 macOS 透明代理客户端)从"没有 Xcode 无法编译"到"GitHub Actions 出包 + 本机签名安装"的完整过程、踩过的坑与后续方向。
> 最后更新:2026-11-15

---

## 1. 现状

| 项目 | 状态 |
|---|---|
| 代码仓库 | github.com/koploop/my-proxy-bridge(main 分支) |
| Bundle ID | 主应用 `com.commonuse.magic` / 系统扩展 `com.commonuse.magic.extension` |
| 团队 | P57F6K6J34(Apple Development 证书: aoqiang he) |
| CI | `.github/workflows/build-mac.yml`(push 触发)/ `release-mac.yml`(手动对 tag 出包) |
| CI 产物 | 未签名的 universal(arm64+x86_64)`ProxyBridge-macOS.zip` |
| 本地签名 | `Scripts/sign-local.sh`(嵌入描述文件 + codesign,含 quarantine 清理) |
| 签名材料 | `cer/`(gitignored): Apple Development p12 + 两张开发描述文件 |
| 系统扩展 | 可激活、隧道可启动;版本 4.1.3/9 |
| 规则下发 | **随 `startTunnel(options:)` 传递**(主通道,见 §2.10),共享容器文件兜底;2026-11-15 已端到端验证(阻止规则生效) |

**日常构建流程:**
1. push 代码 → Actions 里 "Build macOS" 跑完(约 4 分钟)→ 下载 `ProxyBridge-macOS` artifact
2. `./Scripts/sign-local.sh path/to/ProxyBridge.app`
3. `ditto ProxyBridge.app /Applications/ProxyBridge.app` → 打开 → 启动代理

**注意:**
- 每次更新扩展代码后必须**提升版本号**(`CURRENT_PROJECT_VERSION` 和/或 `MARKETING_VERSION`),否则 sysexd 认为"已激活"而拒绝替换,新扩展永远不会生效(见 §2.11)
- 替换扩展后若启动报 "Unable to find this application extension record in the Launch Services database",运行一次 `ProxyBridge --reinstall-extension`(先退出 GUI)做干净重装
- 本机访问 github.com 需要代理:`export https_proxy=http://127.0.0.1:7897 all_proxy=socks5://127.0.0.1:7897`(git push 建议再加 `-c http.version=HTTP/1.1`)
- **被测应用不能配代理**:走了系统代理/手动代理(如 Clash Verge 的 127.0.0.1:7897)的流量走环回,透明代理拦截不到,规则不会生效(见 §2.12)
- **规则改动必须重启代理**(停止 → 启动)才生效,运行中修改无效(见 §3)

---

## 2. 遇到的各种问题与解决

### 2.1 没有 Xcode,如何编译
- **方案**:完全照搬上游的 Actions 思路并裁剪:CI 用 `macos-latest` 运行器 + `xcodebuild` 编译,本机只负责签名安装。上游路径(`MacOS/ProxyBridge/...`)按本工程根目录结构适配。

### 2.2 pbxproj 引用的 xcconfig 不存在
- `baseConfigurationReference` 指向根目录的 `Signing-Config-app/ext.xcconfig`,仓库里没有,CI/本地构建都会报 "unable to find base configuration file"。
- **解决**:把两份 xcconfig 直接提交进仓库(内容不含机密:Team ID + 开发证书身份 + 描述文件名)。

### 2.3 本机访问 GitHub 不稳定
- 症状:`git push` 报 `HTTP2 framing layer` / `Empty reply from server` / `Couldn't connect`;brew 下载 formulae 被 reset。
- 诊断:`api.github.com` 与 `codeload.github.com` 通,`github.com` 与 `raw.githubusercontent.com` 不通(无代理时)。
- **解决**:用户开启本机代理(127.0.0.1:7897)后,我的 shell 里显式 `export https_proxy/http_proxy/all_proxy`;git 额外 `-c http.version=HTTP/1.1 -c http.postBuffer=...`。
- gh CLI 从 ghcr/代理镜像装不上(Intel + macOS 13 无 bottle),改从 ghproxy.net 下载官方 release 二进制,用 `codesign -dv` + spctl 校验签名(Developer ID: GitHub)后安装;token 通过 `~/.config/gh/hosts.yml` 配置(经典 token 缺 `read:org` scope,gh 会提示但个人仓库操作不受影响)。

### 2.4 证书与描述文件不匹配
- cer/ 里最初的材料:一张 **Apple Development** 开发证书(p12,私钥齐全,团队 P57F6K6J34),但两张描述文件属于**另一个 App**(`com.commonuse.magic` 的组/iCloud 都不匹配),且描述文件内嵌证书是另一张(`d9b72…`)。
- 关键概念:**证书不绑定 Bundle ID,描述文件才绑定**;描述文件是 App ID 能力的"快照",能力改了必须重新生成。
- **解决**:把工程整体改到 `com.commonuse.magic(.extension)`(源码/entitlements/pbxproj/CI 校验全部同步),app group 改 `group.com.commonuse.magic`,iCloud 容器改 `iCloud.com.commonuse.magic`;本机 UDID(CBC16A16…)确认在描述文件设备列表中。

### 2.5 CI 上无法用开发描述文件签名(方案 A 失败)
- 两个连环坑:
  1. App ID 的 Network Extensions 只勾了普通版,描述文件里只有 `app-proxy-provider` 等普通值,而系统扩展需要 `-systemextension` 后缀值(entitlements ⊄ profile → 编译期报错);
  2. 更严重:**开发(Development)描述文件带设备白名单,xcodebuild 会校验"构建机器的 UDID"必须在名单内**,而 GitHub 运行器是临时虚拟机、每次全新 UDID,永远过不了。
- portal 网页上 Network Extensions **没有子项可勾**(只有 Xcode 的 Signing & Capabilities 界面暴露系统扩展变体),而本机 Xcode 15 + macOS 13 勾选后登记的仍是普通值;App Store Connect API 也只有总开关。
- **结论**:开发证书 + 开发描述文件这条路在 CI 上结构性不可行。用户只需要"装到自己的注册 Mac 上",因此选**方案 B:CI 只做不签名编译,签名挪到本地**(`CODE_SIGNING_ALLOWED=NO`;arm64 切片由链接器自动 adhoc 签名,校验步骤要接受 adhoc)。

### 2.6 entitlements 精简
- 上游模板把 8 种 NE 类型全写进 entitlements,属于"模板惯性"。按实际实现裁剪:
  - 扩展只保留 `app-proxy-provider` / `dns-proxy`(对应 Info.plist 里的两个 NEProviderClasses),且必须用**普通版值**——描述文件只授予普通值,内核在启动扩展时会校验 entitlements ⊆ profile(Xcode 的"系统扩展 → Network Extension"模板出厂也是普通值,实测完全正常)
  - 主应用同样需要 `app-proxy-provider` + `dns-proxy`:它用 `NETransparentProxyManager` / `NEDNSProxyManager` 下发配置,签名里缺了 `saveToPreferences` 直接 permission denied(见 2.8)

### 2.7 `$(MAC_PROXY_ICLOUD_CONTAINER)` 导致启动即崩溃
- 手工 `codesign` 不做构建变量替换,字面量 `$(MAC_PROXY_ICLOUD_CONTAINER)` 进了签名,内核校验 `entitlements ⊆ profile` 失败,SIGKILL "Code Signature Invalid"。
- **解决**:entitlements 里直接写死 `iCloud.com.commonuse.magic`。

### 2.8 主应用缺 NE entitlement → saveToPreferences permission denied
- 2.6 中我曾把主应用的 NE entitlement 删掉("宿主不需要"),错。补回 `app-proxy-provider`/`dns-proxy` 后配置可保存。

### 2.9 系统扩展激活成功但规则不生效(provider IPC 被拒)
- 症状:隧道启动、扩展 activated enabled,但任何规则都不命中;`nesessionmanager` 每秒刷:
  `process N is not entitled to establish IPC with plugins of type com.commonuse.magic`
- 即 App 通过 `sendProviderMessage` 下发规则/读取日志的 IPC 通道被 entitlement 检查拒绝。规则因此永远到不了扩展。
- **做过的签名实验(全部无效)**:baseline(=profile 授予集)/ +旧版布尔 `com.apple.developer.networkextension`(内核直接拒启动)/ +`get-task-allow`(同上)/ 换 Xcode 托管 Team Profile / +`keychain-access-groups`(完整复刻 Xcode 签名)。换 profile、重启、GUI/CLI 启动均复现。
- 对 nesessionmanager(iOS 18.2 伪代码 dump)的检查逻辑分析:私有 fallback 通道(`com.apple.private.*`)第三方拿不到;主检查路径按我们的 entitlement 集合应当通过,但 macOS 13 的透明代理会话(独立类 NESMTransparentProxySession,无公开 dump)实际行为不明。**根因未定位**,疑似与 Apple Development 证书 + macOS 13 组合有关(上游开发者用 Xcode 自动签名在新系统上开发,无法直接对比)。

### 2.10 解决方案:规则走 startTunnel options(Plan B 的最终形态)
- IPC 通道不可用的背景下试过两条路,都倒在"系统扩展是 root 进程"上:UserDefaults suite 在扩展里解析不到;App Group 容器路径 root/用户各一份。最终:**规则直接放进 `session.startTunnel(options:)`**——options 随 App 自己的会话进入扩展的 `startProxy(options:)`,不经过 provider IPC 的 entitlement 检查,一次启动就完成了规则交付。
  - `RuleManager.savedRulesPayload()` 生成规范化规则数组,GUI 启动隧道时随 options 下发
  - 扩展优先用 options 里的规则,为空再回退读容器文件 `proxybridge-rules.json`
- **教训(两轮)**:第一版用 `UserDefaults(suiteName:)` 做通道,在系统扩展进程里解析不到共享 suite(静默返回空);第二版改文件,发现**系统扩展进程以 root 运行**,`containerURL(forSecurityApplicationGroupIdentifier:)` 解析到的是 /var/root 的容器,与用户 App 写入的容器不是同一路径。最终方案:**规则随 `startTunnel(options:)` 传递**——options 属于 App 自己的会话,不经过 provider IPC 的 entitlement 检查,扩展在 `startProxy(options:)` 里直接拿到;共享容器文件保留为兜底。
- provider IPC 代码保留(其他环境可用)。
- 代价:运行中改规则不会实时生效(原靠 IPC 推送),需重启代理;连接记录等扩展→App 的上行通道(被同一 entitlement 检查拦截)不可用,App 的"连接记录"页拿不到数据。

### 2.11 系统扩展"替换"的连环坑
- **同版本激活是 no-op**:sysexd 只在"版本不同"时才走替换流程。只改代码提升 `CURRENT_PROJECT_VERSION` 还不够,`MARKETING_VERSION` 相同也会被无视 → 4.1.2→4.1.3 + build 8→9 后替换成功。
- **Launch Services 记录丢失**:替换后旧 staged 副本处于 "terminated waiting to uninstall on reboot",neagent 报 "Unable to find this application extension record in the Launch Services database" 且 `lsregister -f` 直接注册 staged 副本被系统拒绝(-10811)。
- **解决**:新增 CLI 开关 `ProxyBridge --reinstall-extension`(先 `deactivationRequest` 卸载、再 `activationRequest` 全新安装),并配合重启清理旧副本。

### 2.12 走了系统代理的应用不受透明代理规则约束
- 现象:给 Firefox 设了"阻止"规则(协议 TCP/UDP)后照样能上网。
- 原因:本机跑着 Clash Verge(系统代理模式),Firefox 的所有连接都发给 `localhost:7897`(verge-mihomo 的端口)——**环回(loopback)流量不被透明代理 divert**,扩展根本看不到这些连接,规则无从匹配。curl 被拦是因为 curl 默认不走系统代理。
- 排查命令:`lsof -iTCP -P | grep firefox`,连接全指向 localhost 即中招。
- 结论:测试规则前先关掉目标应用的代理设置(或退出 Clash Verge);两工具共存时,ProxyBridge 只能管到 `verge-mihomo` 进程自己的出站连接,管不到经它转发的应用流量。

---

## 3. 规则下发方案(重点)

### 3.1 演进史
| 阶段 | 通道 | 结果 |
|---|---|---|
| 0(上游原始设计) | provider IPC:`sendProviderMessage`(setRules/addRule/clearRules) | 本机被 entitlement 检查拒绝,见 §2.9 |
| 1 | App Group 的 `UserDefaults(suiteName:)` | 系统扩展进程里解析不到共享 suite,静默返回空 |
| 2 | App Group 容器里的 JSON 文件 | **系统扩展以 root 运行**,`containerURL` 解析到 /var/root 的容器,与用户 App 写入的不是同一路径 |
| 3(**当前**) | **`startTunnel(options:)`** | App 自己的会话通道,不经过 provider IPC 的 entitlement 门;扩展在 `startProxy(options:)` 里直接收到规则。已端到端验证 |

### 3.2 当前规则生效链路
1. GUI 点"启动代理" → `RuleManager.mirrorSavedRulesToSharedContainer()`(写容器文件 + suite,兜底用)
2. `session.startTunnel(options: ["rules": RuleManager.savedRulesPayload()])`
3. 扩展 `startProxy(options:)` → 优先用 options 里的规则 → 为空则回退读容器文件
4. 扩展日志出现 `Loaded N rule(s)` 即送达成功

### 3.3 当前已知限制
- **活动日志 / 连接记录页不显示**:扩展→App 方向(日志轮询、连接记录推送)走同样的 provider IPC,被同一 entitlement 检查拦截。排查扩展行为请用 Console.app 过滤 subsystem `com.commonuse.magic.extension`,或 `log show --predicate 'subsystem == "com.commonuse.magic.extension"'`。
- **规则不实时**:修改规则后必须 停止代理 → 启动代理 才生效(上游设计里的 addRule/clearRules 实时推送依赖 IPC,本机不可用)。
- **CLI 模式**(`--profile`)未接 options 通道,首跑靠容器文件兜底;文件写入早于隧道启动时不影响,但 CLI 与 GUI 互斥、且只应有一个在控制扩展。

### 3.4 高版本 macOS + Xcode 环境下切回 IPC 验证
换到 2018 年后机型(macOS 14+/26)+ Xcode 16 后,按此验证 IPC 是否恢复可用:
1. **观察门**:启动代理后执行
   `log show --last 5m --predicate 'process == "nesessionmanager"' | grep -c "not entitled"`
   结果为 0 且 App 活动日志出现 `Loaded N rule(s) from local storage`,说明 IPC 已通。
2. **实时性验证**:不改代码直接测——添加一条规则后**不重启代理**,让目标应用发起新连接。若新规则即时生效,说明 addRule/setRules 的 IPC 实时推送可用。
3. **代码层确认点**(如需恢复上游行为):`RuleManager.sendMessage` 的 completion 返回 success=true;`reloadAndStartTunnel` 里 `loadRulesFromUserDefaults` 成功返回 count。
4. **建议架构(任何环境都成立)**:保留 options 通道作为启动时的一次性全量下发(它总是有效),IPC 作为运行期增量通道(IPC 通的环境自动获得实时性)。当前代码已经就是这个形态,无需改动。

---

## 4. 解决方案汇总(当前架构)

```
git push → GitHub Actions (macos-latest, xcodebuild, CODE_SIGNING_ALLOWED=NO)
         → ProxyBridge-macOS.zip (universal, 未签名)
本机:Scripts/sign-local.sh (嵌入 cer/ 描述文件 + codesign --options runtime)
         → /Applications/ProxyBridge.app
首次/异常时:ProxyBridge --reinstall-extension(需先退出 GUI)
```

密钥/材料存放:
- 仓库 secrets 里留有 7 个(MACOS_* / APPLE_ID 等)——当前 workflow 已不使用,保留以备切回 Developer ID 方案
- 本机 `cer/`(gitignored):p12 + 密码 + 两张描述文件
- 本机 `~/.config/proxybridge-secrets/`：早期 base64 备份,可删

---

## 5. 后续方向

1. **根治 IPC 问题(优先级最高)**:
   - 装 Ghidra(`GHIDRA_INSTALL_DIR`)或 Hopper,逆向本机 `/usr/libexec/nesessionmanager` 的 `NESMTransparentProxySession` IPC entitlement 检查,弄清楚 macOS 13 到底要什么;
   - 或在 macOS 14+/Xcode 16 环境做一次对照实验(借机器即可,10 分钟),确认是否为 13 的系统怪癖。
2. **Developer ID + 公证路线**(如果想分发给别人或摆脱设备白名单):需要 Developer ID Application 证书私钥——团队里那张(d9b72…)私钥在谁手上就找谁导出,否则新建一张(本机钥匙串可做 CSR);之后在 portal 给 App ID 勾选系统扩展子项(需要 Xcode 能力界面,或借机),生成 Developer ID 描述文件,workflow 里现成的 secrets 机制可直接复用。公证只需 3 个 APPLE_ID 类 secrets,workflow 里已留好可选步骤。
3. **版本号纪律**:以后每次改扩展代码,`CURRENT_PROJECT_VERSION` + `MARKETING_VERSION` 都要递增;可考虑在 CI 里用 run number 自动注入。
4. **上游同步**:上游仓库活跃(issue #282 等),定期 rebase/merge 上游修复,注意保留我们的 bundle id/规则通道改动。
5. **使用注意**:Firefox 进程名是小写 `firefox`;规则在"启动代理"时生效,运行中修改需重启代理;CLI 模式(`--profile`)与 GUI 互斥。
6. **网络**:本机到 github.com 需代理;CI 产物下载走 `gh run download`(需代理环境变量)。
