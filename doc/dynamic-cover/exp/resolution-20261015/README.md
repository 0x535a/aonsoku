# 分辨率与消费需求验证（2026-10-15）

本次使用生产 macOS Swift 库的 C ABI，源图为用户提供的 `../../cover.png`（500×500）。原生 `immersiveEnabled` / `dynamicEnabled` 均关闭，先验证读取只返回 pending，再登记独立动态消费需求。P6 复用此前已经校验和编译的包，没有重复下载。

| 阶段 | 首次可用 | 实际视频 | 文件 |
| --- | --- | --- | --- |
| static | 430ms | 500×500 单帧 | [static.mp4](static.mp4) |
| camera | 606ms | 500×500、24fps、6s | [camera.mp4](camera.mp4) |
| depth | 5.838s | 500×500、24fps、3s | [depth.mp4](depth.mp4) |

源图没有放大为旧版 720×720。参数为幅度 1.5x、速度 2x；默认速度仍为 6 秒。静态是单帧文件，接口中的 2 秒为名义保持时长，媒体容器实际时长约 0.067s。

- [depth.png](depth.png)：实际 DAV2 归一化深度。
- [result.json](result.json)：阶段、源图/输出/解码尺寸、开关、参数、模型状态、ffprobe 元数据。
- [service.log](service.log)、[status.json](status.json)：原生时间、内存与诊断；Release 内存为阶段端点最大值，不是采样峰值或模型独占内存。
- [legacy-reuse.json](legacy-reuse/legacy-reuse.json)：在新的进程/会话中放入历史 720×960、6 秒的 DAV2 视频，按当前原图摘要与参数索引读取。`any` 租约直接返回该竖版文件，逐字节一致，且没有 Core ML 推理；不是把它重编码为新方形视频。相关 [日志](legacy-reuse/service.log)。缺少静态保留片时，生产者可另外补建静态片。
- [geometry-tests.txt](geometry-tests.txt)：两份独立原生实现对照分辨率示例、对齐、解码及需求隔离。
- [interface-tests.txt](interface-tests.txt)：24 项定向接口测试。

全屏中的 1:1 遮罩属于 CSS 展示层，未写入这些视频。iOS Release 编译和 macOS 构建/Range/租约检查均通过；本轮没有安装真机，真实系统尺寸回调及 WKWebView 播放交互留待设备验收。详细规则见 [resolution.md](../../resolution.md)。
