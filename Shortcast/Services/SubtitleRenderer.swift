import AppKit

/// Shared typography and Ukrainian function words used by the essay pipeline.
enum SubtitleRenderer {
    static let minorWords: Set<String> = [
        "А", "І", "В", "НА", "З", "У", "К", "О", "ОБ", "ВІД", "ДО", "ЗІ", "ПО", "ЗА", "АЛЕ",
        "НЕ", "ЩО", "ЯК", "ТО", "ЖЕ", "ТИ", "Я", "ВІН", "ВОНА", "ВОНО", "МИ", "ВИ", "ВОНИ",
        "ЦЕ", "ТУТ", "ТАМ", "ОСЬ", "БИ", "ЧИ", "ТАК", "НІ", "ДЕ", "ХТО", "ЧИМ", "ОТО",
        "ВЖЕ", "ВСЕ", "ЙОГО", "ЇЇ", "ЇХ", "ТОБІ", "МЕНІ", "НАМ", "ВАМ", "ЇМ"
    ]

    static func resolveFont(name: String, size: CGFloat, fallback: NSFont.Weight = .heavy) -> NSFont {
        FontDownloadService.shared.registerBundledFonts()
        
        // 1. Try exact PostScript name match
        if let f = NSFont(name: name, size: size) {
            return f
        }
        
        // 2. Variable font support: try family name + bold trait via NSFontDescriptor.
        //    Variable fonts (e.g. Oswald) register under family "Oswald" but
        //    NSFont(name: "Oswald-Bold") fails because CoreText doesn't synthesize
        //    PostScript names for individual variation instances.
        let oswaldFamilies = ["Oswald", "Anton"]
        for family in oswaldFamilies {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.bold.rawValue]
            ])
            let matched = descriptor.matchingFontDescriptor(withMandatoryKeys: [.family])
            if let matched {
                if let font = NSFont(descriptor: matched, size: size) {
                    // Apply bold weight via font manager for variable fonts
                    let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    return boldFont
                }
            }
        }
        
        // 3. Impact (system font, always available on macOS)
        if let f = NSFont(name: "Impact", size: size) {
            return f
        }
        
        // 4. Montserrat fallback (bundled static fonts)
        if let f = NSFont(name: "Montserrat-Black", size: size) ?? NSFont(name: "Montserrat-ExtraBold", size: size) {
            return f
        }
        if let f = NSFont(name: "Arial-Black", size: size) {
            return f
        }
        
        // 5. System Font Black (San Francisco Black)
        return NSFont.systemFont(ofSize: size, weight: .black)
    }

}
