import Foundation

/// One sRGB colour from the landmark art file, parsed from `#RRGGBB`.
public nonisolated struct LandmarkArtColour: Hashable, Sendable {
    /// Red, 0–255.
    public let red: UInt8
    /// Green, 0–255.
    public let green: UInt8
    /// Blue, 0–255.
    public let blue: UInt8

    /// The colour `hex` names (`#RRGGBB`), or nil for anything else.
    public init?(hex: String) {
        let digits = Array(hex.utf8)
        let hexDigits = digits.dropFirst()
        guard digits.count == 7, digits.first == UInt8(ascii: "#"),
              hexDigits.allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
              let value = UInt32(String(decoding: hexDigits, as: UTF8.self), radix: 16) else { return nil }
        red = UInt8((value >> 16) & 0xFF)
        green = UInt8((value >> 8) & 0xFF)
        blue = UInt8(value & 0xFF)
    }
}

/// A colour for light mode and one for dark mode.
public nonisolated struct LandmarkArtPair: Hashable, Sendable {
    /// The light-mode colour.
    public let light: LandmarkArtColour
    /// The dark-mode colour.
    public let dark: LandmarkArtColour
}

/// One landmark sprite: rows of palette indices, ``LandmarkSprite/clear`` where nothing is drawn.
public nonisolated struct LandmarkSprite: Hashable, Sendable {
    /// The index that means "clear" (the file's `.`).
    public static let clear = UInt8.max
    /// Width in pixels.
    public let width: Int
    /// Height in pixels.
    public let height: Int
    /// `height` rows of `width` palette indices each, top row first.
    public let pixels: [[UInt8]]
    /// The English name the art file gives (data: a famous landmark's name, or a generic kind's).
    public let englishName: String
    /// The Spanish name the art file gives.
    public let spanishName: String
}

