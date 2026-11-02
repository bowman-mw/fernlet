# Fernlet Spanish glossary and style rules (`es`, Spain)

**Status:** approved line by line by the owner, a native Spanish speaker, on 2026-10-20, for one
neutral Spanish. On 2026-11-01 the owner split Spanish in two: `es` is **Spain Spanish (castellano)**
and `es-MX` is Mexican Spanish, a separate localization with its own word choices. This file is the
`es` (Spain) half; the rows changed for Spain on 2026-11-01 say so in their notes and await the
owner's look. Every `es` string follows this file. A translation that needs a word not listed here
uses the word Apple's Spain Spanish iOS uses; if there is none, the owner picks it and it is added
here in the same commit.

**Decided:**
- **Variant:** `es` is castellano as spoken in Spain (2026-11-01). `es-MX` covers Mexico and is not
  edited from this file.
- **Address:** tú to the person (D-L1 in `Docs/Localization-Plan-2026-07-19.md`); **vosotros** when
  a line speaks to two or more people at once (a hangout, two phones held together).
- **Gender:** words that describe the user agree with the body profile's **Sex** answer
  (`UserProfile.sex`): female draws the feminine form, male the masculine. Male is the profile's
  default, so a user who never answered sees masculine forms. There is no separate “address me
  as” setting (owner, 2026-10-20). Translators write the masculine form and mark each such word
  `^[listo](inflect: true)`; the app inflects it with Foundation's `TermOfAddress`.
- **The companion** is grammatically masculine: *el compañero*, and *Estoy contento* in its own
  first-person lines.

## Style rules

### Castellano (Spain)

Write the way people in Spain talk and the way Apple's Spain Spanish iOS writes: móvil, añadir, zumo, patata, ordenador, coche, vídeo, Ajustes. Vosotros for a group (“Os habéis encontrado”), never ustedes. Still skip words that are rude elsewhere (see below): Spanish speakers outside Spain and Mexico fall back to this localization.

- EN: Add your first meal
- ES: Añade tu primera comida

### Tú, always

Warm and informal everywhere, errors and privacy copy included. Never usted.

- EN: Are you sure you want to delete it?
- ES: ¿Seguro que quieres eliminarlo?

### Words about the user follow their form of address

Write the masculine form and wrap each word that describes the user in inflection markup. Fernlet swaps it to the feminine for users who chose it (masculine when nothing was chosen). No slashes, no @, x or e endings.

- EN: Start your next set when you're ready.
- ES: Empieza la siguiente serie cuando estés ^[listo](inflect: true).  →  … cuando estés lista.

### No words with a second meaning somewhere

Skip words that are rude in some countries: coger (use tomar, agarrar or sujetar), concha, pico, bicho, paja.

- EN: Grab the dumbbells.
- ES: Toma las mancuernas.

### Sentence case

Titles and buttons use sentence case. Only names keep capitals (Fernlet, Salud, Apple Watch).

- EN: Add a Workout
- ES: Agregar un entrenamiento

### Buttons in the infinitive, instructions in tú

Buttons and menu items use the infinitive, as iOS does. Instructions and the companion's own lines use the tú imperative.

- EN: Save · Breathe slowly
- ES: Guardar · Respira despacio

### Apple's own words

Use the names Apple uses in Spain Spanish iOS: Salud, Ajustes, Llavero de iCloud, código, Atajos, pantalla de bloqueo, Actividad en directo. A tap on the screen is *tocar* (“Toca un día”), a touch-and-hold is *mantener pulsado*, and a physical button is *pulsar*.

- EN: Turn it on in Settings › Health.
- ES: Actívalo en Ajustes › Salud.

### Keep it short

Spanish runs 20–30% longer than English. On the tab bar, buttons, widgets and the Live Activity, pick the shorter word.

- EN: Log it again
- ES: Registrar otra vez

### Gentle, never clinical

No guilt, no “deberías”, no streak talk. At most one exclamation mark per string.

- EN: However today went, a small note of care still counts.
- ES: Como haya ido el día, una pequeña nota de cuidado también cuenta.

### Adapt the jokes

The silly stats and the companion's jokes keep the joke, not the words. Swap the image when it doesn't land in Spanish.

- EN: The hens are unionizing.
- ES: Las gallinas ya están formando un sindicato.

### Punctuation, placeholders and numbers

Always open with ¿ and ¡. Quotes are “ ”. Keep every %@ and %lld; use %1$@ and %2$@ to reorder. Never write numbers, dates or units into a translation: the system formats them, decimal comma included.

- EN: Re-import from %@?
- ES: ¿Volver a importar desde %@?

### Errors keep Fernlet as the subject

Say what happened and what to do next, with Fernlet as the subject rather than an impersonal “Error al…”.

- EN: Fernlet couldn't save the recipe. Try again in a moment.
- ES: Fernlet no pudo guardar la receta. Inténtalo de nuevo en un momento.

## Glossary

### Fernlet's own words

