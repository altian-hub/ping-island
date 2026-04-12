import Foundation
import SwiftUI

@MainActor
enum AppLocalization {
    static func string(_ key: String) -> String {
        string(key, locale: AppSettings.shared.locale)
    }

    static func string(_ key: String, locale: Locale) -> String {
        let bundle = bundle(for: locale)
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private static func bundle(for locale: Locale) -> Bundle {
        let code = locale.language.languageCode?.identifier ?? "en"
        let lprojName = code.hasPrefix("zh") ? "zh-Hans" : code
        if let path = Bundle.main.path(forResource: lprojName, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments, locale: AppSettings.shared.locale)
    }

    static func format(_ key: String, _ arguments: CVarArg..., locale: Locale) -> String {
        format(key, arguments: arguments, locale: locale)
    }

    private static func format(_ key: String, arguments: [CVarArg], locale: Locale) -> String {
        let formatString = string(key, locale: locale)
        return String(format: formatString, locale: locale, arguments: arguments)
    }
}

struct AppLocalizedRootView<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.locale, settings.locale)
    }
}

extension Text {
    @MainActor
    init(appLocalized key: String) {
        self.init(verbatim: AppLocalization.string(key))
    }
}
