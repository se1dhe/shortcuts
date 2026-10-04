import Foundation

/// Протокол поставщика метаданных о версии и времени сборки приложения (DIP).
public protocol AppVersionProviding: Sendable {
    var marketingVersion: String { get }
    var buildNumber: String { get }
    var buildDate: Date? { get }
    var formattedBuildDate: String? { get }
    var fullFormattedBuildDate: String? { get }
    var displayVersion: String { get }
    var detailedVersionInfo: String { get }
}

/// Сервис предоставления информации о версии и сборке приложения.
/// Соответствует принципам SOLID:
/// - Single Responsibility (SRP): единая ответственность за извлечение и форматирование информации о сборке.
/// - Open/Closed (OCP): расширяем через свойства и форматы без изменения клиентов.
/// - Dependency Inversion (DIP): предоставлен протокол AppVersionProviding для внедрения зависимостей и тестирования.
public final class AppVersionService: AppVersionProviding, @unchecked Sendable {
    public static let shared = AppVersionService()

    private let bundle: Bundle
    private let fileManager: FileManager

    public init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        self.bundle = bundle
        self.fileManager = fileManager
    }

    /// Маркетинговая версия релиза (например, "1.0.0").
    public var marketingVersion: String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Номер внутренней сборки (например, "1").
    public var buildNumber: String {
        bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Дата и время компиляции бинарного файла приложения.
    public var buildDate: Date? {
        // 1. Проверяем наличие специального ключа в Info.plist (если задан скриптом)
        if let plistDateString = bundle.infoDictionary?["BuildDate"] as? String {
            let isoFormatter = ISO8601DateFormatter()
            if let date = isoFormatter.date(from: plistDateString) {
                return date
            }
        }

        // 2. Извлекаем дату модификации исполняемого файла приложения
        guard let executableURL = bundle.executableURL,
              let attributes = try? fileManager.attributesOfItem(atPath: executableURL.path),
              let date = attributes[.modificationDate] as? Date else {
            return nil
        }
        return date
    }

    /// Локализованная дата и время сборки для компактного отображения (например, "04.10 20:24").
    public var formattedBuildDate: String? {
        guard let date = buildDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter.string(from: date)
    }

    /// Полная дата и время сборки для тултипа (например, "4 октября 2026, 20:24:49").
    public var fullFormattedBuildDate: String? {
        guard let date = buildDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    /// Компактная строка для боковой панели: "v1.0.0 (04.10 20:24)" или fallback "v1.0.0 (build 1)".
    public var displayVersion: String {
        if let formattedDate = formattedBuildDate {
            return "v\(marketingVersion) (\(formattedDate))"
        } else {
            return "v\(marketingVersion) (build \(buildNumber))"
        }
    }

    /// Подробная строка для подсказки (hover tooltip / help) и буфера обмена.
    public var detailedVersionInfo: String {
        var lines = ["Версия \(marketingVersion) (сборка \(buildNumber))"]
        if let fullDate = fullFormattedBuildDate {
            lines.append("Собрано: \(fullDate)")
        }
        return lines.joined(separator: "\n")
    }
}
