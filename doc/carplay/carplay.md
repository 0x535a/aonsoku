# Aonsoku CarPlay 适配方案与实施计划

- 日期：2026-10-25
- 状态：首版代码已实施；本地验证与未验证范围见 [实施记录](implementation.md)。
- 使用场景：个人 iPhone 与真实 CarPlay 车机，不以 App Store 上架为目标。
- UI 决策：全部使用 Apple CarPlay 官方模板。

## 1. 目标与边界

在 CarPlay 上完成浏览音乐、选择播放、继续播放和基础播放控制，复用
Aonsoku 现有 iOS 原生播放、音乐库、鉴权和缓存能力。

首版必须支持从车机直接启动应用。手机界面没有打开、React 尚未挂载或
WKWebView 尚未加载时，原生层仍应能恢复队列、读取音乐库并响应播放。
这里的冷启动指系统允许启动应用的正常场景，不承诺绕过用户强制退出或
设备重启后首次解锁等系统限制。

CarPlay 是同一 iPhone 应用的另一套界面，不注册成新的协调设备，不创建
第二个播放器、播放队列、数据库或音频会话。手机和车机共享播放事实来源。

### 首版范围

- 首页：继续播放、最近播放、收藏歌曲。
- 音乐库：歌单、专辑、艺术家及对应的专辑/歌曲列表。
- 已下载：已完整缓存且实际文件可用的歌曲。
- 点击歌曲、专辑或歌单开始播放，保留来源、顺序和队列语义。
- 系统正在播放页：封面、曲名、艺术家、播放/暂停、上一首/下一首。
- 系统及模板支持的进度控制、随机/循环、待播列表与选择队列条目。
- 手机与车机状态同步；锁屏、后台、音频中断与离线播放。
- 未登录、未同步、空列表、服务器不可达及播放失败的模板内提示与重试。

### 暂不纳入首版

- Siri 点歌、车载搜索、电台入口。
- 车载跨设备选择、远程控制与接力 UI。
- 歌单编辑、下载管理、服务器设置和登录表单。
- 自绘播放器、WebView 车载页面、歌词、视频或额外动态封面展示。
- App Store 提审、上架材料和商店发布流程。

登录、服务器配置、首次完整音乐库同步和下载操作在手机端完成。没有登录
或尚无本地音乐库时，车机提供清楚的状态说明，不启动手机 Web 登录流程。

## 2. 已有能力与真实缺口

以下是实施前的代码现状，内部方法不等于已提供可直接使用的 CarPlay API。

| 能力 | 已有实现 | 需要补充或调整 |
| --- | --- | --- |
| 播放核心 | `AonsokuNativeAudioPlugin` 持有 AVPlayer、音频会话、恢复与中断处理 | 提取进程级服务，解除插件实例生命周期依赖 |
| 队列 | `NativeQueueEngine`，上下文队列、用户队列、随机/循环 | 通过共享服务暴露命令和可订阅快照 |
| 播放入口 | 插件内部已有按歌曲、专辑、歌单及索引播放的方法 | 原生类型接口、异步结果与错误反馈 |
| 系统控制 | `MPNowPlayingInfoCenter`、`MPRemoteCommandCenter` | 统一命令执行路径，覆盖恢复后首次播放，清除 JS 依赖 |
| 音乐库 | GRDB 与歌曲、专辑、艺术家、歌单 Repository | 车载分页查询、详情补取、变更通知 |
| 音源 | `NativeSourceResolver`、Keychain、原生 HTTP | 复用并验证冷启动下的音质偏好与鉴权 |
| 离线 | 音频缓存、缓存元数据、完整下载/流缓存机制 | 已下载查询和实际完整文件校验 |
| 播放持久化 | `PlaybackStatePersistence`、`PlaybackStateRepository` | 独立启动时幂等恢复，避免手机加载后再次恢复或重播 |
| 封面 | 原生封面缓存、Now Playing 静态/动态封面 | 浏览缩略图异步加载，保持现有锁屏行为 |
| 状态通知 | 主要由插件 `notifyListeners` 向 JS 发送 | 增加不依赖 Capacitor 的原生订阅，插件转发相同事实 |
| 车载宿主 | 尚无 CarPlay Scene 或模板控制层 | Scene 配置、模板导航、签名权限 |

关键代码位置：

