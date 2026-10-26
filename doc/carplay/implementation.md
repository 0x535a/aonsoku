# CarPlay 首版实施与个人设备测试

日期：2026-10-25。范围以 [适配方案](carplay.md) 为准。

本次只进行命令行编译与离线/模拟器测试。不连接真机，不向个人 iPhone 安装，
不执行真车测试。真实 CarPlay 连接、模板导航和车机音频路由由用户安装后验证。

## 已实现

- 独立 CarPlay Scene 与手机 Scene 分流，保留单个手机窗口和 WKWebView。
- Apple 官方三 Tab 列表：主页、音乐库、已下载。
- 最近播放、收藏、歌单、专辑、艺术家与歌曲列表，上一页/下一页、异步封面。
- 共享 `NativePlaybackService`，独立于 Capacitor 插件初始化和存活。
- 保留原有手机 JS 接口和事件；协调与动态封面消费者改为调用共享服务。
- 原生冷启动恢复队列/进度，播放、暂停、切歌、随机/循环和系统播放页。
- 待播列表按实际播放顺序显示当前条目、用户队列及剩余上下文队列；支持分页、
  按具体出现位置选择重复歌曲，并拒绝队列变化后的旧条目。
- 原生数据变更通知、初始状态订阅、连接断开取消及过期结果保护。
- 账号/服务器变化时取消车载请求、清除播放状态并使音源凭据缓存失效。
- 远端播放投影期间禁用车载播放操作，不自动接管远端会话。
- 根据原生语言偏好提供中文/英文文案，使用系统外观和焦点交互。

浏览列表和待播列表按运行时 `CPListTemplate.maximumItemCount` 尽量完整显示，
仅超过系统上限时分页，并为上一页/下一页预留条目位置。翻页记录实际偏移，
不再使用固定的 40/100 条步长。系统未公开触底回调，因此保留超长列表的手动翻页。
最近播放、收藏和下载内容以实际显示页作为播放上下文。
专辑和歌单点击播放保留完整的来源
上下文及重复歌曲；最近播放、收藏与已下载使用所显示的一页作为播放上下文，
避免从这些入口一次装载整个音乐库。

最近播放合并原生历史与歌曲 `playedAt`；本机开始播放会更新本地歌曲时间。
已下载查询读取缓存索引，并核对完成元数据、实际文件与索引大小，不把临时流
缓存作为完整下载。歌单详情缺失时通过现有原生 Subsonic HTTP 补取。

选歌准备设置 15 秒总超时；超时显示可重试错误，不再持续等待列表条目回调。
取消或被新选择替代时立即结束旧条目的转圈；迟到结果不能再替换播放队列。
原生 `CarPlay` 日志记录选歌准备的开始、接受、失败与超时。此超时只涵盖
选歌准备，不表示音频已缓冲完成；音频加载仍由现有播放器处理。

## 本地检查

```bash
# 不访问真实服务器/凭据，使用临时 SQLite 与 URLProtocol
node scripts/ios/test-carplay-library.mjs

# 需已有 booted iPhone Simulator；自动构建、安装和清理独立 QA 包
node scripts/ios/test-carplay-simulator.mjs

# 现有相关回归
node scripts/ios/test-playback-sync.mjs
node scripts/ios/test-dynamic-cover-interface.mjs
pnpm exec vitest run src/native/audio
pnpm run lint
```

音乐库测试需要先解析 Xcode 项目的 GRDB 依赖。脚本会从本地 DerivedData 或
CarPlay 测试构建目录查找；也可用 `AONSOKU_GRDB_PATH` 指向本地 GRDB checkout。
模拟器脚本可用 `AONSOKU_CARPLAY_PACKAGES` 指定 Swift Package 缓存目录。

模拟器 QA 使用 `github.realtvop.aonsoku.carplay-qa` 包名，只有同时满足 Debug、
模拟器、该包名后缀及显式环境变量时才运行。它使用生成的静音 WAV，正常手机
入口不创建 WKWebView。结果位于 `/tmp/aonsoku-carplay-qa/results.json`，构建
日志位于同目录 `build.log`。Release 不包含这个测试入口。

