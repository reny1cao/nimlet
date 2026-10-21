import Foundation

/// Which language dictation listens for.
///
/// It was always the phone's own language, with nowhere to change it. Somebody
/// whose iPhone is set to English and who talks to their Mac in Mandarin got
/// English guesses at Mandarin, and when the on-device transcriber did not know
/// the phone's language it fell back to American English whatever was said.
///
/// Stored as a BCP 47 identifier; empty means the phone's language, which is
/// what nobody having chosen anything has always meant.
enum DictationLanguage {
    static let key = "mice.dictation.language"

    struct Option: Identifiable, Hashable {
        /// Empty for the phone's own language.
        let id: String
        /// In its own language, the way a language menu names it.
        let name: String
        /// For the chip in the dictation console, which has room for a word.
        let short: String
    }

    /// The languages most people dictating to a Mac are likely to want, each
    /// written the way its speakers would look for it.
    static let common: [Option] = [
        Option(id: "zh-CN", name: "中文（普通话）", short: "普通话"),
        Option(id: "zh-TW", name: "中文（台灣）", short: "國語"),
        Option(id: "zh-HK", name: "粵語（香港）", short: "粵語"),
        Option(id: "en-US", name: "English (US)", short: "EN"),
        Option(id: "en-GB", name: "English (UK)", short: "EN-GB"),
        Option(id: "ja-JP", name: "日本語", short: "日本語"),
        Option(id: "ko-KR", name: "한국어", short: "한국어"),
        Option(id: "fr-FR", name: "Français", short: "FR"),
        Option(id: "de-DE", name: "Deutsch", short: "DE"),
        Option(id: "es-ES", name: "Español", short: "ES"),
    ]

    static var options: [Option] { [automatic] + common }

    /// The phone's language, named, so "automatic" says what it will do.
    static var automatic: Option {
        let current = Locale.current
        let name = current.localizedString(forIdentifier: current.identifier) ?? current.identifier
        return Option(id: "", name: "Same as iPhone — \(name)", short: matching(current)?.short ?? languageCode(of: current))
    }

    /// What is chosen right now.
    static var chosen: String { UserDefaults.standard.string(forKey: key) ?? "" }

    static func locale(for id: String) -> Locale { id.isEmpty ? .current : Locale(identifier: id) }

    static func option(for id: String) -> Option {
        id.isEmpty ? automatic : common.first { $0.id == id } ?? Option(id: id, name: id, short: id)
    }

    /// The listed language a locale amounts to: the same language, and the same
    /// region where the list tells regions apart.
    private static func matching(_ locale: Locale) -> Option? {
        let language = locale.language.languageCode?.identifier
        let region = locale.region?.identifier
        let sameLanguage = common.filter { Locale(identifier: $0.id).language.languageCode?.identifier == language }
        return sameLanguage.first { Locale(identifier: $0.id).region?.identifier == region } ?? sameLanguage.first
    }

    private static func languageCode(of locale: Locale) -> String {
        (locale.language.languageCode?.identifier ?? locale.identifier).uppercased()
    }
}
