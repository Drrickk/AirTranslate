# AirTranslate v0.3.0

本版重点解决部分 iPhone 对 en-US 返回 `supportsOnDeviceRecognition = false`，导致无法开始同传的问题。

## v0.3.0

- 语音识别改为“设备端离线优先 + Apple 在线自动兜底”。
- 有离线识别资源时自动设置 `requiresOnDeviceRecognition = true`。
- 没有离线识别资源时，如果开启“无离线模型时允许联网语音识别”，自动切到 Apple Speech 在线识别。
- 界面明确显示当前是“设备端离线识别”还是“Apple 在线识别”。
- 可以关闭联网兜底；关闭后仍保持纯离线策略。
- Translation 翻译继续使用系统本地语言包。
- 保留 AirPods 输出/麦克风选项、双人对话、本地历史、MLX + Qwen3 本地总结。
- 保留 v0.2.4 的 Swift 6 Translation 兼容修复。

## 构建

把压缩包内容覆盖到 GitHub 仓库根目录，运行 Actions → Build unsigned IPA。成功后下载 `AirTranslate-v0.3.0-unsigned`。

## 隐私说明

当“无离线模型时允许联网语音识别”开启，并且当前语言没有设备端识别资源时，Speech framework 可能通过 Apple 在线语音识别服务处理音频。关闭该开关可强制只允许本机离线识别。翻译和本地 AI 总结仍按项目原有本地方案运行。
