# AirTranslate v0.7.0 — DeepSeek / 智谱 AI 总结 + 正式 App 图标

本版在 v0.6 的低延迟同传、稳定分句、双阶段翻译、本地语音选择和 TTS 追赶基础上，增加联网 AI 总结能力。

## AI 总结

- 默认支持 **DeepSeek** 与 **智谱 GLM**，另保留「快速本地」兜底。
- DeepSeek 默认模型：`deepseek-flash`；默认接口：`https://api.deepseek.com/chat/completions`。
- 智谱默认模型：`glm-5.3-flash`；默认接口：`https://open.bigmodel.cn/api/paas/v4/chat/completions`。
- 模型名与 Endpoint 都可以在 App 内修改，后续模型升级不必重新编译。
- API Key 使用 iOS Keychain 保存，不写入 UserDefaults、历史记录或导出文字。
- 联网总结仅发送最终转写与译文文本，不上传原始麦克风音频。
- 支持「日常 / 会议」两套模板。会议模板会整理会议摘要、明确结论、待办、问题风险与关键时间/数字；信息不足时明确说明，不脑补。
- 支持可选「实时刷新总结」：首次较快生成，之后可按 30 秒 / 1 分钟 / 2 分钟 / 3 分钟自动刷新；只有最终转写或译文发生变化时才调用 API。
- 设置页内可直接测试 DeepSeek / 智谱连接。

## 构建优化

- v0.7 移除了 MLX/Qwen3 本地总结依赖，减少 Swift Package 依赖与构建负担。
- 保留快速本地关键句摘要作为断网兜底。

## 隐私边界

- SpeechAnalyzer / SpeechTranscriber：设备端语音识别。
- TranslationSession：设备端系统翻译。
- AVSpeechSynthesizer：本机朗读。
- DeepSeek / 智谱：仅在用户主动生成总结，或用户开启“实时刷新总结”时联网上传最终文字。

GitHub Actions 成功产物：`AirTranslate-v0.7.0-unsigned.ipa`。