| English | Spanish | Notes |
| --- | --- | --- |
| Fernlet | Fernlet | Never translated. Used without an article when it is the subject: “Fernlet no pudo…”. |
| companion | compañero | The companion talks in the first person (“I made you a pie chart”), so its own adjectives need one fixed gender: “Estoy contento” or “Estoy contenta”. Masculine matches “el Fernlet”. |
| Home (tab) | Inicio |  |
| Food (tab) | Comida | “Comida” also means “meal”; the tab and the meal word can share it. |
| Move (tab) | Moverse | “Moverse” is Apple Fitness's name for the Move ring in Spanish. |
| Journal (tab) | Diario |  |
| Cycle | Ciclo |  |
| Calm | Calma |  |
| Private (hub) | Privado |  |
| Friends | Amigos | Generic masculine plural, as everyday Spanish uses it. |
| Today | Hoy |  |
| Settings | Ajustes | Spain's iOS name for Settings (2026-11-01; was “Configuración”, Latin America's). |
| Silly stats | Estadísticas absurdas | Owner's pick over “Datos curiosos”. |
| care · self-care | cuidado · autocuidado |  |
| gentle | suave · con cariño | No single word. “Suave” for intensity (a gentle stretch: un estiramiento suave); “con cariño” or “trátate bien” for tone. |
| enoughness | lo suficiente | A concept, not a word. Translate it per sentence: “…y la idea de que lo que haces ya es suficiente”. |

### Apple's words

| English | Spanish | Notes |
| --- | --- | --- |
| Apple Health · the Health app | Salud · la app Salud | Apple's name for the app in Spanish. |
| Apple Fitness | Fitness |  |
| iCloud Keychain | Llavero de iCloud |  |
| passcode | código | As in iOS's “Face ID y código”. |
| Face ID | Face ID |  |
| Lock Screen | pantalla de bloqueo | Spain's iOS term (2026-11-01). |
| Home Screen | pantalla de inicio |  |
| Live Activity | Actividad en directo | Spain's iOS term (2026-11-01; was “en vivo”). |
| Dynamic Island | Dynamic Island |  |
| Shortcuts | Atajos |  |
| Messages | Mensajes |  |
| Photos | Fotos |  |
| Apple Intelligence | Apple Intelligence |  |
| Secure Enclave | Secure Enclave |  |
| notification | notificación |  |
| silent mode | modo silencioso |  |

### Privacy and safety

| English | Spanish | Notes |
| --- | --- | --- |
| backup | copia de seguridad | Latin American iOS says “Respaldo en iCloud”; Spain says “copia de seguridad”. Owner's pick over “respaldo”. |
| sealed · sealed backup | sellado · copia de seguridad sellada | Fernlet's own word for the journal, cycle and intimacy data kept encrypted out of the synced copy. Follows the owner's choice of “copia de seguridad” for backup. |
| encrypted | cifrado | Apple writes “cifrado”; “encriptado” is common speech. |
| App Lock | bloqueo de la app |  |
| duress code | código de coacción | The code you type when someone forces you to open Fernlet. “Coacción” is the precise word but formal; “de emergencia” is friendlier but less exact. |
| recovery device | dispositivo de recuperación |  |
| unlock | desbloquear |  |
| delete everything | borrar todo | “Eliminar” for deleting one thing, “borrar” for wiping everything, as iOS's “Borrar contenido y configuración”. |
| in person | en persona |  |
| nearby · nearby friends | cerca · amigos cerca |  |
| Report… | Denunciar… | Spain's word (2026-11-01; was “Reportar”, the Latin American one). |
| block | bloquear |  |

### Food

| English | Spanish | Notes |
| --- | --- | --- |
| meal | comida |  |
| breakfast | desayuno |  |
| lunch | almuerzo | In Spain the midday meal is also “la comida”, but that collides with “meal” and the Food tab. |
| dinner | cena |  |
| snack | tentempié | Spain's word for the meal slot (2026-11-01; was “snack”). |
| log (verb) · log (noun) | registrar · registro |  |
| recipe · recipe book | receta · recetario |  |
| serving | ración | As Spain's nutrition labels say “por ración” (2026-11-01; was “porción”). |
| ingredient | ingrediente |  |
| grocery list | lista de la compra | Spain's phrase (2026-11-01). |
| nutrition label | información nutricional | Owner's pick over “etiqueta nutricional”. |
| barcode | código de barras |  |
| calories · cal | calorías · kcal | Short labels always say kcal, never cal. |
| protein · carbs · fat · fiber | proteína · carbohidratos · grasa · fibra |  |
| water · glass | agua · vaso |  |
| cup · tablespoon · teaspoon | taza · cucharada · cucharadita |  |
| timer | temporizador |  |

### Movement

| English | Spanish | Notes |
| --- | --- | --- |
| workout | entrenamiento |  |
| workout plan | plan de entrenamiento |  |
| guided workout | entrenamiento guiado |  |
| session | sesión |  |
| set | serie |  |
| rep · reps | rep. · reps | Short form wherever English writes rep or reps (“3 × 10 reps”). |
| rest · rest day | descanso · día de descanso |  |
| warm-up | calentamiento |  |
| cool-down | enfriamiento |  |
| stretch | estiramiento |  |
| strength · cardio · mobility | fuerza · cardio · movilidad |  |
| dumbbell · barbell · bench | mancuerna · barra · banco |  |
| resistance band | banda elástica |  |
| plateau | estancamiento |  |
| effort | esfuerzo |  |
| heart rate | frecuencia cardiaca | Apple Health's spelling. |
| steps | pasos |  |
| progress photos | fotos de progreso |  |

