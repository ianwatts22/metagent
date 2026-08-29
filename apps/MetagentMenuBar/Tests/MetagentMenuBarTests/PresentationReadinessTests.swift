import Foundation
import Testing
@testable import MetagentMenuBar

@Test func presentationReadyIdentifierIsDeterministicAndPrivacySafe() {
    let identifier = presentationReadyIdentifier(
        section: "skills",
        state: ["summary", "/private/secret/project", "confidential query"],
        orderedRowIDs: ["/private/secret/project/a", "/private/secret/project/b"]
    )

    #expect(identifier == presentationReadyIdentifier(
        section: "skills",
        state: ["summary", "/private/secret/project", "confidential query"],
        orderedRowIDs: ["/private/secret/project/a", "/private/secret/project/b"]
    ))
    #expect(identifier == "metagent.skills.content.ready.b3ff5a5d0a1c21ad")
    #expect(identifier.hasPrefix("metagent.skills.content.ready."))
    #expect(identifier.count == "metagent.skills.content.ready.".count + 16)
    #expect(!identifier.contains("secret"))
    #expect(!identifier.contains("confidential"))
}

@Test func presentationReadyIdentifierChangesWithStateAndPresentedOrder() {
    let original = presentationReadyIdentifier(
        section: "projects",
        state: ["all", "0"],
        orderedRowIDs: ["alpha", "beta"]
    )
    let filtered = presentationReadyIdentifier(
        section: "projects",
        state: ["attention", "0"],
        orderedRowIDs: ["alpha", "beta"]
    )
    let sorted = presentationReadyIdentifier(
        section: "projects",
        state: ["all", "0"],
        orderedRowIDs: ["beta", "alpha"]
    )

    #expect(filtered != original)
    #expect(sorted != original)
}

@Test func presentationReadyIdentifierSeparatesComponentBoundaries() {
    let first = presentationReadyIdentifier(
        section: "mcps",
        state: ["ab", "c"],
        orderedRowIDs: []
    )
    let second = presentationReadyIdentifier(
        section: "mcps",
        state: ["a", "bc"],
        orderedRowIDs: []
    )

    #expect(first != second)
    #expect(!"metagent.skills.content.loading".hasPrefix("metagent.skills.content.ready."))
}

@Test func presentationReadyIdentifierDistinguishesActualSortDescriptorsWithTiedRows() {
    let forward = [KeyPathComparator(\ReadinessFixture.name)]
    let reverse = [KeyPathComparator(\ReadinessFixture.name, order: .reverse)]
    let tiedRowIDs = ["same-value-a", "same-value-b"]

    let forwardIdentifier = presentationReadyIdentifier(
        section: "plugins",
        state: [sortPresentationState(forward)],
        orderedRowIDs: tiedRowIDs
    )
    let reverseIdentifier = presentationReadyIdentifier(
        section: "plugins",
        state: [sortPresentationState(reverse)],
        orderedRowIDs: tiedRowIDs
    )

    #expect(sortPresentationState(forward) == "\\ReadinessFixture.name:forward")
    #expect(sortPresentationState(reverse) == "\\ReadinessFixture.name:reverse")
    #expect(forwardIdentifier != reverseIdentifier)
}

private struct ReadinessFixture {
    let name: String
}
