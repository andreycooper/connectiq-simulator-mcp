import Foundation
import Security

/// Immutable Security.framework output used as an injectable fixture seam.
/// CF objects never cross the Sendable boundary.
public struct SignatureMetadata: Equatable, Sendable {
    public let signed: Bool
    public let adHoc: Bool
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let cdhash: Data?
    public let designatedRequirement: String?

    public init(
        signed: Bool, adHoc: Bool, signingIdentifier: String? = nil,
        teamIdentifier: String? = nil, cdhash: Data? = nil,
        designatedRequirement: String? = nil
    ) {
        self.signed = signed
        self.adHoc = adHoc
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.cdhash = cdhash
        self.designatedRequirement = designatedRequirement
    }
}

public struct SignatureReport: Equatable, Sendable {
    public let executablePath: String
    public let kind: SignatureKind
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let cdhash: String?
    public let designatedRequirement: String?

    public init(
        executablePath: String, kind: SignatureKind, signingIdentifier: String?,
        teamIdentifier: String?, cdhash: String?, designatedRequirement: String?
    ) {
        self.executablePath = executablePath
        self.kind = kind
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.cdhash = cdhash
        self.designatedRequirement = designatedRequirement
    }
}

public struct SignatureInspector: Sendable {
    // Security/CSCommon.h declares kSecCodeSignatureAdhoc = 0x0002, but the
    // SDK does not import that C enum case into Swift.
    private static let adHocSignatureFlag: UInt32 = 0x0002
    private let metadata: @Sendable (URL) -> SignatureMetadata

    public init() {
        self.metadata = Self.loadSecurityMetadata
    }

    public init(_ metadata: @escaping @Sendable (URL) -> SignatureMetadata) {
        self.metadata = metadata
    }

    public func inspect(executableURL: URL) -> SignatureReport {
        let canonical = executableURL.resolvingSymlinksInPath().standardizedFileURL
        let value = metadata(canonical)
        let kind: SignatureKind
        if !value.signed {
            kind = .unsigned
        } else if value.adHoc || value.designatedRequirement?.isEmpty != false {
            // A signature without a designated requirement cannot provide the
            // stable identity required by TCC, even if Security returned data.
            kind = .adHoc
        } else {
            kind = .stable
        }
        return SignatureReport(
            executablePath: canonical.path, kind: kind,
            signingIdentifier: value.signingIdentifier,
            teamIdentifier: value.teamIdentifier,
            cdhash: value.cdhash.map(Self.hex),
            designatedRequirement: value.designatedRequirement)
    }

    public static func currentExecutableURL() -> URL {
        if let bundled = Bundle.main.executableURL {
            return bundled.resolvingSymlinksInPath().standardizedFileURL
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().standardizedFileURL
    }

    private static func loadSecurityMetadata(_ executableURL: URL) -> SignatureMetadata {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL, SecCSFlags(), &code)
        guard createStatus == errSecSuccess, let code else {
            return SignatureMetadata(signed: false, adHoc: false)
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard infoStatus == errSecSuccess, let dictionary = information as NSDictionary? else {
            return SignatureMetadata(signed: false, adHoc: false)
        }

        let flags = (dictionary[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
        let adHoc = flags & Self.adHocSignatureFlag != 0
        let identifier = dictionary[kSecCodeInfoIdentifier] as? String
        let team = dictionary[kSecCodeInfoTeamIdentifier] as? String
        let cdhash = dictionary[kSecCodeInfoUnique] as? Data

        var requirement: SecRequirement?
        var requirementText: String?
        if SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess,
            let requirement
        {
            var text: CFString?
            if SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess {
                requirementText = text as String?
            }
        }

        return SignatureMetadata(
            signed: true, adHoc: adHoc, signingIdentifier: identifier,
            teamIdentifier: team, cdhash: cdhash,
            designatedRequirement: requirementText)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