- [AppDelegate.swift](../../ios/App/App/AppDelegate.swift)
- [SceneDelegate.swift](../../ios/App/App/SceneDelegate.swift)
- [Info.plist](../../ios/App/App/Info.plist)
- [AonsokuNativeAudioPlugin.swift](../../capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift)
- [NativeQueueEngine.swift](../../capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin/Audio/NativeQueueEngine.swift)
- [NativeSourceResolver.swift](../../capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin/Audio/NativeSourceResolver.swift)
- [PlaybackStatePersistence.swift](../../capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin/Audio/PlaybackStatePersistence.swift)
- [Repositories](../../capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin/Data/Repositories)
- [EventEmitter.swift](../../capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin/Data/EventEmitter.swift)

特别注意：当前 `AppDelegate` 为连接的 Scene 统一返回手机 `SceneDelegate`；
播放器在 Capacitor 插件 `load()` 时初始化，活动实例通过弱引用暴露给部分
原生调用。这两处不能直接用于车载独立启动。

## 3. Apple 官方模板与导航

| 界面 | 模板与行为 |
| --- | --- |
| 根界面 | `CPTabBarTemplate`，首页、音乐库、已下载三个 Tab |
| 分类、专辑、歌单、艺术家与歌曲 | `CPListTemplate`、`CPListSection`、`CPListItem` |
| 正在播放 | `CPNowPlayingTemplate.shared`，使用现有系统媒体信息 |
| 待播列表 | 从系统 Up Next 入口进入 `CPListTemplate` |
| 错误与状态 | 列表空状态或适用的系统提示模板，提供重试等有限操作 |

- 正在播放通过系统入口或模板按钮进入，不占用第四个 Tab。
- 播放页使用系统模板支持的随机/循环控件；进度交互由系统能力决定，
  不承诺每种车机都显示可拖动进度条。
- 隐藏或禁用不可用操作；电台等既有来源不显示歌曲专属的无效控制。
- 采用公开 API，遵守实际 SDK 的模板层级、条目和按钮限制；长列表分页，
  不一次装载整个音乐库。
- 列表加载、封面网络和数据库查询不得阻塞主线程。模板更新在主线程执行，
  所有列表选择回调必须完成，失败也要结束加载状态。
- 连接生命周期使用取消/版本标记，旧查询和封面回调不得更新新的 Scene。
- 支持系统明暗外观、触控与旋钮焦点；文字跟随应用语言，冷启动从原生偏好读取。
- 不将手机原生底栏、迷你播放器或 React 路由搬到车机。

## 4. 原生服务与模块边界

### 4.1 播放服务

新增 `NativePlaybackService`（暂定名），放在共享插件 Swift 包的 `Audio/`
目录。将现有播放器及其必要依赖逐步迁移，保持原有算法和行为。

```text
手机 React -> Capacitor 音频插件 ─┐
                              ├-> NativePlaybackService
CarPlay 模板 -> 原生控制层 ─────┘      -> AVPlayer / NativeQueueEngine
                                     -> 音源 / 持久化 / scrobble
                                     -> Now Playing / 系统媒体命令

CarPlay 原生控制层 -> CarPlayLibraryProvider
                      -> 现有 Repository / 原生 HTTP / 封面与音频缓存
```

- 服务负责播放器、队列、恢复、睡眠计时器、scrobble、音频中断及系统媒体发布。
- Capacitor 音频插件保留现有 JS 方法、事件名和数据兼容性，调用服务并转发事件。
- 服务通过原生接口提供快照与订阅；订阅先取得当前状态，并在释放时可取消。
- 初始化、队列恢复和媒体命令注册均幂等；不通过手工创建 `CAPPlugin` 实例
  或隐藏 WKWebView 来启动播放。
- CarPlay 断开只释放模板、控制器与订阅；共享播放服务继续按音频路由和
  中断策略工作，不因为 Scene 释放直接停止或强制恢复播放。
- 保留现有串行状态/加载约束，明确跨队列调用方向，避免同步互相等待。
- 第一批迁移保留现有业务语义，不顺带重写队列算法、动态封面或数据同步。

### 4.2 车载音乐库

新增 `CarPlayLibraryProvider`（暂定名），在插件包内复用内部 Repository，
向宿主提供有界的数据模型与异步查询，不公开全部数据库实现。

需要提供：最近播放、收藏、专辑、艺术家、歌单、详情歌曲与已下载列表；
结果包含稳定 ID、标题、副标题、封面标识、分页信息及可播放性。

- 本地数据优先；歌单详情等缺失时按需使用现有原生 HTTP 补取并写回。
- 不在车机连接时触发全库封面下载、全量同步或全盘文件扫描。
- “已下载”以完成记录和实际文件可用为依据，部分流缓存不能冒充完整下载。
  以现有下载/流缓存完成机制为准，实施前确认两种缓存的落盘规则。
