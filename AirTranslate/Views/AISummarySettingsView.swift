import SwiftUI

struct AISummarySettingsView: View {
    @ObservedObject var model: LiveTranslateViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                Section("DeepSeek") {
                    SecureField("API Key", text: $model.deepSeekAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("模型", text: $model.deepSeekModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        model.testAIConnection(.deepSeek)
                    } label: {
                        Label("测试 DeepSeek 连接", systemImage: "network")
                    }
                    .disabled(model.isTestingAIConnection)
                }

                Section("智谱 GLM") {
                    SecureField("API Key", text: $model.zhipuAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("模型", text: $model.zhipuModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        model.testAIConnection(.zhipu)
                    } label: {
                        Label("测试智谱连接", systemImage: "network")
                    }
                    .disabled(model.isTestingAIConnection)
                }

                Section {
                    DisclosureGroup("高级：API 地址", isExpanded: $showAdvanced) {
                        TextField("DeepSeek Endpoint", text: $model.deepSeekEndpoint, axis: .vertical)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("智谱 Endpoint", text: $model.zhipuEndpoint, axis: .vertical)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } footer: {
                    Text("API Key 只保存在本机钥匙串，不会写进导出记录。AI 总结只上传最终转写/译文文本，不上传原始麦克风音频。")
                }

                if !model.aiSettingsStatus.isEmpty {
                    Section("状态") {
                        if model.isTestingAIConnection { ProgressView() }
                        Text(model.aiSettingsStatus)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("AI 总结设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        model.saveAISettings()
                        dismiss()
                    }
                }
            }
        }
    }
}
