# AirTranslate v0.6.0 — 稳定分句 / 双阶段翻译 / 本地语音选择

本版重点从“单纯追求速度”转为同时控制翻译质量、朗读延迟和本地语音体验。

## 翻译质量

- 新增「低延迟 / 高质量」两档。
- 低延迟模式不再把每个原始 partial 都直接送去翻译，而是优先选择连续识别中已经稳定的文本前缀或带完整标点的片段做预览翻译。
- partial 译文只作为屏幕预览；SpeechTranscriber 最终结果仍会整句重新翻译并覆盖成最终译文。
- 高质量模式关闭 partial 翻译，只使用最终语义单元。

## 低延迟朗读

- 低延迟模式下可单独开启「低延迟朗读」。
- 当讲话出现短暂停顿（约 520 ms）或形成较明确的句尾时，稳定片段可以提前翻译并朗读，不必一直等整段 final。
- 已提前朗读的原文前缀会记录下来；最终句到来后只补朗读尚未播放的尾部，避免整句重复。
- 如果 SpeechTranscriber 后续把已经朗读过的前缀改写，App 会优先避免重复播报，屏幕最终译文仍以完整 final 为准。
- 保留 v0.5 的 TTS 自动追赶：队列积压时动态提速，严重积压时只丢弃过时音频，不删除字幕和历史记录。

## 本机语音选择

- 新增「目标语言声音」。
- 使用 `AVSpeechSynthesisVoice.speechVoices()` 读取 iPhone 当前可用的目标语言语音。
- 可选择「系统默认」或具体本机声音；不接 Azure、Edge 或第三方云 TTS。
- 语言切换后会自动刷新该语言可用语音列表。

## 保留能力

- iOS 26 `SpeechAnalyzer + SpeechTranscriber + AssetInventory` 设备端识别。
- `TranslationSession` 常驻预热，本地系统翻译。
- Apple 本地 AI / Qwen3 离线总结。
- 双人对话、AirPods 路由、本地历史与导出。
- Swift 6 `AVAudioEngine.installTap` 的 `@Sendable` 闪退修复。

GitHub Actions 成功产物：`AirTranslate-v0.6.0-unsigned.ipa`。