/// The landmark art the design session approved (World-Exploration-Spec §2; `World-Landmark-Art.json`, bundled
/// as `WorldLandmarkArt.json`): one shared palette, the famous sprites by art id, the generic icons by
/// ``AtlasLandmarkKind``, the found and not-found halos, the not-found greys and the draw scales.
///
/// **Found and not found.** Found art takes the palette's colours. Before it is found every pixel of the
/// outline letter (``outlineLetter``, `k`) takes ``notFoundOutline`` and every other drawn pixel
/// ``notFoundFill``, so it stands grey and unnamed through the fog. Either way a one-pixel halo
/// (``foundHalo`` or ``notFoundHalo``) rings every drawn pixel.
///
/// **Refused, never trapped.** ``init(data:)`` throws ``ArtError`` for a file over ``maxFileBytes``, a version
/// other than ``version``, a palette letter that is not one ASCII character or repeats, a colour that is not
/// `#RRGGBB`, a palette without the outline letter, a sprite whose size is outside 1…``maxSide`` or whose rows
/// don't match it, a pixel letter the palette lacks, an unknown generic kind, or more than ``maxSprites``.
public nonisolated struct WorldLandmarkArt: Sendable {
    /// The file format this build reads.
    public static let version = 1
    /// The largest file read.
    public static let maxFileBytes = 256 * 1_024
    /// The longest sprite side, in pixels.
    public static let maxSide = 64
    /// The most sprites (famous and generic together).
    public static let maxSprites = 256
    /// The most palette letters.
    public static let maxPalette = 64
    /// The palette letter that is the outline (it turns ``notFoundOutline`` before a landmark is found).
    public static let outlineLetter: Character = "k"

    /// Why an art file was refused.
    public enum ArtError: Error, Equatable {
        /// Over ``maxFileBytes``.
        case tooLarge
        /// Not an art file (bad JSON, a missing field, a wrong type).
        case malformed
        /// A version this build does not read.
        case unsupportedVersion(Int)
        /// A palette letter that is not one ASCII character, repeats, has a bad colour, or the palette is over
        /// ``maxPalette`` or lacks ``outlineLetter``.
        case badPalette(String)
        /// A colour in the halo or not-found greys that is not `#RRGGBB`.
        case badColour(String)
        /// A sprite with a bad size, rows that don't match it, or a letter the palette lacks; or more than
        /// ``maxSprites``.
        case badSprite(String)
        /// A generic sprite whose kind is not an ``AtlasLandmarkKind``.
        case unknownKind(String)
    }

    /// The palette letters in file order; a sprite pixel is an index into this.
    public let letters: [Character]
    /// The palette colours, by the same index.
    public let colours: [LandmarkArtColour]
    /// The index of ``outlineLetter`` in the palette.
    public let outlineIndex: UInt8
    /// The famous sprites by art id (`eiffel`, `empire`, `opera`, `colosseum`).
    public let famous: [String: LandmarkSprite]
    /// The generic icons by kind.
    public let generic: [AtlasLandmarkKind: LandmarkSprite]
    /// The halo around found art.
    public let foundHalo: LandmarkArtPair
    /// The halo around art not found yet.
    public let notFoundHalo: LandmarkArtPair
    /// The outline colour of art not found yet.
    public let notFoundOutline: LandmarkArtPair
    /// The fill colour of art not found yet.
    public let notFoundFill: LandmarkArtPair
    /// Points per pixel for famous art on the map (3).
    public let famousScale: Double
    /// Points per pixel for generic icons on the map (3.5).
    public let genericScale: Double

    /// The art in `data` (the bundled file), or the reason it is refused.
    public init(data: Data) throws {
        guard data.count <= Self.maxFileBytes else { throw ArtError.tooLarge }
        let file: ArtFile
        do {
            file = try JSONDecoder().decode(ArtFile.self, from: data)
        } catch {
            throw ArtError.malformed
        }
        guard file.version == Self.version else { throw ArtError.unsupportedVersion(file.version) }
        guard file.famous.count + file.generic.count <= Self.maxSprites else { throw ArtError.badSprite("count") }
        let palette = try Self.palette(file.palette)
        letters = palette.letters
        colours = palette.colours
        outlineIndex = palette.outline
        famous = try Self.sprites(file.famous, letters: palette.letters)
        generic = try Self.genericSprites(file.generic, letters: palette.letters)
        foundHalo = try Self.pair(file.halo.found, "halo.found")
        notFoundHalo = try Self.pair(file.halo.notFound, "halo.notFound")
        notFoundOutline = try Self.pair(LandmarkArtFilePair(light: file.notFound.light.outline,
                                                            dark: file.notFound.dark.outline), "notFound.outline")
        notFoundFill = try Self.pair(LandmarkArtFilePair(light: file.notFound.light.fill,
                                                         dark: file.notFound.dark.fill), "notFound.fill")
        guard file.scale.famous > 0, file.scale.famous <= 16, file.scale.generic > 0,
              file.scale.generic <= 16 else { throw ArtError.malformed }
        famousScale = file.scale.famous
        genericScale = file.scale.generic
    }

    /// The sprite a landmark draws now, by its tier's drawable form (``AtlasLandmarkTier/drawable``): a drawn
    /// famous id's own art, else the generic icon, so a placeholder (one of the 24 famous landmarks still being
    /// drawn) draws its stand-in until its id moves to ``WorldLandmarks/drawnArtIDs``, even when its sprite is
    /// already in the file. Nil when the file
    /// lacks the sprite.
    public func sprite(for landmark: AtlasLandmark) -> LandmarkSprite? {
        switch landmark.tier.drawable {
        case .famous(let artID): return famous[artID]
        case .generic(let kind): return generic[kind]
        }
    }

    /// The palette's letters, colours and outline index, or the reason it is refused. Bounded by ``maxPalette``.
    private static func palette(_ raw: [String: String]) throws -> (letters: [Character], colours: [LandmarkArtColour], outline: UInt8) {
        guard raw.count <= maxPalette, !raw.isEmpty else { throw ArtError.badPalette("size") }
        var letters: [Character] = []
        var colours: [LandmarkArtColour] = []
        for key in raw.keys.sorted() {
            guard key.count == 1, let letter = key.first, letter.isASCII, letter != ".",
                  let hex = raw[key], let colour = LandmarkArtColour(hex: hex) else { throw ArtError.badPalette(key) }
            letters.append(letter)
            colours.append(colour)
        }
        guard let outline = letters.firstIndex(of: outlineLetter) else { throw ArtError.badPalette("k") }
        return (letters, colours, UInt8(outline))
    }

    /// The famous sprites, each checked. Bounded by ``maxSprites``.
    private static func sprites(_ raw: [String: LandmarkArtFileSprite], letters: [Character]) throws -> [String: LandmarkSprite] {
        var out: [String: LandmarkSprite] = [:]
        for (id, sprite) in raw {
            out[id] = try Self.sprite(sprite, id: id, letters: letters)
        }
        return out
    }

    /// The generic icons, each checked and keyed by kind. Bounded by ``maxSprites``.
    private static func genericSprites(_ raw: [String: LandmarkArtFileSprite], letters: [Character]) throws -> [AtlasLandmarkKind: LandmarkSprite] {
        var out: [AtlasLandmarkKind: LandmarkSprite] = [:]
        for (id, sprite) in raw {
            guard let kind = AtlasLandmarkKind(rawValue: id) else { throw ArtError.unknownKind(id) }
            out[kind] = try Self.sprite(sprite, id: id, letters: letters)
        }
        return out
    }

    /// One sprite as palette indices, or the reason it is refused. Bounded: at most ``maxSide`` rows of
    /// ``maxSide`` letters.
    private static func sprite(_ raw: LandmarkArtFileSprite, id: String, letters: [Character]) throws -> LandmarkSprite {
        guard raw.size.count == 2, let width = raw.size.first, let height = raw.size.last,
              (1...maxSide).contains(width), (1...maxSide).contains(height),
              raw.rows.count == height else { throw ArtError.badSprite(id) }
        var pixels: [[UInt8]] = []
        for row in raw.rows {
            let row = Array(row)
            guard row.count == width else { throw ArtError.badSprite(id) }
            var line: [UInt8] = []
            for letter in row {
                if letter == "." {
                    line.append(LandmarkSprite.clear)
                } else if let index = letters.firstIndex(of: letter) {
                    line.append(UInt8(index))
                } else {
                    throw ArtError.badSprite(id)
                }
            }
            pixels.append(line)
        }
        return LandmarkSprite(width: width, height: height, pixels: pixels, englishName: raw.en, spanishName: raw.es)
    }

    /// A light and dark pair, or the reason it is refused.
    private static func pair(_ raw: LandmarkArtFilePair, _ name: String) throws -> LandmarkArtPair {
        guard let light = LandmarkArtColour(hex: raw.light), let dark = LandmarkArtColour(hex: raw.dark) else {
            throw ArtError.badColour(name)
        }
        return LandmarkArtPair(light: light, dark: dark)
    }
}

