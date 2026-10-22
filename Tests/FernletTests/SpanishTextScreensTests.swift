import Foundation
import Testing
@testable import FernletDomainModel

/// Localization plan §5.4, "the honesty items", for Spanish: the clinical-language screen the privacy
/// policy describes and the clothing shop's name gate read Spanish too.
///
/// Both hold in every language at once, whatever the interface language — so, unlike the food
/// parsers, nothing here is bound to an input language, and the English-only test host proves it.
/// Both match a folded, separator-free substring, with a whole-word list for the short terms that sit
/// inside ordinary words.
struct SpanishTextScreensTests {

    // MARK: - Clinical language

    @Test func spanishClinicalLanguageIsCaught() {
        let sentences = [
            "Me diagnosticaron depresión", "Tengo mucha ansiedad", "Estoy muy ansiosa hoy",
            "Me siento deprimido", "trastorno bipolar", "Hablé con mi psiquiatra", "Empecé terapia",
            "Tomo un medicamento nuevo", "Me dieron una receta médica", "estoy embarazada",
            "Tuve un aborto", "Me llegó la regla", "Mi ciclo se adelantó", "Tengo TDAH", "Tengo TOC",
            "Otra noche de insomnio", "pensamientos de autolesión", "ideas suicidas",
            "Tuve un ataque de pánico", "anorexia", "síndrome de burnout", "un episodio maníaco",
            "Mi hijo es autista", "trastorno obsesivo-compulsivo", "estrés postraumático"
        ]
        for sentence in sentences {
            #expect(DiagnosticLanguage.contains(sentence), "not caught: \(sentence)")
        }
    }

    @Test func spanishEvasionsFoldLikeEnglishOnes() {
        for evasion in ["d e p r e s i ó n", "DEPRESIÓN", "ansi.edad", "tras-torno", "Psiquiatría"] {
            #expect(DiagnosticLanguage.contains(evasion), "\(evasion)")
        }
        // The documented trade of a whole word: spelled with separators inside it, it is not read.
        #expect(!DiagnosticLanguage.contains("T.D.A.H"))
    }

    @Test func ordinarySpanishPassesTheScreen() {
        let sentences = [
            "Comí huevos con tocino", "Arreglé la bicicleta en la mañana", "Caminé por el parque con mi perro",
            "Cociné arroz con pollo", "Hoy hice ejercicio y me sentí fuerte", "Leí un libro en la terraza",
            "Mi abuela me enseñó una receta", "El flautista tocó toda la tarde", "Las reglas del juego",
            "Preparé una ensalada de manzana", "Dormí ocho horas"
        ]
        for sentence in sentences {
            #expect(!DiagnosticLanguage.contains(sentence), "over-matched: \(sentence)")
        }
    }

    @Test func ordinaryEnglishStillPasses() {
        let sentences = [
            "had a great workout and felt strong", "cooked a nice dinner with friends",
            "Got a manicure after the long walk", "Read about Germanic languages on the train",
            "The flautist played all afternoon", "Bought a new recipe book"
        ]
        for sentence in sentences {
            #expect(!DiagnosticLanguage.contains(sentence), "over-matched: \(sentence)")
        }
    }

    @Test func theScreenHoldsInSpanishWhateverTheInterfaceLanguage() {
        #expect(InputLanguages.current == .englishOnly)
        #expect(DiagnosticLanguage.contains("depresión"))
        // Wherever the screen is applied, so: a journal summary that names a Spanish diagnosis is
        // rejected before it can become a memory.
        #expect(JournalMemorySummaryPolicy.accepted("Habla de su depresión", entryText: "Hoy fue un día largo.") == nil)
        #expect(JournalMemorySummaryPolicy.accepted("Un paseo largo por el parque", entryText: "Hoy caminé mucho.") != nil)
    }

    // MARK: - Item names

    @Test func spanishProfanityIsBlockedIncludingEvasions() {
        for name in ["Pendejo", "c4br0n hat", "m i e r d a", "Gorra de puta madre", "Puta", "put@", "Verga",
                     "Hat culo", "hijo de puta", "MARICÓN", "joder"] {
            #expect(!ItemNameModeration.isAllowedForListing(name), "expected ‘\(name)’ to be blocked")
        }
    }

    @Test func innocentNamesThatContainAShortTermAreAllowed() {
        for name in ["Reputation Hat", "Overgarment", "Matching Apron", "Ridiculous Hat", "Computadora",
                     "Cono de helado", "Capa roja", "Gorro de lana", "Particular Scarf", "Calculadora"] {
            #expect(ItemNameModeration.isAllowedForListing(name), "expected ‘\(name)’ to be allowed")
        }
    }

    @Test func wholeWordsFoldLikeTheSubstringList() {
        #expect(ItemNameModeration.words(of: "Put@ Hat!") == ["puta", "hati"])
        #expect(ItemNameModeration.words(of: "ＶＥＲＧＡ") == ["verga"])
    }
}
