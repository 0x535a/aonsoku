# Aonsoku — iOS 与 iPadOS 原生导航及迷你播放器改造目标

## 项目背景与范围

- 仓库：https://gitlab.com/stephenzeng/aonsoku
- Aonsoku 目前具有 Home、Library、Search 三个主要入口，以及展示封面、曲目与播放控制的迷你播放器（MiniPlayer）。
- 希望将导航和迷你播放器升级为符合 iOS 与 iPadOS 设计语言的原生交互体验，同时尽量保留现有音乐业务逻辑和页面实现。
- **本次仅覆盖 iOS（iPhone）与 iPadOS（iPad）。** 两种移动端形态统一产品能力、视觉语言和播放状态，但导航位置、控件形态及交互可以随设备与窗口尺寸自适应。
- 本文只定义目标与验收要求。现有 iOS/iPadOS 技术栈、导航结构与可行改造路径，由本地 Agent 阅读仓库后确认。**macOS 不在本次改造范围内。**

## 一、移动端核心目标

### 1. 原生导航体验

- 保留 Home、Library、Search 的语义、功能和导航层级，让用户能够清晰识别当前所在位置。
- 优先采用目标系统公开、受支持的原生导航能力及视觉材质（包括支持时的 Liquid Glass），而非仅通过 Web 样式模拟。
- 保持与系统惯用交互一致：iPhone 偏底部 Tab，iPad 允许顶部 Tab / Sidebar 等自适应布局。
- 支持触控、硬件键盘、指针及无障碍操作中对应设备实际具备的输入方式。

### 2. 原生迷你播放器

- 保留封面、曲名、艺术家、播放/暂停、下一首、进入完整播放器等核心交互，并根据可用空间调整信息密度和控件位置。
- 导航与 MiniPlayer 在视觉上保持协调，呈现精致、轻量、克制的 Apple 平台原生质感；不要求复刻 Apple Music。
- 播放中的封面、元数据、播放状态、队列与进度变化及时同步，不允许 Web 界面与原生界面显示互相矛盾的状态。
- 页面切换、屏幕旋转、窗口尺寸变化、MiniPlayer 展开或收起均不得中断音频、重建播放队列或丢失播放状态。
- 无可播放内容时，迷你播放器应合理隐藏或降级，不保留无意义的空白区域。

### 3. 自然过渡与适度动效

- 以系统原生动效和布局能力为优先，保持导航切换、迷你播放器收起/展开及全屏播放器入口的连续性。
- 如果系统及现有页面结构允许，支持导航随滚动或空间变化收起、简化；如果不可行，应提供稳定的替代体验。
- 支持减少动态效果、降低透明度等系统辅助功能设置；避免过度动画影响长列表性能和音频播放。
- 第一阶段可以保留已有完整播放器页面，不将其整体原生化作为前置条件。

## 二、平台差异化目标

### iOS（iPhone）

- 优先采用系统级原生底部导航，支持 Home、Library、Search 的清晰切换。
- MiniPlayer 与底部导航构成自然协调的底部交互区，在空间合适时展示完整信息，紧凑时保留核心控制。
- 充分适配 Home Indicator、安全区域、键盘弹出、不同屏幕尺寸、屏幕方向和页面滚动。
- 保持已有后台音频、锁屏播放控制、播放队列及离线播放行为。

### iPadOS

- **不能仅将 iPhone 底部栏按比例放大。** 导航形式应随窗口尺寸、横竖屏以及系统布局规则自适应，可研究顶部 Tab、Sidebar 等更符合 iPadOS 的形态。
- MiniPlayer 应与导航的变化协调，避免在大屏下形成不必要的固定底部空白，或在窄窗口下遮挡内容。
- 考虑分屏、窗口缩放、Stage Manager 及外接显示器等场景，优先响应实际窗口尺寸而不是固定设备型号。
- 支持触控、硬件键盘、鼠标和触控板；合理提供焦点、悬停及快捷键交互。
- 页面内容、滚动位置及播放器状态应在窗口尺寸与布局形态切换时保持稳定。

## 三、与 Aonsoku 现有架构集成

- 尽可能保留 React + Capacitor 中既有页面、路由和音乐业务逻辑，以及移动端已经稳定运行的音频服务。
- 原生导航选择、Web 路由、播放器 UI 与实际播放状态保持同步，包括页面内跳转、返回、外部事件及 iPadOS 多窗口场景（若适用）。
- 优先最小化不必要的 WebView、音频服务和全量视图重复实例，控制内存与桥接开销。
- 处理好原生控件与页面内容的实际占用区域，避免列表底部、搜索输入、弹窗及滚动操作被遮挡。
- 保持深色主题及品牌辨识度，同时尊重 iOS/iPadOS 系统外观和辅助功能偏好。
- 不因本阶段改造而连带要求 AI 动态专辑封面生成、播放器页面整体重构或音乐数据层重构。

## 四、约束与优先级

