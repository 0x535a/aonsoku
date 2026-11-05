# 上游 PR 提交说明

目标仓库：`realtvop/aonsoku-reborn`，目标分支：`main`。

提取来源：`deploy` 的 `44f856b7`；四个功能分支均直接基于上游 `5b07e181`，各只有一个独立功能提交。四个分支之间当前无硬性代码依赖，已检查涉及共享文件的分支合并无冲突。可以按下表顺序提交，也可以由维护者独立评审合并。上游 main 更新后仍应重新检查差异和构建。

| 功能分支 | 提交 | 中文标题和正文 |
| --- | --- | --- |
| `feat/ios-lockscreen-artwork` | `ec08a2b2` | [01-ios-lockscreen-artwork.md](01-ios-lockscreen-artwork.md) |
| `feat/web-fullscreen-dynamic-artwork` | `07657a3b` | [02-web-fullscreen-dynamic-artwork.md](02-web-fullscreen-dynamic-artwork.md) |
| `feat/ios-native-amll-lyrics` | `ee8d83a2` | [03-ios-native-amll-lyrics.md](03-ios-native-amll-lyrics.md) |
| `feat/ios-carplay` | `a5eaa43f` | [04-ios-carplay.md](04-ios-carplay.md) |

每份文档的“标题”用于 PR 标题，“正文”及其后内容用于 PR 描述。各功能分支只携带自身的 PR 文案；当前 deploy 的 `doc/pr` 汇总了四份，方便复制。

## 最终范围

1. iOS 锁屏沉浸式静态／动态封面、DAV2 模型管理、生成缓存和设置。
2. Web 全屏动态封面的镜像、羽化、光晕与可选提供方接口；没有提供方时继续使用静态封面。此分支未接入视频生成后端。
3. 原生 iOS AMLL 风格歌词及不限行排版，保留 deploy 已确认的动效差异。
4. 原生 CarPlay 浏览、共享播放、队列和场景／签名配置。

所有分支保留上游 Aonsoku 品牌，没有引入 Tauri、macOS 视频生成后端、Electron 视频生成适配、Web 内嵌原生播放器、品牌替换或 deploy 的队列替换行为修改。

## 本次检查

- 锁屏：iOS 模拟器 arm64／x86_64 应用构建、原图 XCTest、封面生成／缓存／租约／资源策略、分辨率与翻译键检查通过。未执行真实模型下载测试。
- Web：生产构建、1,303 项单元测试、9 项 headless Cypress 组件测试和变更文件 Biome lint 通过。
- 歌词：arm64 模拟器应用构建、动效数学检查及 588 项模拟器排版检查通过。
- CarPlay：arm64 模拟器应用构建、507 项原生测试及翻译键检查通过。
- 验证通过命令行完成，未使用 Computer Use。真机锁屏、真实视频提供方、歌词手感和车机连接仍由维护者验收。

本次仅创建本地分支和文档，没有推送远程，也没有创建或发布 GitHub PR。你可以将上述分支推送到自己的 GitHub fork，再手动向上游 main 提交。

## 本地工作目录

- `feat/ios-lockscreen-artwork`：`/Users/stephenzeng/Repo/aonsoku-pr-artwork`
- `feat/web-fullscreen-dynamic-artwork`：`/Users/stephenzeng/Repo/aonsoku-pr-web-fullscreen`
- `feat/ios-native-amll-lyrics`：`/Users/stephenzeng/Repo/aonsoku-pr-lyrics`
- `feat/ios-carplay`：`/Users/stephenzeng/Repo/aonsoku-pr-carplay`