- 最近播放需核实本地播放是否及时更新记录；若只依赖服务器同步的
  `playedAt` 会滞后，应补充最小必要的本地记录或更新路径。
- 原生数据变更可直接通知车载订阅者；现有 JS 数据事件继续保留。
- 账号退出或服务器切换时取消旧查询、清理车载快照，避免显示或播放旧账号数据。

### 4.3 命令契约

在 Swift 层提供类型明确的命令与状态模型，具体类型名在实现时确定：

- 基础控制：播放、暂停、切歌、跳转、随机、循环。
- 内容播放：按歌曲、专辑、歌单、列表索引建立上下文队列。
- 队列操作：读取当前实际顺序、选择具体条目。
- 状态快照：初始化状态、播放来源、当前条目、播放/缓冲状态、进度、
  队列、随机/循环及命令可用性。
- 错误结果：未登录、内容缺失、不可离线播放、网络失败、音源失败等。

“已接受命令”和“已经开始播放”分别表达；不能以同步 `Bool` 成功掩盖
后续查询失败。快速连续点击要有明确的最终生效顺序，过期请求不得覆盖新选择。

系统媒体按钮、手机桥接和车机调用共享执行路径。特别覆盖已恢复队列但
AVPlayer 尚未创建的首次播放，不能仅调用空播放器的 `play()`。

## 5. Scene、协调与系统集成

- 宿主新增 `CarPlaySceneDelegate`，实现 `CPTemplateApplicationSceneDelegate`。
- `Info.plist` 配置 `CPTemplateApplicationSceneSessionRoleApplication`；
  `AppDelegate` 按 Scene role 分流，保留手机 `SceneDelegate` 的现有路径。
- 核实多 Scene 配置与手机/CarPlay 共存行为；不因此开放多个手机窗口，
  不重建或替换已有手机 WKWebView。保留 iOS 26 原生底栏及旧系统 Web 导航。
- 沿用当前 iOS 15 目标；逐项核实 API availability，而非提升到 iOS 26。
- 冷启动先恢复原生偏好、凭据和数据依赖，再恢复播放状态；恢复本身不自动出声，
  用户选择继续播放或内容后才开始播放。
- Now Playing 和媒体命令仍只有一个所有者；保留现有锁屏静态/动态封面设置、
  资源保护和发布顺序，不为车机另建动画生成流程。
- 现有协调插件对活动音频插件的调用应改为服务接口，保留 session/generation
  与快照语义，不能绕开现有接力事务。
- 首版不提供远程控制 UI。若共享状态正在投影其他设备，车机明确显示该状态，
  禁用相关控制和新内容播放，提示在手机切回本机；不静默接管或控制远端。
  本机采用已提交的接力队列时，正常展示并控制本机播放。
- 车载独立启动不以协调 WebSocket 建连为播放前提；不得新建另一套协调客户端。

## 6. 个人使用与签名权限

不需要准备 App Store 发布流程，但真实 iPhone 上的 CarPlay 能力仍受系统
entitlement 与 provisioning profile 控制。

- 所需音频权限：`com.apple.developer.carplay-audio`。
- 按 Apple 流程申请对应 managed capability，配置 App ID 和签名 profile。
- 普通侧载不会自动授予权限；不能把免费个人签名当作已满足权限条件。
- 实施前确认所用开发者账号是否可申请、是否已获批；这是待确认的环境条件，
  不阻塞服务提取、模拟器开发和离线测试。
- 未获权限时可验证模拟器路径，不能据此宣称真实车机已可用。
- 不使用私有 API、越狱或绕过权限的方法作为实施方案。
- 确保未获 CarPlay 权限时仍有可构建、可签名的普通手机配置，避免新增权限
  阻断日常手机构建；有权限后检查真机包的实际签名 entitlement。

## 7. 分阶段实施与交付

### 阶段 1：最小 Scene 与工程配置

- [x] 添加 Scene 分流、CarPlay Scene、最小官方模板和受控签名配置。
- [ ] 核实 iOS 15 API、模板限制与多 Scene 行为。
- [ ] 确认个人设备权限申请/签名路径，并记录实际验证环境。

验收：模拟器 CarPlay 出现应用，手机原有导航正常，未授予权限的手机构建
路径仍可用。此阶段仅验收工程入口，不宣称支持独立播放。

### 阶段 2：提取共享播放服务

- [x] 迁移播放器所有权、队列、恢复、系统媒体控制与必要附属能力。
- [x] 插件委托服务，保留现有 JS 契约；协调调用切换到服务。
- [x] 提供原生状态订阅、异步命令结果及幂等初始化。
- [ ] 回归锁屏封面、scrobble、睡眠计时器、恢复和接力。