### Wellbeing, cycle and intimacy

| English | Spanish | Notes |
| --- | --- | --- |
| journal entry | entrada del diario |  |
| mood · feelings | estado de ánimo · emociones |  |
| sleep | sueño |  |
| worry box | caja de preocupaciones |  |
| breathing exercise | ejercicio de respiración |  |
| grounding | anclaje | The 5-4-3-2-1 kind of exercise. Spanish-language therapists use all three. |
| period | periodo | Apple Health says “periodo”; “regla” is everyday speech in Spain and parts of Latin America. |
| cycle tracking | seguimiento del ciclo |  |
| predicted | previsto |  |
| spotting | manchado |  |
| flow: light · medium · heavy | flujo: leve · moderado · abundante |  |
| cramps | dolor menstrual · calambres | “Cólicos” is the Latin American word (2026-11-01). |
| cervical mucus · egg white | moco cervical · clara de huevo |  |
| ovulation · fertile window | ovulación · ventana fértil |  |
| intimacy · intimate log | intimidad · registro íntimo |  |
| sexual activity | actividad sexual | Apple Health's term. |
| I'm unwell today | Hoy no me siento bien |  |

### Companion and play

| English | Spanish | Notes |
| --- | --- | --- |
| wardrobe | armario | Spain's word (2026-11-01; the owner's pick for neutral Spanish was “clóset”). |
| coins · shop | monedas · tienda |  |
| hearts | corazones |  |
| creation studio | estudio de creación |  |
| stamp · stamp book | sello · álbum de sellos | The silly stats' stamps (draft, 2026-10-22, needs the owner's review): the kind pressed into a passport or an album, not a postage stamp. Each stamp's name is a joke drafted to keep the joke (“Encore” → “¡Otra, otra!”, “Small Step” → “Un pequeño paso”), and a name that would describe the user (“Floss Boss”) becomes one that doesn't (“Hilo de oro”), so no stamp needs gender agreement. |

### Buttons and common UI

| English | Spanish | Notes |
| --- | --- | --- |
| Done | OK | iOS in Spanish labels Done buttons “OK”; “Listo” also reads naturally. |
| Cancel | Cancelar |  |
| Save | Guardar |  |
| Add | Añadir | Spain's word (2026-11-01; was “Agregar”). |
| Delete · Remove | Eliminar · Quitar |  |
| Edit · Share | Editar · Compartir |  |
| Continue · Next · Back | Continuar · Siguiente · Atrás |  |
| Not now · Skip | Ahora no · Omitir |  |
| Try again | Reintentar · Inténtalo de nuevo | “Reintentar” on a button, “Inténtalo de nuevo” in a sentence. |
| Turn on · Turn off | Activar · Desactivar |  |
| Undo · Allow | Deshacer · Permitir |  |
| Open · Close · Search | Abrir · Cerrar · Buscar |  |
| Learn more | Más información |  |


### Spain's everyday words (2026-11-01)

Where Spain and Latin America part ways, `es` takes Spain's word. `es-MX` keeps its own.

| English | Spain (`es`) | Not | Notes |
| --- | --- | --- | --- |
| phone | móvil | celular |  |
| hangout (meeting friends in person) | quedada | reunión | Fernlet's in-person hangout. |
| tap · touch and hold · press (a button) | tocar · mantener pulsado · pulsar |  | As Apple's Spain iOS. |
| video | vídeo | video | Spain writes the accent. |
| computer · car · drive | ordenador · coche · conducir | computadora · carro, auto · manejar |  |
| juice · potato · sweet potato | zumo · patata · boniato | jugo · papa · camote |  |
| peach · strawberry · banana | melocotón · fresa · plátano | durazno · frutilla · banana |  |
| peanut · avocado · shrimp | cacahuete · aguacate · gamba | maní, cacahuate · palta · camarón |  |
| peas · green beans · beans | guisantes · judías verdes · alubias | chícharos, arvejas · ejotes · frijoles |  |
| cake · smoothie · fridge | tarta · batido · nevera | pastel, torta · licuado · refrigerador |  |
| glasses · T-shirt · sweater · sneakers | gafas · camiseta · jersey · zapatillas | lentes · playera · suéter · tenis |  |
| apartment · bedroom · pool · blanket | piso · dormitorio · piscina · manta | departamento · recámara · alberca · cobija |  |
| angry · cute · to miss someone | enfadado · bonito · echar de menos | enojado · lindo · extrañar |  |
| to check · to go back · to hurry | comprobar · volver · darse prisa | checar · regresar · apurarse |  |
| sore muscles (after training) | agujetas | dolor muscular | Everyday Spain word. |
| walk (on foot) | andar · caminar · paseo | caminata | All fine in Spain; “paseo” for a gentle walk. |
