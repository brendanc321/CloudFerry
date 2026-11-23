import Foundation

enum Language: String { case en, zh }

/// 轻量本地化：默认英文；在「设置」最底部的 Language 里可以切换到简体中文。
enum Loc {
    private static let key = "cf.language"
    static var current: Language = {
        if let s = UserDefaults.standard.string(forKey: key), let l = Language(rawValue: s) { return l }
        return .en   // 默认全英文
    }()

    static func set(_ l: Language) {
        guard l != current else { return }
        current = l
        UserDefaults.standard.set(l.rawValue, forKey: key)
        NotificationCenter.default.post(name: .cfLanguageChanged, object: nil)
    }
    static func toggle() { set(current == .zh ? .en : .zh) }

    static var appleLocale: Locale { current == .zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US") }
}

extension Notification.Name {
    static let cfLanguageChanged = Notification.Name("cfLanguageChanged")
}

/// L("中文", "English") —— 按当前语言返回。
func L(_ zh: String, _ en: String) -> String { Loc.current == .zh ? zh : en }
