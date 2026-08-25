import Foundation

/// Encodings MarkLook can detect without performing a lossy conversion.
enum DocumentTextEncoding: String, CaseIterable, Codable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case shiftJIS
    case eucJP

    var localizedName: String {
        switch self {
        case .utf8:
            "UTF-8"
        case .utf16LittleEndian:
            "UTF-16 LE"
        case .utf16BigEndian:
            "UTF-16 BE"
        case .shiftJIS:
            "Shift_JIS"
        case .eucJP:
            "EUC-JP"
        }
    }
}

struct DecodedDocument: Equatable, Sendable {
    enum DetectionSource: Equatable, Sendable {
        case byteOrderMark
        case htmlMetaCharset
        case strictUTF8
    }

    let text: String
    let encoding: DocumentTextEncoding
    let source: DetectionSource
}

enum CharacterDecodingError: Error, Equatable, Sendable {
    case unsupportedDeclaredEncoding(String)
    case malformedData(DocumentTextEncoding)
    case undecodable
    case likelyBinary
}

extension CharacterDecodingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedDeclaredEncoding(name):
            "The document declares an unsupported character encoding: \(name)."
        case let .malformedData(encoding):
            "The document contains invalid \(encoding.localizedName) byte sequences."
        case .undecodable:
            "The document character encoding could not be detected."
        case .likelyBinary:
            "The file appears to contain binary data and cannot be displayed as text."
        }
    }
}

/// Performs deterministic, non-lossy decoding in the order required by the document format.
struct CharacterDecoder: Sendable {
    func decode(
        _ data: Data,
        allowsHTMLMetaCharset: Bool = true
    ) throws -> DecodedDocument {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return try decodedDocument(
                Data(data.dropFirst(3)),
                as: .utf8,
                source: .byteOrderMark
            )
        }

        if data.starts(with: [0xFF, 0xFE]) {
            return try decodedDocument(
                Data(data.dropFirst(2)),
                as: .utf16LittleEndian,
                source: .byteOrderMark
            )
        }

        if data.starts(with: [0xFE, 0xFF]) {
            return try decodedDocument(
                Data(data.dropFirst(2)),
                as: .utf16BigEndian,
                source: .byteOrderMark
            )
        }

        if allowsHTMLMetaCharset, let declaredName = declaredHTMLCharset(in: data) {
            guard let encoding = encoding(forCharsetName: declaredName) else {
                throw CharacterDecodingError.unsupportedDeclaredEncoding(declaredName)
            }
            return try decodedDocument(data, as: encoding, source: .htmlMetaCharset)
        }

        if let text = String(data: data, encoding: .utf8) {
            try validateTextIsNotBinary(text)
            return DecodedDocument(text: text, encoding: .utf8, source: .strictUTF8)
        }

