import Foundation

/// Command-format baselines, not certification of every OS/architecture pairing.
enum SourceToolVersion {
    static func validated(_ output: String, source: UpdateSource) throws -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw UpdaterError("\(source.toolName) did not report a version.") }
        let pattern: String
        let minimum: String
        let requirement: String
        let candidate: String
        switch source {
        case .homebrew:
            pattern = #"\AHomebrew ([0-9]+\.[0-9]+\.[0-9]+)\z"#
            candidate = String(text.split(whereSeparator: \.isNewline).first ?? "")
            minimum = "6.0.0"
            requirement = "Homebrew 6 or later is required for scoped cask updates with --no-quit."
        case .macPorts:
            pattern = #"\AVersion: ([0-9]+\.[0-9]+\.[0-9]+)\z"#
            candidate = text
            minimum = "2.8.1"
            requirement = "MacPorts 2.8.1 or later is required for this source's command-format baseline."
        case .appStore:
            pattern = #"\A([0-9]+\.[0-9]+\.[0-9]+)\z"#
            candidate = text
            minimum = "7.0.0"
            requirement = "mas 7 or later is required for identity-based matching."
        }
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
              let range = Range(match.range(at: 1), in: candidate) else {
            throw UpdaterError("\(source.toolName) returned an unrecognized version. Choose Prepare Sources or update the tool manually. Diagnostic: " + Diagnostics.redact(text).prefixString(3500))
        }
        let version = String(candidate[range])
        guard let comparison = ReleaseComparison.compare(version, minimum), comparison != .orderedAscending else {
            throw UpdaterError(requirement + " The installed tool reported: " + version)
        }
        return version
    }
}
