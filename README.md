# AirTranslate v0.4.0

本版重新启用 iOS 26 官方端侧 SpeechAnalyzer / SpeechTranscriber 路线。

- 实时语音识别：SpeechTranscriber `.progressiveTranscription`
- 首次模型下载：AssetInventory 自动下载安装系统端侧语音模型
- 后续识别：设备端离线
- 麦克风：AVAudioEngine -> 音频格式转换 -> AnalyzerInput -> SpeechAnalyzer
- 翻译：Apple Translation framework，本地语言包模式
- AirPods：支持当前音频输出、可选蓝牙麦克风
- 总结：FoundationModels / MLX Qwen3 / 本地兜底

首次使用某种语音语言时需要联网下载 Apple 管理的端侧模型；下载完成后可以离线识别。

GitHub Actions 构建成功后下载 `AirTranslate-v0.4.0-unsigned` artifact。
