import Foundation

/// Генератор вирусной упаковки для YouTube Shortcast Cinema
enum LongformMetadataGenerator {

    /// Формирует полный пакет метаданных для ролика
    static func generate(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> LongformYouTubeMetadata {
        let title = concept.suggestedTitle

        let safeMovieTitle = MovieMetadataService.isGarbageTitle(movieTitle) ? "фильма" : "фильма «\(movieTitle)»"

        let desc = """
        Этот ролик — про одну из главных мыслей \(safeMovieTitle).

        \(concept.tagline)

        \(concept.philosophicalPremise)

        Иногда самые сильные испытания не ломают человека, а показывают, из чего он сделан на самом деле.

        \(LongformYouTubeMetadata.standardFairUseDisclaimer)

        #мотивация #саморазвитие #психология #эмоции #жизнь #характер #мышление #сила #фильм
        """

        var baseTags = [
            concept.word.lowercased(),
            "мотивация",
            "саморазвитие",
            "психология",
            "характер",
            "мышление",
            "фильмы",
            "сила духа",
            "успех",
            "жизненные уроки",
            "кино",
            "смысл жизни"
        ]
        if !MovieMetadataService.isGarbageTitle(movieTitle) {
            baseTags.insert(movieTitle.lowercased(), at: 1)
        }

        let pinnedComment = "Напиши в комментариях, какой момент из \(safeMovieTitle) произвел на тебя самое сильное впечатление 👇"

        return LongformYouTubeMetadata(
            title: title,
            description: desc,
            tags: baseTags,
            pinnedComment: pinnedComment
        )
    }
}
