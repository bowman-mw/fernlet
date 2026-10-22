//
//  LanguagePack+SpanishScreens.swift
//  FernletDomainModel
//
//  Spanish terms for the two keyword screens (localization plan §5.4, "the honesty items"):
//  `DiagnosticLanguage`, the clinical-language screen the privacy policy describes, and
//  `ItemNameModeration`, the clothing shop's name gate. Both screens hold in EVERY language at once,
//  whatever the interface language — a person can journal in Spanish in an English app — so these
//  lists are always on (`LanguagePack.all`).
//
//  Both are best-effort keyword screens, as their own docs say, and both match a normalized
//  substring: lowercase, accents folded, every separator removed ("tras torno" → "trastorno"). A
//  short word that sits inside ordinary words is matched only as a WHOLE word instead: "toc" (the
//  Spanish OCD) is inside "tocino", "puta" inside "reputation", "verga" inside "overgarment".
//  `LanguagePackTests` checks no stem fires on ordinary English and Spanish text.
//
//  Left out on purpose (the owner may decide otherwise):
//  - Clinical: "tratamiento", "pastillas" and "quemado" (treatment, pills, burnt — far too common in
//    food and exercise text); "regla" is whole-word only, because "arreglar" contains it.
//  - Moderation: "coño" (folds to "cono", the ice-cream cone, and sits inside "economy"), "polla"
//    and "pija" (innocent in some countries), "pinche" and "boludo" (mild), "zorra" (also "fox"),
//    "gonorrea" (a Colombian insult, but also the disease's name), "retrasado" (also "delayed";
//    English "retard" already catches "retardado").
//

import Foundation

extension LanguagePack {
    /// Spanish clinical and diagnostic stems, matched as substrings of the separator-free text. Each
    /// covers its family once folded: "depresi" is depresión, depresivo and antidepresivo.
    static let spanishClinicalStems: [String] = [
        "trastorno", "sindrom", "depresi", "deprimid", "ansiedad", "ansios", "ansiolitic",
        "esquizofren", "psicosis", "psicotic", "psiquiatr", "terapia", "terapeut",
        "medicament", "medicacion", "recetamedic", "prescripci", "clinico", "clinica",
        "postraumat", "obsesivocompulsiv", "ataquedepanico", "anorexi", "bulimi", "insomnio",
        "disoci", "narcisis", "evitativ", "burnout",
        "menstrua", "ciclo", "embaraz", "aborto", "intimidad",
        "autolesi", "hacermedano"
    ]

    /// Spanish clinical words matched only as whole words: the Spanish abbreviations for OCD,
    /// ADHD and PTSD, "regla" (a period, but inside "arreglar"), and "maníaco".
    static let spanishClinicalWholeWords: Set<String> = [
        "toc", "tdah", "tept", "regla", "maniaco", "maniaca", "maniacos", "maniacas", "autista", "autistas"
    ]

    /// Spanish profanity and slurs blocked from a listed item's name, matched as substrings of the
    /// normalized name (diacritics and leetspeak folded, separators removed).
    static let spanishBlockedNameStems: [String] = [
        "pendej", "cabron", "chingad", "mierda", "joder", "gilipolla", "hijodeputa", "hijueputa",
        "putamadre", "culero", "mamada", "follar", "maricon", "sudaca", "negrata", "carajo",
        "cojone", "puneta", "pelotudo", "malparid", "mamaguevo", "mamahuevo", "violador", "pedofil"
    ]

    /// Spanish words blocked only as whole words, because each sits inside ordinary words
    /// ("puta" in "reputation", "culo" in "ridiculous", "verga" in "overgarment", "chinga" in
    /// "matching apron").
    static let spanishBlockedNameWholeWords: Set<String> = [
        "puta", "putas", "puto", "putos", "culo", "culos", "verga", "vergas", "chinga",
        "marica", "maricas", "joto", "jotos"
    ]
}
