# 全屏播放器动态封面接口

## 范围与交付顺序

目标平台是 iOS/iPadOS 与 macOS。先提供统一消费接口，再替换全屏播放器中现有的方形专辑封面区域。播放控制、拖动关闭、歌词、队列及迷你播放器保持各自职责。

接口与 iOS 适配已完成；macOS 现已接入 Tauri + 原生 Core ML，使用同一消费契约。全屏播放器现已接入消费接口；当前分辨率和需求规则以 [`resolution.md`](resolution.md) 为准。Windows、Android 暂不实现；未来浏览器 WebGPU 提供者也沿用统一消费边界，不让组件依赖 Core ML。

## 消费契约（v1）

代码入口：`src/native/artwork/`。

- `getCapabilities()`：协议版本、可用状态、支持的格式及不可用原因。能力来自提供者握手，不能仅凭 Apple 系统或桌面运行时推断可用。
- `acquire({ coverArtId, format, mode })`：请求当前展示封面的已完成视频。格式为 `square` / `portrait` / `any`（接受已有比例），模式为 `static` / `dynamic`。返回 `ready`、`pending`、`disabled`、`mismatch`、`unavailable` 或 `busy`。
- `ready` 包含 `leaseId`、`assetId`、`coverArtId`、`format`、`stage`、`backend`、`width`、`height`、`duration`、`src`。`stage` 是 `static`、`camera` 或 `depth`；`backend` 保留具体 DAV2 档位，便于诊断。`src` 是可直接供播放器读取的本地视频地址，不携带服务器凭据。
- `requestGeneration({ coverArtId, mode })`：独立登记消费者需求，返回可释放的句柄；不是 UI 生成开关，也不传递全屏像素尺寸。读取接口自身不登记需求。
- `release(leaseId)`：幂等释放引用。使用返回的句柄 `release()` 可保证释放回到原提供者，即使运行时桥接对象已改变。

静态模式始终使用保留的纯静态视频；动态模式按 static → camera → depth 渐进取用。`motionAllowed` 表达原生播放许可，与生成阶段分开。读取只访问已完成的视频，绝不触发推理、下载或编码。调用者在可见期间有限频率重试 `pending`，比较 `assetId`，无需逐帧查询。暂不添加事件订阅或常驻轮询。

## 所有权与安全

原生播放管线仍是唯一生成者；前端不能提交任意封面 URL、磁盘路径或模型请求。请求必须匹配当前原生播放投影的封面，包括远程播放；切歌、清空和元数据修订会使旧请求失效。文件读取完成后再次校验修订与设置，避免异步回调返回旧封面。

一次成功 acquire 对应一个租约。租约持有生产管线的同一 asset，沿用已有缓存保护，缓存清理/LRU 不得删除使用中的视频。切歌不会撤销尚在播放或退出动画中的旧租约；消费者移除旧视频后主动 release。每个原生桥接会话最多 32 个租约，超出返回 busy，不强制删除活跃视频；桥接销毁时释放全部租约。生产者只保留当前修订的发布记录。

iOS 通过现有 Preferences 插件扩展方法访问原生发布注册表，适配器用 Capacitor 文件转换生成 WebView URL。锁屏发布仍按公开支持的 artwork key 执行；全屏消费与其展示开关、是否已有系统尺寸回调独立。预览/视频尺寸分别记录，具体目标和首次兜底见 `resolution.md`。

macOS Tauri 适配器通过 `dynamic_cover_command` 实现 `DynamicCoverProvider`；`window.aonsokuDynamicCover` 保留为其他宿主的可选接入口。宿主验证 Darwin、维护 WebView 会话租约并负责销毁清理，通过受限本地资源协议返回视频 URL。接口不允许将任意路径转成可读 URL。非 Tauri/macOS 运行时不调用该桥接。现有 Electron 运行时未增加生成服务。

## macOS 实现路线

采用 Tauri → Rust 调度层 → Swift 原生服务 → Core ML DAV2 的调用链。Rust 负责命令入口、任务调度与受控文件访问；Swift 负责模型加载、推理和视频生成。macOS 源码独立放在 `src-tauri/native/artwork`，初始版本复制自 iOS `36cb9f2b`，随后独立适配；构建与源码均不引用 iOS 目录。两端对齐 DAV2 分档、单模型串行推理、资源释放、运动参数和缓存身份规则。锁屏发布及平台生命周期、资源策略各自维护。

