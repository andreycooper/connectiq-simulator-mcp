/// A numeric `major.minor.patch` version. Comparison is numeric per
/// component (9.10.0 > 9.2.0, 10.0.0 > 9.10.0) — never lexicographic,
/// which is exactly the mistake the plan's SDK-sorting tests guard
/// against. Encodes as the plain version string.
public struct SemVer: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses an exact `major.minor.patch` string; anything else is `nil`.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let major = Int(parts[0]),
            let minor = Int(parts[1]),
            let patch = Int(parts[2]),
            major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// Extracts the first `major.minor.patch` triple embedded in a longer
    /// name, e.g. `connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b` → 9.1.0
    /// (the real installed SDK directory naming on this machine).
    public init?(firstIn name: String) {
        guard let match = name.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
            let major = Int(match.1),
            let minor = Int(match.2),
            let patch = Int(match.3)
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension SemVer: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let version = SemVer(string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "'\(string)' is not a major.minor.patch version"
            )
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
