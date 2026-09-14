# AirTranslate v0.2.3

这是针对 GitHub Actions / Xcode 26.6 编译失败的稳定性修正版。

## v0.2.3 关键修复

- 实时语音识别从 iOS 26 新版 `SpeechAnalyzer` 改为成熟的 `SFSpeechRecognizer`。
- 强制 `requiresOnDeviceRecognition = true`，不会为了语音识别把音频发送到 Apple 服务器。
- 启动前检查 `supportsOnDeviceRecognition`，不支持时直接给出中文提示。
- 保留 iPhone 麦克风 / AirPods 麦克风选择与 AirPods 译文播报。
- 修正 Swift 6 下 `AVSpeechSynthesizerDelegate` 主线程隔离问题。
- GitHub Actions 自动删除旧的 `SpeechCaptureService-v*.swift` 补丁文件，避免旧文件再次被 XcodeGen 编进项目。
- Actions 失败时会直接在步骤中打印精简的 `error:` 行，并上传完整 build.log。

> 注意：`SFSpeechRecognizer` 是 Apple 较成熟的旧版语音识别接口，适合先把可安装版本稳定编译出来。它不像 `SpeechAnalyzer` 那样适合超长会议连续转写；后续等新版 API 在实际 Xcode SDK 中稳定后可以再切回。

## 构建

1. 把本压缩包内容完整覆盖到 GitHub 仓库根目录。最好先删除仓库里旧的 `AirTranslate/Services/SpeechCaptureService-v*.swift`。
2. 打开 GitHub → Actions → **Build unsigned IPA** → **Run workflow**。
3. 成功后下载 Artifact：`AirTranslate-v0.2.3-unsigned`。
4. Artifact 内包含 `AirTranslate-v0.2.3-unsigned.ipa` 和 `build.log`。

## 离线说明

- 语音识别：设置为设备端识别；仅在该语言支持设备端识别时启动。Apple 文档说明 `requiresOnDeviceRecognition = true` 会要求音频保持在设备端。
- 翻译：继续使用 Apple Translation framework 的本地语言包。
- AI 总结：保留 v0.2.1 的本地 MLX / Qwen 路径以及系统可用时的总结逻辑。

---

# AirTranslate v0.2.1 — 离线同传

这是一个面向 iOS 26+ 的原生 SwiftUI 项目，主要目标是绕开“中国大陆无法使用 AirPods 原生实时翻译”的限制，改用第三方 App 可调用的公开系统能力。

## v0.2.1 新增

- **双人对话模式**
  - 对方说外语：iPhone 收音 → 本地识别 → 本地翻译 → AirPods/当前输出朗读中文。
  - 我说中文：本地识别 → 翻译为外语 → 可让 iPhone 扬声器外放给对方。
  - 外放时会停止当前收音，降低“机器朗读被再次识别”的回声问题。
- **真正的离线生成式 AI 总结**
  - 自动模式优先使用 Apple Foundation Models（若设备与地区可用）。
  - Apple 本地 AI 不可用时，使用 **MLX + Qwen3-0.6B-4bit**。
  - Qwen3 模型第一次使用需要联网下载，下载完成后推理完全在 iPhone 本机进行。
  - 如果模型下载/加载失败，会退化到“不需要模型”的快速关键句摘要。
- **双向 Translation 会话**：外语→中文和中文→外语分别维护 TranslationSession。
- **离线语音包预下载**：可一次准备当前两种语言的 SpeechTranscriber 资源。
- **音频路由提示**：显示当前输入/输出设备。
- **历史记录**：本机最多保存 100 次会话，可查看、删除。
- **分享/导出**：直接使用 iOS Share Sheet 导出完整双语文字与总结。
- 新增法语、德语、西班牙语预设。

## 推荐的实际使用方式

### 1. 日常同传

- 模式：同传模式
- 对方语言：英语/日语等
- 我的语言：简体中文
- “优先使用 AirPods 麦克风”：关闭
- “自动朗读译文”：开启

把 iPhone 放在桌面或对方面前收音，AirPods 只负责把中文译文送进耳朵，通常比用耳机麦克风收对方声音更稳定。

### 2. 双人面对面对话

1. 选择“双人对话”。
2. 点“对方说”，开始回合；对方讲话后，你在 AirPods 里听中文。
3. 点“我来说”，开始回合；你说中文后，App 翻译成外语并从 iPhone 扬声器播放。
4. 播放完后再点“对方说”继续。

这是 v0.2.1 的可靠方案，没有做自动判断谁在说话，因为在嘈杂现场自动语言/说话人切换容易误判。

## 离线 AI 总结

总结页有三个模式：

- **自动**：Apple 本地 AI 可用就用 Apple；否则使用 Qwen3 离线 AI。
- **离线 AI**：强制使用 Qwen3-0.6B-4bit。
- **快速本地**：不下载大模型，只做关键句抽取。

Qwen3 模型来源为 `mlx-community/Qwen3-0.6B-4bit`。首次下载依赖 Hugging Face 网络；下载后模型会缓存到设备，本机推理时不需要联网。大陆网络如果访问 Hugging Face 不稳定，仍可用“快速本地”兜底。

## 系统要求

- iOS 26.0+
- iPhone 真机（MLX 本地模型不建议模拟器测试）
- Xcode 26+ / Swift 6
- 首次使用某种 Speech / Translation 语言需要联网下载 Apple 语言资源

## Windows 用户：GitHub Actions 打包

项目内已包含 `.github/workflows/build-unsigned-ipa.yml`。

1. 把本项目所有文件上传到你自己的 GitHub 仓库根目录。
2. 打开仓库的 **Actions**。
3. 选择 **Build unsigned IPA**。
4. 点击 **Run workflow**。
5. 构建成功后，在 Artifacts 下载 `AirTranslate-v0.2.1-unsigned`。
6. 解压后得到 `AirTranslate-v0.2.1-unsigned.ipa`。
7. 在 Windows 使用你信任的签名/侧载工具，用自己的 Apple ID / 开发证书重新签名后安装到 iPhone。

工作流不再写死某一个 Xcode 26.x 版本，会自动选择 GitHub macOS runner 中最新安装的 Xcode 26。

## 本地 Mac 编译

```bash
brew install xcodegen
xcodegen generate
open AirTranslate.xcodeproj
```

在 Xcode 中选择自己的 Team 后真机运行。

## 隐私

- App 本身不内置统计 SDK，也不上传你的会话内容。
- SpeechTranscriber 与 Translation 使用 Apple 设备端能力。
- Qwen3 总结只有首次下载模型时需要连接 Hugging Face；生成总结在设备本地完成。
- 历史记录保存在 App 自己的 Documents 容器中。

## 重要说明

这是个人测试项目，不是 App Store 成品。由于当前环境没有 macOS/Xcode，项目已做 Swift 语法解析检查，但真正的 Apple 框架链接和 Swift Package 构建仍需要通过 GitHub Actions/Xcode 完成。如果 Actions 出现编译错误，请把 `build.log` 发回，我可以按日志继续修正。


## v0.2.1 修复

- 修正 iOS 26 `SpeechTranscriber.supportedLocale(equivalentTo:)` 必须异步调用导致的编译错误。
- AirPods 高质量蓝牙录音模式改用兼容的 `.default` AudioSession mode。
- GitHub Actions 改为 `actions/checkout@v5`。
- 编译失败时也会上传 `build.log`，方便直接定位下一处 Xcode 错误。
