import Foundation

struct AppLanguage: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let speechLocaleIdentifier: String
    let translationIdentifier: String

    static let english = AppLanguage(id: "en", name: "英语", speechLocaleIdentifier: "en-US", translationIdentifier: "en")
    static let simplifiedChinese = AppLanguage(id: "zh-Hans", name: "简体中文", speechLocaleIdentifier: "zh-CN", translationIdentifier: "zh-Hans")
    static let japanese = AppLanguage(id: "ja", name: "日语", speechLocaleIdentifier: "ja-JP", translationIdentifier: "ja")
    static let korean = AppLanguage(id: "ko", name: "韩语", speechLocaleIdentifier: "ko-KR", translationIdentifier: "ko")
    static let french = AppLanguage(id: "fr", name: "法语", speechLocaleIdentifier: "fr-FR", translationIdentifier: "fr")
    static let german = AppLanguage(id: "de", name: "德语", speechLocaleIdentifier: "de-DE", translationIdentifier: "de")
    static let spanish = AppLanguage(id: "es", name: "西班牙语", speechLocaleIdentifier: "es-ES", translationIdentifier: "es")

    static let all: [AppLanguage] = [
        .english, .simplifiedChinese, .japanese, .korean, .french, .german, .spanish
    ]
}
