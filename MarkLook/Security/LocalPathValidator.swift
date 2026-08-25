import Darwin
import Foundation

/// A permission boundary previously granted by the user and restored from a security-scoped
/// bookmark. A file scope grants only that file; a folder scope grants its descendants.
enum LocalResourceScope: Hashable, Sendable {
    case file(URL)
    case folder(URL)
}

enum LocalPathValidationError: Error, Equatable, Sendable {
    case emptyPath
    case malformedPercentEncoding
    case embeddedNUL
    case unsupportedScheme(String)
    case remoteFileHost(String)
    case invalidBaseDirectory(URL)
    case noAllowedScopes
    case invalidAllowedScope(URL)
    case targetDoesNotExist
    case targetIsNotRegularFile
    case outsideAllowedScopes
}

extension LocalPathValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyPath:
            "The local resource path is empty."
        case .malformedPercentEncoding:
            "The local resource path contains malformed percent encoding."
        case .embeddedNUL:
            "The local resource path contains an invalid NUL character."
        case let .unsupportedScheme(scheme):
            "The URL scheme “\(scheme)” is not permitted for a local resource."
        case let .remoteFileHost(host):
            "The remote file host “\(host)” is not permitted."
        case .invalidBaseDirectory:
            "The document's base folder is unavailable."
        case .noAllowedScopes:
            "No local file or folder access has been granted."
        case .invalidAllowedScope:
            "A granted local file or folder is no longer available."
        case .targetDoesNotExist:
            "The requested local resource does not exist."
        case .targetIsNotRegularFile:
            "The requested local resource is not a regular file."
        case .outsideAllowedScopes:
            "The requested local resource is outside the granted file and folder access."
        }
    }
}

/// Resolves a local resource to a canonical existing path, then proves that the result is inside
/// an explicit permission boundary. Callers should open only the returned URL.
struct LocalPathValidator: Sendable {
    func validate(
        requestPath: String,
        relativeTo baseDirectory: URL,
        allowedScopes: [LocalResourceScope],
        requireRegularFile: Bool = true
    ) throws -> URL {
        guard !requestPath.isEmpty else {
            throw LocalPathValidationError.emptyPath
        }
        try validatePercentTriplets(in: requestPath)
        guard baseDirectory.isFileURL else {
            throw LocalPathValidationError.invalidBaseDirectory(baseDirectory)
        }

        let components: URLComponents
        guard let parsedComponents = URLComponents(string: requestPath) else {
            throw LocalPathValidationError.malformedPercentEncoding
        }
        components = parsedComponents

        if let scheme = components.scheme?.lowercased(), scheme != "file" {
            throw LocalPathValidationError.unsupportedScheme(scheme)
        }

        if let host = components.host, !host.isEmpty, host.lowercased() != "localhost" {
            throw LocalPathValidationError.remoteFileHost(host)
        }

        let decodedPath = try strictlyPercentDecoded(components.percentEncodedPath)
        guard !decodedPath.isEmpty else {
            throw LocalPathValidationError.emptyPath
        }
        guard !decodedPath.contains("\0") else {
            throw LocalPathValidationError.embeddedNUL
        }

        let basePath = baseDirectory.path
        var isBaseDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: basePath, isDirectory: &isBaseDirectory),
              isBaseDirectory.boolValue else {
            throw LocalPathValidationError.invalidBaseDirectory(baseDirectory)
        }

        // Build the path textually so `realpath(3)` sees symlinks and `..` in their original
        // order. Lexically removing `..` before resolving a preceding symlink is unsafe.
        let unresolvedPath: String
        if decodedPath.hasPrefix("/") {
            unresolvedPath = decodedPath
        } else if basePath == "/" {
            unresolvedPath = "/" + decodedPath
        } else {
            unresolvedPath = basePath + "/" + decodedPath
        }

