# DAV2 动态封面实验

打开 [index.html](index.html) 比较 FP16/P8/P6 与整体镜头回退。所有视频无音轨、6 秒、24 FPS；素材使用用户提供的 `../cover.png`。模型本身保存在仓库外，来源/校验和见 [model-manifest.json](model-manifest.json)。

当前三档产物在 `dav2-product-mac/`，模型来源、固定版本、大小和校验和见 `model-manifest.json`。模型权重不放入本目录或 App 安装包。

当前比较基准是 `dav2-product-mac`：标量深度、自定义 Metal、线性中性值和文字保护。旧 YOLO/P4/错误滤镜实验只保留在本地历史目录供排查，没有进入产品。

每个档位保存源图、归一化深度图、720/960 画布及位移场、关键帧、两个比例的循环 MP4、结果 JSON 和阶段性能日志。原始模型输出 `raw-dav2-*.f32` 使用 `numpy.fromfile(path, dtype="<f4").reshape(height, width)` 读取，尚未归一化；DAV2 是模型相对逆深度图。PNG 白表示更近；正式位移为 `(2d-1)` 乘周期偏移。

`text-regions.json` 使用左下原点、归一化坐标；用于文字保护，不包含识别出的字符串。`optical-flow.json` 是关键帧之间的估计运动，纹理不足区域可能不可靠；单元测试使用已知图形验证 20px 相对位移与中性值，避免仅凭光流判定。

Mac 的 RAM/延迟不能替代 iPad/iPhone 指标；生产只做一次预测，实验才记录预热重复。正式 DAV2 版本目前只完成 Mac 验证，真机验证留待下一步。

复现：

```bash
node scripts/ios/run-motion-cover-experiment.mjs /tmp/aonsoku-depth-models doc/ios-lock-screen/cover.png doc/ios-lock-screen/exp/dav2-product-mac
node scripts/ios/test-lock-screen-artwork.mjs
```