1. **播放稳定性优先**：音频播放与媒体控制不得因 UI 改造退化。
2. **平台原生习惯优先**：统一设计理念，但允许 iPhone 与 iPad 采用不同的导航布局。
3. **现有架构优先**：先调查真实平台目标与工程现状，再选择必要的原生组件及桥接方案；不预设 UIKit、SwiftUI 等具体技术。
4. **响应式与性能优先**：以实际窗口和可用空间驱动布局，避免无谓的常驻资源占用。
5. **可渐进落地**：允许分别针对 iPhone 和 iPad 实现与验证，其他功能尽量保持不变。

## 五、验收标准

- iPhone 上，原生底部导航与 MiniPlayer 正确展示和响应操作；滚动及布局变化时体验自然。
- iPad 上，横竖屏与不同窗口宽度下导航及播放器合理自适应，分屏/窗口调整不导致控件遮挡或播放状态丢失。
- iOS/iPadOS 上的歌曲、封面、播放状态、进度及导航选中状态保持一致。
- 打开/关闭完整播放器、切换页面、进入后台、恢复前台及系统媒体控制均不引入明显回归。
- 不产生多余播放器实例、明显额外内存开销、错位安全区域、窗口布局故障或不可预期的原生/Web 状态冲突。
- 若某个系统版本不支持新的材质或布局行为，应有符合 iOS/iPadOS 习惯且功能完整的回退体验。

## 本地 Agent 自主工作范围

先检查仓库中 **iOS/iPadOS 的实际工程、入口、导航实现、播放器架构和支持状态**，再自行确定技术可行性、实施范围、适配方案、桥接方式、依赖和测试策略。

本文只描述产品目标与验收标准，不规定实现步骤或具体 API。如 iPhone 与 iPad 不能在同一轮完成，可提出分期方案；不得将 iPhone 布局机械套用到 iPad，或为统一代码而牺牲平板体验。

## 当前实现（2026-10-15，参照 example）

实际工程是 React + Capacitor 8、最低 iOS 15。iOS 26+ 现在使用 `AonsokuNativeTabController`（UIKit `UITabBarController`）作为根控制器，配置 `.tabSidebar` 与 `.onScrollDown`，通过 `UITabAccessory` 安装迷你播放器。iOS 15–25 保留原 Web 导航和播放器。

- **系统排布**：UIKit 负责 Tab/sidebar、玻璃背景、安全区及 accessory 的 regular/inline 转换。常规态展示 36pt 封面、曲名、艺人、播放/暂停与下一首；inline 态封面缩至 30pt，隐藏艺人及下一首，高度 44pt。控件不再自己画独立玻璃卡片。系统动效和材质遵守辅助功能设置，文字使用动态字体，控制支持 VoiceOver 和指针。
- **单一内容实例**：三个 UITab 的轻量容器只承载同一个 `AonsokuViewController`/WKWebView。切换时移动既有 controller，清理旧约束及滚动观察，再把 WebView 的 UIScrollView 注册为当前容器的 `contentScrollView`；不创建新 WebView、音频服务或队列。Info.plist 移除了 Main storyboard 的自动根控制器声明，避免在程序化 SceneDelegate 入口之外额外构造 bridge。
- **路由一致**：使用现代 `shouldSelectTab` 发送用户点击意图（含重复点击当前 Tab）；`didSelectTab` 只同步容器，不发送导航。程序化更新 selectedTab 期间禁止回传用户点击事件。React Router 管理页面历史/KeepAlive；点击 Tab 与 Web 底栏一致，始终进入对应一级路由，不恢复上次二级页面，页面内跳转反向更新系统选中项。本地化直接更新既有 UITab 标题，不重建容器。
- **内容与留白**：隐藏重复 Web 底栏、播放器、侧栏及失效的 Web 侧栏切换按钮；宽窗口保留 Web 顶栏的搜索与账户。系统侧栏采用 tile 布局，页面随其宽度重新布局。顶部/底部占用根据系统 Tab/accessory 与实际 WebView bounds 的交集测量，回传 CSS，替代固定 64pt 估算。键盘/模态/完整播放器遮挡期间保留页面留白，避免滚动位置跳动；原生控件让位。未登录或退出共享 Player 时隐藏原生导航，空队列移除 accessory。
- **播放复用**：使用共享 Player 已计算的本地歌曲、电台、遥控投影。原生播放/暂停与下一首继续调用现有 actions；歌曲封面/标题进入现有 React 完整播放器并保留历史行为。电台沿用原来没有完整播放器入口的边界。单独发送既有 CachedImage 的 128px JPEG，过期曲目图片被忽略；这个副本只供迷你播放器，不进入沉浸封面生成管线。进度同步为无障碍播放时间描述。
- **平台边界**：Web、Android、桌面保持原 UI。当前仍只支持单 scene；横竖屏、分屏与 Stage Manager 按可用内容尺寸适配。真实 Web 滚动是否触发系统最小化需要在真实页面与设备确认，不能以强制 inline trait 的夹具测试替代。

## 验证记录