        throw CharacterDecodingError.undecodable
    }

    private func decodedDocument(
        _ data: Data,
        as encoding: DocumentTextEncoding,
        source: DecodedDocument.DetectionSource
    ) throws -> DecodedDocument {
        let text: String

        switch encoding {
        case .utf8:
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw CharacterDecodingError.malformedData(encoding)
            }
            text = decoded

        case .utf16LittleEndian:
            text = try decodeUTF16(data, littleEndian: true, encoding: encoding)

        case .utf16BigEndian:
            text = try decodeUTF16(data, littleEndian: false, encoding: encoding)

        case .shiftJIS:
            guard let decoded = String(data: data, encoding: .shiftJIS) else {
                throw CharacterDecodingError.malformedData(encoding)
            }
            text = decoded

        case .eucJP:
            guard let decoded = String(data: data, encoding: .japaneseEUC) else {
                throw CharacterDecodingError.malformedData(encoding)
            }
            text = decoded
        }

        try validateTextIsNotBinary(text)
        return DecodedDocument(text: text, encoding: encoding, source: source)
    }

    /// Validating code units first prevents `String(decoding:as:)` from silently repairing a
    /// truncated code unit or an unpaired surrogate.
    private func decodeUTF16(
        _ data: Data,
        littleEndian: Bool,
        encoding: DocumentTextEncoding
    ) throws -> String {
        let bytes = [UInt8](data)
        guard bytes.count.isMultiple(of: 2) else {
            throw CharacterDecodingError.malformedData(encoding)
        }

        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(bytes.count / 2)

        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let first = UInt16(bytes[offset])
            let second = UInt16(bytes[offset + 1])
            let codeUnit = littleEndian
                ? first | (second << 8)
                : (first << 8) | second
            codeUnits.append(codeUnit)
        }

        var index = codeUnits.startIndex
        while index < codeUnits.endIndex {
            let codeUnit = codeUnits[index]

            if (0xD800...0xDBFF).contains(codeUnit) {
                let nextIndex = codeUnits.index(after: index)
                guard nextIndex < codeUnits.endIndex,
                      (0xDC00...0xDFFF).contains(codeUnits[nextIndex]) else {
                    throw CharacterDecodingError.malformedData(encoding)
                }
                index = codeUnits.index(after: nextIndex)
            } else if (0xDC00...0xDFFF).contains(codeUnit) {
                throw CharacterDecodingError.malformedData(encoding)
            } else {
                index = codeUnits.index(after: index)
            }
        }

        return String(decoding: codeUnits, as: UTF16.self)
    }

    private func validateTextIsNotBinary(_ text: String) throws {
        guard !text.isEmpty else { return }

        var scalarCount = 0
        var nulCount = 0
        var suspiciousControlCount = 0

        for scalar in text.unicodeScalars {
            scalarCount += 1
            switch scalar.value {
            case 0:
                nulCount += 1
            case 0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F:
                suspiciousControlCount += 1
            default:
                break
            }
        }

        // A single NUL can be accidental. Repeated NULs, or a meaningful density of control
        // characters, are much stronger binary-file signals.
        if nulCount > max(1, scalarCount / 100)
            || (suspiciousControlCount >= 8 && suspiciousControlCount * 10 >= scalarCount) {
            throw CharacterDecodingError.likelyBinary
        }
    }

    private func declaredHTMLCharset(in data: Data) -> String? {
        // HTML's encoding declaration is required near the beginning of the file. ISO Latin-1
        // gives a one-to-one byte mapping here; it does not decode the document body.
        let sniffLength = min(data.count, 8_192)
        guard sniffLength > 0,
              var prefix = String(data: data.prefix(sniffLength), encoding: .isoLatin1) else {
            return nil
        }

        if let commentExpression = try? NSRegularExpression(
            pattern: #"<!--.*?-->"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
            prefix = commentExpression.stringByReplacingMatches(
                in: prefix,
                range: range,
                withTemplate: ""
            )
        }

        guard let expression = try? NSRegularExpression(
            pattern: #"<meta\b[^>]*\bcharset\s*=\s*[\"']?\s*([A-Za-z0-9._:-]+)"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let searchRange = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        guard let match = expression.firstMatch(in: prefix, range: searchRange),
              match.numberOfRanges > 1,
              let charsetRange = Range(match.range(at: 1), in: prefix) else {
            return nil
        }

        return String(prefix[charsetRange])
    }

    private func encoding(forCharsetName name: String) -> DocumentTextEncoding? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            .utf8
        case "utf-16le", "utf16le":
            .utf16LittleEndian
        case "utf-16be", "utf16be":
            .utf16BigEndian
        case "shift_jis", "shift-jis", "shiftjis", "sjis", "ms_kanji", "csshiftjis",
             "windows-31j", "cp932", "ms932":
            .shiftJIS
        case "euc-jp", "euc_jp", "eucjp", "cseucpkdfmtjapanese":
            .eucJP
        default:
            nil
        }
    }
}