        return try validate(
            unresolvedFilePath: unresolvedPath,
            allowedScopes: allowedScopes,
            requireRegularFile: requireRegularFile
        )
    }

    func validate(
        fileURL: URL,
        allowedScopes: [LocalResourceScope],
        requireRegularFile: Bool = true
    ) throws -> URL {
        guard fileURL.isFileURL else {
            throw LocalPathValidationError.unsupportedScheme(fileURL.scheme ?? "")
        }
        guard fileURL.host == nil || fileURL.host?.isEmpty == true
                || fileURL.host?.lowercased() == "localhost" else {
            throw LocalPathValidationError.remoteFileHost(fileURL.host ?? "")
        }
        guard !fileURL.path.contains("\0") else {
            throw LocalPathValidationError.embeddedNUL
        }

        return try validate(
            unresolvedFilePath: fileURL.path,
            allowedScopes: allowedScopes,
            requireRegularFile: requireRegularFile
        )
    }

    private func validate(
        unresolvedFilePath: String,
        allowedScopes: [LocalResourceScope],
        requireRegularFile: Bool
    ) throws -> URL {
        guard !allowedScopes.isEmpty else {
            throw LocalPathValidationError.noAllowedScopes
        }

        let targetURL = try canonicalExistingURL(
            forPath: unresolvedFilePath,
            missingError: .targetDoesNotExist
        )

        if requireRegularFile {
            let values = try? targetURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                throw LocalPathValidationError.targetIsNotRegularFile
            }
        }

        var sawUsableScope = false
        var firstInvalidScope: URL?

        for scope in allowedScopes {
            switch scope {
            case let .file(scopeURL):
                guard scopeURL.isFileURL,
                      let canonicalScope = try? canonicalExistingURL(
                          forPath: scopeURL.path,
                          missingError: .invalidAllowedScope(scopeURL)
                      ) else {
                    firstInvalidScope = firstInvalidScope ?? scopeURL
                    continue
                }

                sawUsableScope = true
                if filesReferToSameItem(targetURL, canonicalScope) {
                    return targetURL
                }

            case let .folder(scopeURL):
                guard scopeURL.isFileURL,
                      let canonicalScope = try? canonicalExistingURL(
                          forPath: scopeURL.path,
                          missingError: .invalidAllowedScope(scopeURL)
                      ) else {
                    firstInvalidScope = firstInvalidScope ?? scopeURL
                    continue
                }

                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: canonicalScope.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    firstInvalidScope = firstInvalidScope ?? scopeURL
                    continue
                }

                sawUsableScope = true
                var relationship: FileManager.URLRelationship = .other
                do {
                    try FileManager.default.getRelationship(
                        &relationship,
                        ofDirectoryAt: canonicalScope,
                        toItemAt: targetURL
                    )
                } catch {
                    firstInvalidScope = firstInvalidScope ?? scopeURL
                    continue
                }

                if relationship == .same || relationship == .contains {
                    return targetURL
                }
            }
        }

        if !sawUsableScope, let firstInvalidScope {
            throw LocalPathValidationError.invalidAllowedScope(firstInvalidScope)
        }
        throw LocalPathValidationError.outsideAllowedScopes
    }

    private func canonicalExistingURL(
        forPath path: String,
        missingError: LocalPathValidationError
    ) throws -> URL {
        guard !path.isEmpty else {
            throw LocalPathValidationError.emptyPath
        }

        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.withCString({ realpath($0, &resolvedPath) }) != nil else {
            throw missingError
        }

        let terminatorIndex = resolvedPath.firstIndex(of: 0) ?? resolvedPath.endIndex
        let pathBytes = resolvedPath[..<terminatorIndex].map(UInt8.init(bitPattern:))
        let path = String(decoding: pathBytes, as: UTF8.self)
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func filesReferToSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.path == rhs.path {
            return true
        }

        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let lhsIdentifier = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let rhsIdentifier = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let lhsHashable = lhsIdentifier as? AnyHashable,
              let rhsHashable = rhsIdentifier as? AnyHashable else {
            return false
        }
        return lhsHashable == rhsHashable
    }

    private func strictlyPercentDecoded(_ encodedPath: String) throws -> String {
        try validatePercentTriplets(in: encodedPath)

        guard let decoded = encodedPath.removingPercentEncoding else {
            throw LocalPathValidationError.malformedPercentEncoding
        }
        return decoded
    }

    private func validatePercentTriplets(in value: String) throws {
        let scalars = Array(value.unicodeScalars)
        var index = scalars.startIndex

        while index < scalars.endIndex {
            if scalars[index] == "%" {
                let firstHexIndex = scalars.index(after: index)
                guard firstHexIndex < scalars.endIndex else {
                    throw LocalPathValidationError.malformedPercentEncoding
                }
                let secondHexIndex = scalars.index(after: firstHexIndex)
                guard secondHexIndex < scalars.endIndex,
                      scalars[firstHexIndex].isASCIIHexDigit,
                      scalars[secondHexIndex].isASCIIHexDigit else {
                    throw LocalPathValidationError.malformedPercentEncoding
                }
                index = scalars.index(after: secondHexIndex)
            } else {
                index = scalars.index(after: index)
            }
        }
    }
}

private extension Unicode.Scalar {
    var isASCIIHexDigit: Bool {
        switch value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66:
            true
        default:
            false
        }
    }
}
