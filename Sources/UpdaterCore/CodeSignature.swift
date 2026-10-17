import Foundation
import Security

/// Transient evidence captured at review. Each validation opens a fresh code
/// object so a previous successful validation cannot hide a changed bundle.
enum CodeSignatureEvidence {
    case unsigned
    case adHoc(identifier: String)
    case signed(requirement: SecRequirement, identifier: String, team: String?)
    case invalid

    private static let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

    private static func code(at path: String) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
    private static func information(_ code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
    static func capture(at path: String) -> CodeSignatureEvidence {
        guard let code = code(at: path) else { return .invalid }
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        if status == errSecCSUnsigned { return hasSignatureResources(at: path) ? .invalid : .unsigned }
        guard status == errSecSuccess, let info = information(code),
              let identifier = info[kSecCodeInfoIdentifier as String] as? String else { return .invalid }
        let signingFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if signingFlags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adHoc(identifier: identifier) }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { return .invalid }
        return .signed(requirement: requirement, identifier: identifier, team: info[kSecCodeInfoTeamIdentifier as String] as? String)
    }
    func validate(at path: String) throws {
        guard let code = Self.code(at: path) else { throw Self.failure }
        switch self {
        case .invalid:
            throw Self.failure
        case .unsigned:
            // Unsigned applications carry no publisher guarantee. A newly signed
            // replacement must nevertheless have a valid signature.
            let status = SecStaticCodeCheckValidity(code, Self.flags, nil)
            guard status == errSecSuccess || (status == errSecCSUnsigned && !Self.hasSignatureResources(at: path)) else { throw Self.failure }
        case .adHoc(let identifier):
            // Ad-hoc signatures establish integrity, not a certified publisher.
            // Their cdhash changes on every release; preserve the signing ID.
            guard SecStaticCodeCheckValidity(code, Self.flags, nil) == errSecSuccess,
                  Self.information(code)?[kSecCodeInfoIdentifier as String] as? String == identifier else { throw Self.failure }
        case .signed(let requirement, let identifier, let team):
            guard SecStaticCodeCheckValidity(code, Self.flags, requirement) == errSecSuccess,
                  let info = Self.information(code),
                  info[kSecCodeInfoIdentifier as String] as? String == identifier,
                  info[kSecCodeInfoTeamIdentifier as String] as? String == team else { throw Self.failure }
        }
    }
    private static func hasSignatureResources(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("Contents/_CodeSignature").path)
    }
    var reviewSummary: String {
        switch self {
        case .unsigned: return "Unsigned application: publisher identity cannot be verified."
        case .adHoc: return "Signature integrity verified; publisher identity is not certified."
        case .signed: return "Signature verified. The update must preserve the reviewed signing identity."
        case .invalid: return "The code signature could not be verified."
        }
    }
    private static var failure: UpdaterError {
        UpdaterError("The application's code signature is invalid or its reviewed signing identity changed. Rescan and review the application before retrying. No cleanup was performed.")
    }
}

/// Only a currently valid certificate-signed bundle establishes a publisher team.
public enum InstalledPublisherIdentity {
    public static func teamIdentifier(at path: String) -> String? {
        guard case .signed(_, _, let team) = CodeSignatureEvidence.capture(at: path), let team else { return nil }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, let requirement, SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return nil }
        return team
    }
}

public enum DeveloperIDValidation {
    public static func validate(path: String, bundleID: String, team: String) throws {
        guard bundleID.range(of: #"\A[A-Za-z0-9.-]{1,255}\z"#, options: .regularExpression) != nil,
              team.range(of: #"\A[A-Z0-9]{10}\z"#, options: .regularExpression) != nil else { throw UpdaterError("Invalid pinned publisher identity.") }
        let text = "identifier \"" + bundleID + "\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"" + team + "\""
        var requirement: SecRequirement?
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw UpdaterError("The pinned Developer ID requirement could not be created.")
        }
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, let requirement, SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdaterError("The application does not satisfy the pinned Developer ID publisher and bundle requirement.")
        }
    }
}
