import Security
import XCTest
@testable import MetagentCLI

final class NotionProofSigningTests: XCTestCase {
    func testRejectsUnstableExecutableBeforeProofRuns() {
        var interactionTouched = false
        XCTAssertThrowsError(try NotionProofSigning.prepareForProof(
            isValid: { false },
            disableUserInteraction: { interactionTouched = true; return errSecSuccess }
        )) { error in
            XCTAssertEqual(error.localizedDescription, NotionProofSigning.requiredMessage)
        }
        XCTAssertFalse(interactionTouched)
    }

    func testAcceptsValidatedExecutable() throws {
        var order: [String] = []
        try NotionProofSigning.prepareForProof(
            isValid: { order.append("signature"); return true },
            disableUserInteraction: { order.append("no-dialog"); return errSecSuccess }
        )
        XCTAssertEqual(order, ["signature", "no-dialog"])
    }

    func testStopsIfKeychainPromptsCannotBeDisabled() {
        XCTAssertThrowsError(try NotionProofSigning.prepareForProof(
            isValid: { true },
            disableUserInteraction: { errSecInteractionNotAllowed }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("stopped before credential access"))
        }
    }

    func testFailurePointsToInstalledSignedDevHelper() {
        XCTAssertTrue(NotionProofSigning.requiredMessage.contains("~/Applications/Metagent Dev.app/Contents/Helpers/metagent"))
        XCTAssertTrue(NotionProofSigning.requiredMessage.contains("scripts/install-app.sh"))
    }
}
