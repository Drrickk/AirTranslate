# AirTranslate v0.4.1

本版针对“点击开始立即闪退”进行运行时加固：

- 在启动 SpeechAnalyzer 前显式使用 `AssetInventory.reserve(locale:)` 预留语言模型名额，避免模型已下载但 locale 未分配导致 SpeechAnalyzer 启动异常。
- 模型检测改为结合 `SpeechTranscriber.installedLocales`，流程更贴近 Apple WWDC25 官方示例。
- 麦克风 tap 使用 `format: nil`，避免蓝牙/内置麦克风切换期间把过期的音频格式强制传给 AVAudioEngine。
- 音频会话激活后短暂等待路由稳定，再创建 AVAudioEngine。
- 增加 8 段启动诊断标记；若仍发生系统级闪退，重新打开 App 后状态区会显示“上次启动停在：X/8 …”，便于直接锁定闪退步骤。
- 仍使用 SpeechTranscriber + SpeechAnalyzer + AssetInventory 的设备端识别路线；没有改回在线 SFSpeechRecognizer。
