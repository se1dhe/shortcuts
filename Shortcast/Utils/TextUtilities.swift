import Foundation

/// Утилиты для работы с текстом и символами.
/// Общие методы, используемые в нескольких сервисах.
enum TextUtilities {
    
    /// Проверяет, является ли символ кириллическим.
    /// Используется для определения языка текста и фильтрации.
    static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        // Кириллица: U+0400–U+04FF (базовая), U+0500–U+052F (дополнительная),
        // U+2DE0–U+2DFF (кириллица расширенная), U+A640–U+A69F (кириллица расширенная C)
        let value = scalar.value
        return (0x0400...0x04FF).contains(value) ||
               (0x0500...0x052F).contains(value) ||
               (0x2DE0...0x2DFF).contains(value) ||
               (0xA640...0xA69F).contains(value)
    }
    
    /// Проверяет, содержит ли текст кириллические символы.
    static func containsCyrillic(_ text: String) -> Bool {
        return text.unicodeScalars.contains { isCyrillic($0) }
    }
    
    /// Возвращает доминирующий скрипт в тексте (Cyrillic или Latin).
    static func dominantScript(_ text: String) -> String? {
        let cyrillicCount = text.unicodeScalars.filter { isCyrillic($0) }.count
        let latinCount = text.unicodeScalars.filter { $0.properties.isAlphabetic && !isCyrillic($0) }.count
        
        if cyrillicCount == 0 && latinCount == 0 { return nil }
        return cyrillicCount >= latinCount ? "Cyrillic" : "Latin"
    }
}
