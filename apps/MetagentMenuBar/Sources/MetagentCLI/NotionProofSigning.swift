import Foundation
import Security

/// Saved Notion credentials must be accessed through a stable, signed helper.
/// SwiftPM's ad-hoc executable must never try to read or replace that item.
enum NotionProofSigning {
    static let requiredMessage = "Notion proof requires an Apple-anchored signed metagent helper. Run ~/Applications/Metagent Dev.app/Contents/Helpers/metagent (install it with scripts/install-app.sh). Do not use swift run or .build/debug/metagent."

    static func prepareForProof(
        isValid: () -> Bool = isCurrentExecutableValid,
        disableUserInteraction: () -> OSStatus = { SecKeychainSetUserInteractionAllowed(false) }
    ) throws {
        guard isValid() else { throw SigningError.unstableExecutable }
        // This CLI command owns its process until exit. Keep legacy Keychain
        // interaction disabled for the whole command, including token refresh.
        let status = disableUserInteraction()
        guard status == errSecSuccess else { throw SigningError.cannotDisableKeychainInteraction(status) }
    }

    private static func isCurrentExecutableValid() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }

        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"metagent\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }

        // This validates the running code and its on-disk signature, not just
        // a path string, certificate name, or unverified signing metadata.
        return SecCodeCheckValidityWithErrors(code, [], requirement, nil) == errSecSuccess
    }

    enum SigningError: LocalizedError {
        case unstableExecutable
        case cannotDisableKeychainInteraction(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unstableExecutable:
                requiredMessage
            case .cannotDisableKeychainInteraction(let status):
                "Notion proof stopped before credential access: macOS could not disable Keychain prompts (OSStatus \(status))."
            }
        }
    }
}