播放器通过统一接口获取已生成的视频，在 WKWebView 中播放。前端不直接加载 Core ML 模型。模型按需下载和资源限制由宿主管理。默认分档沿用物理 RAM 的 P6/P8/FP16 规则；macOS 使用 free+inactive VM 页估算余量：低于 512 MiB 暂停、低于 1 GiB 限 P6、低于 2 GiB 限 P8，后续按设备数据调整。内存压力暂停 60 秒，恢复期 180 秒限 P6；严重发热、低电量模式或减少动态效果会暂停动态生成。隐藏 App 暂停新工作，单纯切换窗口焦点仍可生成。

## macOS 当前实现

- 原生媒体元数据（本地/远程播放投影）是唯一源入口。Swift 剥离缩略图 `size` 参数并下载、验证完整原图；不将媒体会话中的 300px/base64 图片送入 DAV2。原图按 URL 摘要缓存，原始凭据不出现在文件名或诊断里。
- 新制作视频使用原图长边的方形画布；旧方形/竖版均可消费，按 static → camera → depth 发布；静态视频始终保留。DAV2 成功后退休 camera，仍在使用的租约继续保护文件。模型尚未准备好、压力暂停或推理失败时继续使用已有阶段，不写入伪 DAV2 缓存。
- FP16/P8/P6 使用同一固定 Apple revision、字节数与 SHA256；串流下载、网络限制、取消、删除、编译延期、单模型串行推理均在 macOS 原生实现。模型推理完成后释放，视频编码复用有限像素缓冲。幅度 0.5–2x，速度对应 3–12 秒完整循环、24fps。
- 音频设置提供开关、档位、模型管理和运动参数；离线缓存管理器接入静态/动态视频类型。macOS 设置增加折叠诊断面板，展示原图状态、发布阶段、Core ML/编码耗时与进程内存、归一化深度图。只有展开时才请求诊断。
- Rust 启动时传入 app-data 与打包 license 路径。渲染层命令白名单不包含源 URL、文件路径、会话初始化或内部文件解析。`aonsoku-artwork://localhost/<session>/<lease>` 仅映射活跃原生租约，支持 Range/HEAD；WebView 重载和销毁时自动清理会话。
- 构建要求 Xcode，macOS 最低 13；模型若不被当前 Core ML 运行时支持会报告错误并保留 camera/static。构建只链接 macOS 自己的 Swift 源码，license 随 Tauri 资源打包，权重不入包。参见 [`README`](../../src-tauri/native/artwork/README.md)。

## Web 实现路线与降级

Web 后续优先评估 ONNX Runtime Web + WebGPU，在 Worker 中运行 DAV2 深度推理，避免阻塞界面。Core ML FP16/P8/P6 包不能直接用于浏览器，需要另行准备和验证浏览器模型；不承诺与原生量化档位一一对应。共享消费接口、运动参数与轨迹的视觉目标，推理和渲染使用各平台适合的实现。

WebGPU 能力检测需要实际申请适配器/设备并验证推理所需特性，不能只检查 `navigator.gpu`。适配器申请失败、模型加载失败、内存不足和运行时设备丢失都需要降级；用户关闭动态封面或启用减少动态效果时也应遵循相应设置。

降级顺序为：DAV2 深度分层运动 → 轻量整体镜头运动 → 静态沉浸封面 → 普通原始封面。不支持 WebGPU 时仍可使用轻量镜头运动；不默认在 CPU/WASM 上运行 DAV2，后续有设备耗时、发热和内存数据后再评估是否提供可选路径。

浏览器可评估直接渲染以及生成并缓存循环视频两种方式。当前 v1 是视频租约接口，浏览器若生成视频，可使用受租约管理的 Blob URL；若采用直接渲染，需要扩展带版本的输出类型和对应适配器，不能把 Canvas 当作现有视频 `src` 返回。释放租约时同时释放关联浏览器资源。

能力、生成阶段和降级原因需要分别表达：能力表示当前设备可使用的后端，阶段表示已准备好的 static/camera/depth 内容，原因解释为何停留或降级。后续 Web 接入再补充具体能力字段，避免播放器根据系统名称猜测支持情况。

## 播放器接入（已实现）

继续使用现有方形尺寸与 CachedImage 首帧兜底。仅在全屏封面可见且 App 前台时获取/刷新视频；切歌丢弃迟到结果并立即释放其租约。新视频能播放后再换下旧视频并释放旧租约。关闭全屏、卸载组件时释放全部引用。歌曲暂停、隐藏页面、切到歌词/队列或 Reduce Motion 时暂停动画；资源恢复后复用视频，不重复生成。