已验证范围：

- 模拟器目标编译；独立 QA 的冷恢复、恢复后播放、重复启动、暂停/循环、
  旧队列选择拒绝、队列分页、清空以及无 WKWebView。
- 官方三 Tab 与 `CPListTemplate` 对象构建。
- 音乐库分页、完整专辑/歌单上下文、重复歌曲、最近播放/收藏、下载完整性、
  未登录/HTTP 失败和请求仅完成一次。
- 原有音源解析、队列与桥接契约、动态封面发布/租约检查和 Biome lint。

Release 的 iPhoneOS SDK 编译也已通过（`generic/platform=iOS`、关闭签名），
这只是离线编译，没有连接或运行真实 iPhone。

全仓 `pnpm exec tsc -b` 未通过：当前与实施前基线 `f54d33cb` 均有 348 项
既存诊断。使用独立 worktree 比较、归一化绝对路径和等价联合类型的打印顺序后，
未发现本次新增诊断；原有全仓类型问题未在此适配中扩展处理。

这些检查没有建立实际 CarPlay 连接，不能替代车机上的列表导航、触控/旋钮、
音频中断、重连、锁屏封面表现及协调接力的整体验证。

## 安装到个人 iPhone

### 1. 准备手机资源与工程

```bash
pnpm install
pnpm run build:mobile
pnpm exec cap sync ios
```

打开 `ios/App/App.xcodeproj`，选择自己的开发者团队和设备。首次使用先在手机
完成服务器登录和音乐库同步，离线测试前准备至少一首完整下载。

### 2. CarPlay 权限与设备签名

CarPlay Audio 权限已获批，工程的 Debug 和 Release（含 Archive）默认使用
`App/CarPlay.entitlements`，其中 `com.apple.developer.carplay-audio` 为 `true`。
模拟器同样使用此文件，无需再手动传入构建参数。

在 Apple Developer 的 Certificates, Identifiers & Profiles 中，为实际签名的
App ID（工程默认 Bundle ID 为 `github.realtvop.aonsoku`）启用获批的 CarPlay
Audio capability。工程保留 Automatic Signing；在 Xcode 中选择获批权限所属的
开发者团队，使签名使用包含该权限的 provisioning profile。如果使用手动签名，
需重新生成并下载启用了该 capability 的 development/distribution profile。

需要不带 CarPlay 签名的普通手机包时，可在 App target 的 Build Settings 中将
`AONSOKU_ENTITLEMENTS` 改为 `App/App.entitlements`，或在 `xcodebuild` 中传入
`AONSOKU_ENTITLEMENTS=App/App.entitlements`。此覆盖不影响模拟器的 CarPlay 权限。

项目现有 CI 生成的 unsigned IPA 不等于已启用 CarPlay；重新签名时必须保留该
entitlement，且 profile 必须允许它。仅修改 Info.plist 或安装 unsigned IPA
不足以启用。Apple 配置说明：
[Requesting CarPlay Entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)。

可在 Mac 对最终签名后的 `.app` 检查实际权限：

```bash
codesign -d --entitlements :- /path/to/App.app
```

### 3. 建议真机测试顺序

1. 手机正常播放，连接车机，确认没有重播、重置进度或重复音频。
2. 打开 CarPlay 的 Aonsoku，检查三个 Tab、音乐库详情及上下页导航。
3. 从车机选择歌曲、专辑和含重复歌曲的歌单，检查手机队列同步。
4. 在系统播放页验证暂停/继续、上下首、随机、循环和待播条目选择。
5. 手机锁屏后继续切歌；在系统允许的正常冷启动场景下，从车机独立打开应用。
6. 断网播放已下载歌曲；尝试未下载内容并恢复网络，检查错误与重试。
7. 检查电话、Siri、导航提示音、有线/无线断连及重连后的行为。
8. 如果使用跨设备协调，确认远端投影时车载操作被禁用，本机接力完成后可控。

请记录 iOS 版本、车机/接收端、连接方式、操作步骤和期望/实际结果。
本轮不自动执行上述真机步骤，也不修改开发者账号或申请权限。
