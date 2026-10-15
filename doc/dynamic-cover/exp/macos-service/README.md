# macOS 原生服务验证（2026-10-15）

环境：Apple M3 Pro、18 GiB RAM、macOS 27.0.1。输入为本目录上级的用户示例封面 `../../cover.png`。实际调用 Tauri 构建出的 macOS Swift 静态库 C ABI，不使用 iOS 源码、Python 推理或实验模型注入。

P6 首次经过生产下载器的固定 revision、字节数与 SHA256 校验和本地 Core ML 编译。初次验证确认失去焦点造成的暂停，保留于 `focus-paused.json`；修正 macOS 生命周期后复用这份已验证的编译模型，完成以下链路。没有重复下载权重。

| 阶段 | 首次可取用 | 视频 | 实际编码 |
| --- | --- | --- | --- |
| static | 213 ms | [static.mp4](static.mp4) | 720×720，纯静态单帧 |
| camera | 533 ms | [camera.mp4](camera.mp4) | 720×720，24fps，6s |
| DAV2 P6 depth | 36.639s | [depth.mp4](depth.mp4) | 720×720，24fps，3s |

本次设置：幅度 1.5x、速度 2x；因此 DAV2 完整轨迹为 3 秒。默认速度仍为 6 秒。camera 与 static 不跟随 DAV2 参数变化。静态接口的 `duration=2` 表示沿用 iOS 的名义保持时长；单帧 MP4 的实际媒体时长约 0.067s，前端应保持静态帧。

- [depth.png](depth.png)：实际 DAV2 归一化深度，可见人物/手部与背景的区分。
- [result.json](result.json)：阶段时间、设置、模型状态、诊断及 ffprobe 元数据。
- [service.log](service.log)：原生阶段耗时与进程内存记录。
- [status.json](status.json)：完成时的诊断快照。
- [focus-paused.json](focus-paused.json)：首次网络下载/编译成功但尚未修正焦点策略时的诊断。

冷模型加载约 3.775s、预测 75ms、深度映射 3ms；含首次 Vision 文字识别的分析约 35.625s，DAV2 编码约 158ms。内存记录是 Release 的阶段起止最大值，本次编码结束附近记录约 240 MiB，**不等同于 10ms 采样峰值或模型独占内存**。

检查通过：完整原图仅请求一次且不含 `size` 参数，三个发布阶段、实际 Core ML 深度、静态引用保留、缓存清理保护、封面匹配检查、会话释放。停止时方形 depth 已完成；竖版同管线支持，本次未单独计时。真实 Tauri WKWebView 全屏播放器 UI 尚未接入，不把本次原生服务验证当作 UI 实机验收。