幅度、速度、模型档位继续由统一设置和缓存 ID 管理；视频完整循环仍为 3–12 秒、24fps。设备验收仍需验证 iPad/iPhone 与 macOS WKWebView 的实际视频读取、循环、暂停及触摸拖动。

## 精简验证

本次集中一次运行：前端提供者选择/地址转换/租约释放的定向单测；Foundation 注册表的修订隔离、分阶段选择与租约保护检查；TypeScript 检查和 iOS 编译。无需生成模型视频、下载模型、安装真机或重复跑全套渲染实验。


## 首轮接口验证结果（历史，2026-10-15）

- 接口与既有 iOS 设置门禁定向单测：21 项通过，约 150ms。
- `node scripts/ios/test-dynamic-cover-interface.mjs`：发布阶段、修订隔离、租约生命周期/跨会话隔离/数量限制通过；不生成视频或加载模型。
- iOS Release 通用设备目标编译通过（不签名、不安装设备）。Biome 定向检查通过。
- TypeScript 未全量通过：标准 web 项目检查先遇到既有 Electron 项目引用输出缺失；去除引用、仅检查接口及其真实依赖后，仍有既有 coordination 类型导入/监听器签名和 `IAonsokuAPI.lanControl` 声明错误。新增接口文件无剩余类型诊断。本轮不修改这些无关模块。
- 尚未验证真机 WebView 视频读取；播放器 UI 与 macOS 生产提供者留待下一步接入。


## macOS 首轮接通验证（历史，2026-10-15）

- 平台归属：macOS 独立 Swift 源码全部在 `src-tauri/native/artwork`；本次最终无 iOS 文件改动，Web 实现未改动。
- Tauri/Rust/Swift 编译与链接通过，WebKit Range 边界检查通过；22 项前端定向单测通过。
- 使用生产 C ABI 跑通原图 → static → camera → DAV2 P6 depth，完成模型网络下载/校验/编译和视频引用/缓存保护检查。测试修复了失去焦点误暂停及复制后遗漏原生 Core ML 分支的问题。后续验证复用了已验证模型，没有重复下载。
- M3 Pro / 18 GiB / macOS 27.0.1：static 约 213ms、camera 约 533ms、首个 depth 约 36.639s；其中冷模型加载 3.775s、预测 75ms、首次含文字识别的分析 35.625s。幅度 1.5x、速度 2x 的实际输出为 720×720 / 24fps / 3s，保留完整轨迹。
- 产物及测量边界见 [`exp/macos-service/README.md`](exp/macos-service/README.md)，包含实际视频、深度图、日志和 JSON。Release 内存是起止最大值，未声称采样峰值。
- TypeScript 检查仍仅报告既有 coordination 类型与 `IAonsokuAPI.lanControl` 问题，新增文件无类型诊断。全量 Biome lint 在提交钩子执行。未额外跑 iOS/Android 或 Web 构建；Tauri WKWebView 全屏 UI 接入仍为下一阶段。


### 2026-10-15 分辨率规则接入

全屏新增独立“动态专辑封面”展示选项（默认关闭）；可见消费者通过 `requestGeneration` 登记实际需求，关闭后释放。现已使用现有方形布局显示 leased video，竖版影片仅在 CSS 遮罩中裁切，成品首帧可用后替换旧片；暂停、不可见、Reduce Motion 与原生资源策略受到约束。锁屏选项不再返回全屏 `disabled`。macOS 的旧锁屏兼容选项不作为生成入口，设置页只展示模型/参数配置，全屏展示由新选项控制。验算、兼容旧缓存与具体产物见 `resolution.md`。


### 动态封面边缘融合（2026-10-15）

启用动态专辑封面时，整个封面组合（包含视频准备期间的静态兜底图）使用横纵相交的透明渐变遮罩：外围约 8% 平滑过渡到透明，中心保持清晰，四角同时柔化。移除该模式外容器的实体底色与硬圆角，让真实播放器背景自然透出；不叠加固定颜色边框。Safari/WKWebView 使用对应 WebKit mask 组合。普通封面与迷你播放器沿用原样式。此项仅为显示层样式，不改视频文件、缓存、运镜、布局尺寸或拖动覆盖层；按用户偏好未运行测试。
