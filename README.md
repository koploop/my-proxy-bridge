# 代理桥

代理桥是基于 [ProxyBridge](https://github.com/InterceptSuite/ProxyBridge) macOS 版本改编的 Swift / SwiftUI SOCKS5 客户端。它通过 Network Extension 转发应用流量，操作布局参考 [Proxifier 的规则管理](https://www.proxifier.com/docs/mac-v2/rules.htm)。

## 构建与安装

1. 使用 Xcode 26 或更新版本打开 `ProxyBridge.xcodeproj`。应用最低支持 macOS 13。
2. 为主应用 `com.macproxybridge.client` 和系统扩展 `com.macproxybridge.client.extension` 准备对应的签名与描述文件。两个目标使用同一 Apple 开发团队，均需授权 Network Extension，主应用还需 System Extension 安装权限。若更换 Bundle ID，同步修改扩展标识和 App Group。
3. 使用 Release 配置构建。可通过下列命令传入团队 ID 和两个 Developer ID 描述文件的名称。

   ```sh
   xcodebuild -project ProxyBridge.xcodeproj -scheme ProxyBridge -configuration Release \
     MAC_PROXY_TEAM=你的团队ID \
     MAC_PROXY_APP_PROFILE='主应用描述文件名' \
     MAC_PROXY_EXT_PROFILE='系统扩展描述文件名' build
   ```

4. 将构建的 `ProxyBridge.app` 放进 `/Applications`，打开后点击“启动代理”。按 macOS 提示在系统设置中批准系统扩展与网络配置。

## 使用

1. 点击“代理服务器”，添加 SOCKS5 主机和端口。服务器需要认证时填写用户名和密码。点击“测试”检查连通性、延迟及 UDP ASSOCIATE 支持情况。
2. 点击“代理规则”，按应用进程名或包标识符、目标主机和端口建立规则，动作可设为直连、阻止或指定服务器。规则按列表顺序匹配，可用箭头调整优先级。未匹配的流量默认直连。若要设置兜底代理，将匹配任意应用和目的地的规则放在列表末尾。
3. 点击“启动代理”，在“连接记录”查看应用、目标和代理，在“活动日志”查看启动和扩展诊断。可在“配置方案”菜单切换、导入或导出配置。
4. TCP 支持按目标匹配。UDP 转发需要 SOCKS5 服务器支持 UDP ASSOCIATE，UDP 规则按应用匹配。域名匹配和向上游发送域名依赖“启用 DNS 代理”。配置方案包含代理认证信息，请妥善保管导出文件。

许可证及原项目版权见 [LICENSE](LICENSE)。
