# 接手说明(新 Mac + Xcode,小白向)

> 这份文档写给接手本工程的人。你拿到的是一份**已经调好功能**的 macOS 透明代理客户端(基于开源项目 [InterceptSuite/ProxyBridge](https://github.com/InterceptSuite/ProxyBridge) 修改)。
> 与原开发者的约定:**他会单独交给你签名材料**(Apple Development 证书的 p12 文件 + 密码 + 两张描述文件,描述文件里已包含**你这台 Mac 的 UDID**)。团队、Bundle ID、所有配置都不用改,装完材料直接 Build & Run。
> 按本文档顺序操作,顺利的话 15 分钟跑起来。

---

## 0. 你需要准备什么

| 项目 | 要求 |
|---|---|
| Mac | 2018 年及以后的机型(ARM 或 Intel 均可) |
| macOS | 14(Sonoma)或更新 |
| **Xcode** | **16 或更新** ⚠️ 工程是 Xcode 16 格式(objectVersion 77),Xcode 15 打不开;App Store 装最新版即可 |
| 签名材料 | 对方单独给你:`cer_file.p12`(证书+私钥)、p12 密码、两张 `.provisionprofile` 描述文件 |

> 不需要你自己有 Apple Developer 账号——签名用的账号/团队是对方的,你只是在他授权的设备和描述文件范围内开发。

## 1. 交接前:给对方(原开发者)做的事

> 这一节写给**交出工程的人**,确认完成后把材料交给对方。
1. 拿到对方这台 Mac 的 UDID:对方在终端执行 `system_profiler SPHardwareDataType | grep "Hardware UUID"`,把字符串发给你
2. 到 [Devices](https://developer.apple.com/account/resources/devices/list) 点 **+** 注册这台设备(填名称 + 刚才的 UUID)
3. 到 [Profiles](https://developer.apple.com/account/resources/profiles/list) **重新生成两张描述文件**(`macCommonUse`、`macCommonUseExtension`,编辑 → 勾选新设备 → 保存 → 下载):
   - 类型保持 **Development**
   - 证书保持选 Apple Development: aoqiang he
4. 把以下材料通过**安全渠道**(不要发微信群/邮件正文)交给对方:
   - `cer/cer_file.p12`
   - `cer/p12密码.txt`
   - 刚下载的两张 `.provisionprofile`

## 2. 拿到代码和材料

```bash
git clone https://github.com/koploop/my-proxy-bridge.git
cd my-proxy-bridge
```

(或直接解压 zip。)⚠️ 仓库里**没有**签名材料(被 .gitignore 排除),p12 和描述文件靠对方单独发给你。

**收到材料后注意保密**:p12 = 能冒用对方开发者身份签名的私钥,留在自己电脑里用,不要外传;也不要把它提交进任何 git 仓库。

## 3. 安装签名材料(3 分钟)

把对方给的三个文件先放到一个临时目录(假设都在 `~/Downloads/handoff/`):

```bash
# 1. 导入证书+私钥到钥匙串(会提示输入 p12 密码;也可以在第 2 步的双击方式里输)
security import ~/Downloads/handoff/cer_file.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -P "$(cat ~/Downloads/handoff/p12密码.txt)" \
  -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "$(cat ~/Downloads/handoff/p12密码.txt)" ~/Library/Keychains/login.keychain-db

# 2. 安装两张描述文件
mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
cp ~/Downloads/handoff/*.provisionprofile ~/Library/MobileDevice/Provisioning\ Profiles/

# 3. 验证:应该看到 "Apple Development: aoqiang he (PZ257V6YP5)"
security find-identity -v -p codesigning | grep "Apple Development"
```

> 不喜欢命令行的话:双击 `.p12` 文件 → 选"登录"钥匙串 → 输密码;两张 `.provisionprofile` 也直接双击,系统会装到正确位置。装完在"钥匙串访问"里应能在"我的证书"看到 `Apple Development: aoqiang he`。

## 4. Xcode 构建(5 分钟)

1. 双击打开 `ProxyBridge.xcodeproj`(首次打开选 Trust)
2. 什么都不用改——签名配置(团队 P57F6K6J34、描述文件名、entitlements)都已提交在工程里
3. 直接 **Build & Run**(⌘R)。第一次构建可能问是否允许 codesign 访问钥匙串,选"始终允许"
4. 如果签名报错:
   - *"No profiles for ... were found"* → 第 3 步的描述文件没装好,检查文件名是 `macCommonUse`/`macCommonUseExtension`(在 Xcode 的 Signing 页能看到期望名)
   - *"doesn't include the currently selected device"* → 你的 Mac UDID 不在描述文件里,让原开发者按 §1 重新生成描述文件
   - 钥匙串弹窗不停 → 重跑第 3 步的 `set-key-partition-list` 那行

## 5. 首次运行

1. App 启动后点 **启动代理**
2. macOS 首次会要求批准系统扩展:**系统设置 → 隐私与安全性** → 找到"来自开发者 aoqiang he 的系统扩展"→ 点 **允许**(可能要输密码),回 App 再点一次启动代理
3. 显示代理运行中 = 成功。以后每次 Build & Run 都直接可用

## 6. 验证功能(照做一遍)

```bash
# App 里加一条规则:进程名 curl、动作「阻止」,然后 停止代理 → 启动代理
curl https://ifconfig.me
# 预期:卡住或报错 = 规则生效 ✅(显示出 IP = 没生效,见下方排查)
```

再测代理转发:把 curl 规则动作改成「你的 SOCKS5 服务器」,重启代理再跑一次,显示的应是**服务器的 IP**。

### 两个常见坑(来自实战经验,详见 BUILD_NOTES.md)

1. **浏览器规则不生效?** 先检查浏览器是否配了代理(如 Clash Verge 的 127.0.0.1:7897)。**走环回代理的流量透明代理管不到**。测试时关掉浏览器代理设置。
2. **改规则后没反应?** 规则在"启动代理"时下发,**改完必须停止 → 启动**才生效。

## 7. 你的环境比原开发者好(预期差异)

原开发者在旧 Intel Mac(macOS 13)上遇到系统怪癖:App↔系统扩展的 IPC 被系统拒绝,导致**规则不实时**(改规则要重启代理)、**连接记录页不显示**。你的系统较新,IPC 大概率正常:

- 若 App 的"连接记录"页能看到实时连接 → 全功能 ✅
- 验证方法见 `BUILD_NOTES.md` §3.4

即使 IPC 仍被拦也不影响核心功能:规则下发走 `startTunnel(options:)` 通道,只是少了实时性和连接记录展示。

## 8. 常见问题 FAQ

**Q: 需要注册 Apple Developer 账号吗?**
不需要。你用的是对方的团队、证书和描述文件,材料装好后 Xcode 直接构建。

**Q: 材料会过期吗?**
会。证书和描述文件都到 **2027 年 11 月** 到期。到期后让原开发者重新生成描述文件;证书到期需对方重新签发(流程见 BUILD_NOTES.md §5)。

**Q: 我改了代码想发给别人用?**
开发签名的 App 只能在你注册的这台 Mac 上跑。要分发必须走 Developer ID + 公证(需对方配合,见 BUILD_NOTES.md §5),或让对方也拿到材料自己构建。

**Q: 仓库里的 GitHub Actions 工作流能用吗?**
能,push 到你自己的仓库即可(产物是未签名的 universal 包;有 Xcode 就用不到本地签名脚本 `Scripts/sign-local.sh`)。工作流不需要任何 secrets。

**Q: 构建时 macOS 弹"无法验证开发者"?**
只在直接分发 .app 给别人时才会遇到,自己 Build & Run 不会。确需运行时:右键 App → 打开;或 `xattr -dr com.apple.quarantine ProxyBridge.app`。

**Q: 许可?**
遵守上游 LICENSE(仓库根目录)及其再分发要求。

## 9. 相关文档

- `BUILD_NOTES.md` —— 原开发者的完整排障记录,遇到怪问题先查这里
- `README.md` —— 功能使用说明
- `Scripts/sign-local.sh` —— 无 Xcode 场景的本地签名脚本(你有 Xcode,用不到)
