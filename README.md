# AirTranslate v0.5.0 — 低延迟同传

本版重点解决两个实际体验问题：字幕翻译启动太晚，以及中文 TTS 比讲话人慢导致累计延迟。

- TranslationSession 在页面生命周期内常驻，只在语言配置改变时重新准备，不再每句话 invalidate + prepare。
- SpeechTranscriber 的 partial 字幕约每 300ms 合并一次送入本地 Translation，实时显示预览译文。
- partial 译文只显示、不朗读；最终结果才进入历史并播报，避免重复念半句话。
- 中文 TTS 默认基础 rate 调到 0.58，可在 0.50–0.65 手动调整。
- 开启“语音自动追赶”后，语音队列有积压时动态提速，中文最高约 0.69。
- 当语音已经落后 4 段以上时，只清理过时的语音队列并追到最新译文；屏幕字幕和完整会话记录不会丢。
- 保留 v0.4.2 的 SpeechAnalyzer / SpeechTranscriber / AssetInventory 设备端识别与 AVAudioEngine @Sendable 闪退修复。

GitHub Actions 成功产物：`AirTranslate-v0.5.0-unsigned.ipa`。