/// The art file's top level (frozen keys; `about` and the famous sprites' `city` are read and ignored).
private nonisolated struct ArtFile: Decodable {
    /// The format version.
    let version: Int
    /// Palette letter to `#RRGGBB`.
    let palette: [String: String]
    /// The two halos.
    let halo: LandmarkArtFileHalo
    /// The not-found greys.
    let notFound: LandmarkArtFileNotFound
    /// The draw scales.
    let scale: LandmarkArtFileScale
    /// Famous sprites by art id.
    let famous: [String: LandmarkArtFileSprite]
    /// Generic icons by kind.
    let generic: [String: LandmarkArtFileSprite]
}

/// A sprite as the file spells it.
private nonisolated struct LandmarkArtFileSprite: Decodable {
    /// The English name.
    let en: String
    /// The Spanish name.
    let es: String
    /// `[width, height]`.
    let size: [Int]
    /// The rows of palette letters.
    let rows: [String]
}

/// A light and dark colour as the file spells them.
private nonisolated struct LandmarkArtFilePair: Decodable {
    /// The light-mode `#RRGGBB`.
    let light: String
    /// The dark-mode `#RRGGBB`.
    let dark: String
}

/// The file's two halos.
private nonisolated struct LandmarkArtFileHalo: Decodable {
    /// Around found art.
    let found: LandmarkArtFilePair
    /// Around art not found yet.
    let notFound: LandmarkArtFilePair
}

/// One mode's not-found greys.
private nonisolated struct LandmarkArtFileGreys: Decodable {
    /// The outline letter's colour.
    let outline: String
    /// Every other drawn pixel's colour.
    let fill: String
}

/// The file's not-found greys for both modes (its `note` is read and ignored).
private nonisolated struct LandmarkArtFileNotFound: Decodable {
    /// Light mode.
    let light: LandmarkArtFileGreys
    /// Dark mode.
    let dark: LandmarkArtFileGreys
}

/// The file's draw scales.
private nonisolated struct LandmarkArtFileScale: Decodable {
    /// Points per pixel for famous art.
    let famous: Double
    /// Points per pixel for generic icons.
    let generic: Double
}