验收：不加载 WebView 即可恢复并由用户命令开始播放；手机随后加载不会
重新加载音源、覆盖队列或重复注册媒体按钮。所有入口共用同一播放器。

### 阶段 3：模板浏览与播放闭环

- [x] 实现三个 Tab、层级列表、分页、封面和状态提示。
- [x] 接入最近播放、收藏、音乐库、已下载与按需详情补取。
- [x] 接入系统正在播放页、随机/循环和待播列表。
- [x] 补齐变更订阅、账号变化、异步取消与过期回调保护。

验收：从车机独立完成浏览、选歌、播放和切歌，手机显示同一队列和状态；
无网络时已下载内容可用，未下载内容失败时不无限加载。

### 阶段 4：自动化验证与异常回归

- [x] 添加不依赖真实服务器、Keychain 或车机的原生契约测试。
- [ ] 添加模拟器模板/Scene 验证及可复现的测试数据。
- [ ] 验证下面的验收矩阵，记录失败与修复结果。
- [x] 更新 `AGENTS.md` 的实际架构、模块所有权和可运行测试命令。

验收：针对变更的检查和现有相关回归通过。新增测试脚本落地后再记录正式命令，
本文不将拟议脚本描述为已存在。

### 阶段 5：个人设备安装与真车验证

- [ ] 检查 App ID、profile、实际签名包与 entitlement 一致。
- [ ] 安装到个人 iPhone，在可用的有线/无线 CarPlay 环境测试。
- [ ] 记录 iOS 版本、车机、连接方式、日志与未验证项目。

验收：真车完成启动、浏览、播放、锁屏、中断和断连测试；模拟器通过与
真车通过分别记录，不以其一替代另一项。

## 8. 验收矩阵

| 场景 | 预期 |
| --- | --- |
| 手机先启动、车机后连接 | 沿用当前播放，不重建队列或播放器 |
| 仅车机冷启动 | 不依赖 WKWebView，显示本地库并响应播放 |
| 恢复队列后首次继续播放 | 创建所需音源，恢复正确进度，不从头重播 |
| 车机启动后再打开手机 | React 从原生读取状态，不覆盖车机选择 |
| 重复连接、断开、重连 | 无重复监听、旧回调更新或额外播放器 |
| 锁屏、前后台切换 | 控制与播放保持正确，原生订阅不依赖 JS 活跃 |
| 弱网、断网、恢复联网 | 已下载可播；失败可重试，不无限缓冲 |
| 缓存被清理或只有部分缓存 | 不误标完整下载，播放失败有反馈 |
| 快速连点不同歌曲/歌单 | 最终选择一致，旧查询不回写新队列 |
| 随机、循环、用户队列、重复歌曲 | 与现有队列顺序一致，能区分具体队列条目 |
| 来电、Siri、导航提示音、路由变化 | 遵循音频中断策略，不误恢复用户已暂停的播放 |
| 收藏/最近播放/数据同步变化 | 车机列表更新，不要求 JS 转发 |
| 退出账号或切换服务器 | 取消旧任务，不展示旧账号数据 |
| 远端投影或接力中 | 不操作错误设备，不破坏既有接力事务 |
| 不同尺寸、明暗主题、旋钮焦点 | 官方模板可用，无自绘布局依赖 |

实施中优先运行现有相关检查：

```bash
node scripts/ios/test-playback-sync.mjs
node scripts/ios/test-dynamic-cover-interface.mjs
```

修改手机宿主时，按现有条件运行原生 shell 测试；修改共享 TS 契约时运行
相关单元测试与类型检查。准备原生 App 包时遵循现有 mobile 构建路径：

```bash
pnpm run build:mobile
pnpm exec cap sync ios
```

`cap sync` 会更新原生资源，必须先有对应的 mobile 构建。实际 iOS App
编译、签名和模拟器测试按仓库现有 Xcode 工程执行，并在实施记录中注明配置。

## 9. Apple 参考资料

- [CarPlay 概览](https://developer.apple.com/carplay/)
- [申请 CarPlay entitlement](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [通过 Scene 与模板显示内容](https://developer.apple.com/documentation/carplay/displaying-content-in-carplay)
- [CPTemplateApplicationSceneDelegate](https://developer.apple.com/documentation/carplay/cptemplateapplicationscenedelegate)
- [CPNowPlayingTemplate](https://developer.apple.com/documentation/carplay/cpnowplayingtemplate)

模板数量限制、系统可用性和签名细节，以实施时所用 SDK 与 Apple 官方文档为准。
