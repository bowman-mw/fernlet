# Fernlet's Mexican Spanish (`es-MX`)

Fernlet ships two Spanish variants. `es` is Spain's Spanish ([Localization-es-Glossary.md](Localization-es-Glossary.md)).
`es-MX` is what an iPhone set to Español (México) reads. It is **tú, always**, like `es`, and **ustedes, never vosotros**
when a line speaks to two people.

## `es-MX` must be complete

iOS does not fall back from `es-MX` to `es` key by key. Once a bundle has an `es-MX.lproj`, a key missing from that table
is simply missing and draws its English default (measured on the iOS 26.5 simulator, 2026-11-01: 6,313 of 7,259 keys).
So every `es` entry has an `es-MX` entry, in every catalog. A string that reads the same in both is a plain copy.

When you add a Spanish string, run `Scripts/fill-es-mx-catalogs.py`, then replace any Spain-only wording in what it copied.
`LocalizationBoundaryTests.mexicanSpanishIsCompleteAndNeverSpains` fails while an `es` string has no `es-MX`, and when
`es-MX` has vosotros, "quedada" or "pulsado". The copy does not follow later edits: when you fix an `es` string for a
reason both variants share, fix its `es-MX` too.

## Words

| English | Spain (`es`) | Mexico (`es-MX`) |
| --- | --- | --- |
| hangout | quedada | convivio (masculine: un convivio, el convivio) |
| Settings | Ajustes | Configuración |
| phone | móvil | teléfono; celular in the tap-to-connect line |
| add | añadir | agregar |
| touch and hold | mantener pulsado | mantener presionado |
| lunch | almuerzo | comida (almuerzo is a late breakfast in Mexico) |
| snack | tentempié | colación; botana in Sprout's jokes |
| report | denunciar | reportar |
| closet | armario | clóset |
| glasses | gafas | lentes |
| flight ticket | billete | boleto |
| serving | ración | porción |
| walk | paseo | caminata (a bike ride stays "paseo en bici") |
| to drive · car | conducir · coche | manejar · carro |
| flat | piso | depa |
| pool | piscina | alberca |
| treadmill | cinta | caminadora |
| pull (exercise) | tirar de | jalar |
| lunge | zancada | desplante |
| calves | gemelos | pantorrillas |
| lie down | tumbarse | acostarse |
| rail | barandilla | barandal |
| weather | tiempo | clima |
| past tense, for something just done | has registrado | registraste |

Sample food in the App Review demo: licuado, camote, durazno, cacahuate, camarón, hot cakes, jitomate, yogurt, refri.

Numbers Fernlet groups by hand use "," in `es-MX` ("24,850 km") and "." in `es`
(`FernletLanguage.thousandsSeparator(localization:)`). Country names on city cards come from the app's own variant. The
passport's stamps carry one Spanish name each (`WorldCountryStamps.json`), Spain's for "Arabia Saudí" and "Rumanía".
