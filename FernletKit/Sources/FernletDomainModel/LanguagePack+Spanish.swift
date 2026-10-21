//
//  LanguagePack+Spanish.swift
//  FernletDomainModel
//
//  Spanish matching vocabulary (localization plan §5.2–§5.4). Neutral Spanish leaning Latin
//  American, as the glossary decides (Docs/Localization-es-Glossary.md), with Spain's everyday
//  words added wherever they are unambiguous, because these are words people TYPE, not words
//  Fernlet writes. Every key is folded (lowercase, no accents): "cucharadita", "porción" →
//  "porcion". The owner, a native speaker, reviews these lists.
//

import Foundation

extension LanguagePack {
    /// Spanish: the units, connectors and plural rules of typed Spanish food text.
    static let spanish = LanguagePack(
        language: .spanish,
        unitSpellings: spanishUnitSpellings,
        countWords: ["diente", "dientes"],
        quantityConnectors: ["de", "del"],
        mealJoiners: ["y"],
        mealCompanions: ["con"],
        companionModifiers: [
            "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez",
            "extra", "doble", "triple"
        ],
        joinedDishNames: [
            "chili con carne", "chile con carne", "chili con queso", "chile con queso",
            "arroz con leche", "arroz con pollo"
        ],
        pluralRules: [
            // nueces → nuez, lombrices → lombriz
            PluralRule(suffix: "ces", replacement: "z", minimumStemLength: 2),
            // limones → limon, frijoles → frijol, panes → pan, flores → flor
            PluralRule(suffix: "es", after: "lnrdjy", minimumStemLength: 2),
            // manzanas → manzana, huevos → huevo, tomates → tomate
            PluralRule(suffix: "s", after: "aeiou")
        ]
    )

    /// Spanish unit words and their abbreviations → the unit token each means. Matching inputs only:
    /// "2 tazas" still stores `cup`.
    ///
    /// Spain's "loncha" and Mexico's "rebanada" are both slices; "trozo" and "pedazo" are pieces.
    /// Left out on purpose: "feta" (a slice in Argentina, a cheese everywhere), "pizca" (a pinch:
    /// Fernlet has no pinch unit, so it stays part of the food's text, as English "pinch" does).
    static let spanishUnitSpellings: [String: RecipeUnit] = [
        "miligramo": .milligram, "miligramos": .milligram,
        "gramo": .gram, "gramos": .gram, "gr": .gram, "grs": .gram,
        "kilo": .kilogram, "kilos": .kilogram, "kilogramo": .kilogram, "kilogramos": .kilogram,
        "mililitro": .milliliter, "mililitros": .milliliter,
        "litro": .liter, "litros": .liter,
        "onza": .ounce, "onzas": .ounce,
        "libra": .pound, "libras": .pound,
        "onza liquida": .fluidOunce, "onzas liquidas": .fluidOunce,
        "taza": .cup, "tazas": .cup,
        "cucharada": .tablespoon, "cucharadas": .tablespoon, "cda": .tablespoon, "cdas": .tablespoon,
        "cucharada sopera": .tablespoon, "cucharadas soperas": .tablespoon,
        "cucharadita": .teaspoon, "cucharaditas": .teaspoon, "cdta": .teaspoon, "cdtas": .teaspoon,
        "cdita": .teaspoon, "cditas": .teaspoon,
        "vaso": .glass, "vasos": .glass,
        "rebanada": .slice, "rebanadas": .slice, "rodaja": .slice, "rodajas": .slice,
        "tajada": .slice, "tajadas": .slice, "loncha": .slice, "lonchas": .slice,
        "lonja": .slice, "lonjas": .slice,
        "pieza": .piece, "piezas": .piece, "trozo": .piece, "trozos": .piece,
        "pedazo": .piece, "pedazos": .piece,
        "unidad": .each, "unidades": .each,
        "porcion": .serving, "porciones": .serving, "racion": .serving, "raciones": .serving
    ]
}