- `test-native-shell.mjs`：独立 Simulator App 内使用真正的 `UITabBarController.bottomAccessory` 和生产播放器 view，验证 regular/inline 信息密度、控制事件、键盘及模态隐藏。结果保存到 `exp/system-accessory-qa/`。
- `test-native-shell-bridge.mjs`：实际 Debug Capacitor App 验证最终 WK handler、系统 root、accessory 和三个 Tab；反复选择各 Tab，检查 WebView 身份和单父容器不变，并验证程序化选中/完成回调不发送导航，用户选择意图只发送一次。iPhone 已登录页面另检查 Web 底栏隐藏；无登录的 iPad 只做外壳验证，并明确标记页面隐藏测试未适用。
- Cypress 覆盖 React 桥接、Tab 路由、宽窗口保留搜索顶栏但隐藏重复 Web 导航、窄窗口样式、全屏/模态让位；不是对系统手势最小化的真机验收。
- 测试图片与结构化结果随文档保存；包含真实账户内容的 Simulator 截图只留在 `/tmp/aonsoku-accessory-iphone-current/`，不提交原始页面或日志。
- 最终构建/检查结果在本次提交前复核。未安装到真机；仍需验证实际滚动收起、VoiceOver、Stage Manager、前后台与播放连续性。

## 初始化问题记录

初版把 `aonsokuShell` 注册在 `webViewConfiguration(for:)` 中，但 Capacitor 8 随后替换了 `userContentController`，消息入口丢失。注册现固定在最终 `webView(with:configuration:)` 创建钩子；接收端验证主框架请求 URL，以兼容自定义 scheme 的 opaque security origin。

此前独立 UIKit 和模拟 JS 桥测试遗漏了这个生命周期，因此新增了实际 Capacitor 初始化和状态往返测试。Debug 测试必须显式设置 `AONSOKU_SHELL_BRIDGE_QA=1`，Release 不包含夹具执行路径。原先的自绘底栏和宽窗口 Web 侧栏恢复版本均已由本节的系统 accessory 实现替代。

## 播放器间距修正（2026-10-15）

根据真机截图，常规态封面从 46pt 缩为 36pt，为系统 accessory 上下留白；inline 态保留 30pt。内容行按自身高度相对 accessory 垂直居中，不再上下拉伸，并禁用内容行及其容器自动叠加 safe-area margins，避免收起态内容向上偏移。系统继续管理玻璃背景和 accessory 高度。本轮按用户要求不追加测试，待实际使用反馈。

## 全屏顶部阴影修正（2026-10-16）

全屏播放器是同一 WKWebView 内的 Web Drawer，并非独立原生控制器。该 WebView 的滚动视图已注册为系统 contentScrollView；原生 Tab/accessory 隐藏后，iOS 26 的滚动边缘效果仍可能覆盖 Web 全屏顶部，形成与播放器纯色背景不一致的阴影。现在在原生导航隐藏期间，使用公开 API 关闭该滚动视图的 top/bottomEdgeEffect；恢复导航时重新启用。覆盖全屏、弹层、键盘及未启用原生导航的状态，不改动 Web 播放器背景和安全区，也不影响旧版 iOS 或其他平台。本轮未追加测试，真机视觉效果待使用确认。

## Tab 返回路径修正（2026-10-16）

移除原生桥接中的 tabLocations 地址恢复。此前 Library → Playlists → Home → Library 会将 Playlists 作为新历史项打开，导致左上角 navigate(-1) 回到 Home。现在 Home/Library/Search 均跳转到与 Web 底栏相同的固定一级路由，已选中的 Tab 再次点击也可回到一级页面；KeepAlive 页面缓存仍由原有机制管理。同步修正既有桥接用例的 Library 目标地址，本轮按要求不运行测试。

### 本地安装包资源同步遗漏

用户反馈修复未生效后，检查本地 `dist` 和 `ios/App/App/public` 的 sourcemap，二者均仍含旧的 tabLocations 恢复逻辑。仅提交 TS 源码不会更新 Xcode 使用的被 git 忽略的 Web 资源。本次已重新执行 `pnpm run build:mobile` 和 `pnpm exec cap sync ios`，确认 iOS public 中的源码映射已使用固定 Tab 根路由、无旧恢复逻辑；未运行测试或安装真机。后续修改 Web/桥接代码并从本地 Xcode 安装前，必须先完成以上构建与同步。CI 原有 iOS 工作流已包含这两个步骤。

## 页面跳转反向触发 Tab 导航（2026-10-16）

从 Home 打开专辑等 Library 子页面时，React 的 activeIndex 同步会程序化选中 Library。此前 didSelectTab 无条件将选中完成回传为 Tab 点击；固定根路由修复后，该回传会把详情页拉回 Library 一级页面。现在用户导航只从 shouldSelectTab 发出，didSelectTab 仅重挂既有 bridge；设置 selectedTab 时另加同步标记，防止程序化选择回传用户意图。保留用户直接点击（包括重复点击）Tab 回一级页的 Web 语义。同步更新既有原生 QA 的事件边界，未运行测试。
