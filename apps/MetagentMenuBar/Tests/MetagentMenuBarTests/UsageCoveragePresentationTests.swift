import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

@Test func usageCoverageHelpKeepsNearCompleteProgressProvisional() {
    let expectedProgress = 0.997.formatted(.percent.precision(.fractionLength(1)))
    let completedProgress = 1.0.formatted(.percent.precision(.fractionLength(0)))
    for coverage in [SkillUsageCoverage.partial(progress: 0.997), .updating(progress: 0.997)] {
        let help = overviewUsageCoverageCaveat(coverage)
        #expect(help.contains(expectedProgress))
        #expect(help.contains("provisional"))
        #expect(!help.contains("\(completedProgress) complete"))
    }
}

@Test func usageCoverageHelpNeverRoundsIncompleteWorkToComplete() {
    let expectedProgress = 0.999.formatted(.percent.precision(.fractionLength(1)))
    for progress in [0.9999, 1.0, 1.5] {
        #expect(overviewUsageCoverageCaveat(.partial(progress: progress)).contains(expectedProgress))
        #expect(overviewUsageCoverageCaveat(.updating(progress: progress)).contains(expectedProgress))
    }
}

@Test func usageCoverageHelpPreservesCompleteAndUnavailableMeanings() {
    #expect(overviewUsageCoverageCaveat(.complete) == "Retained session history is fully indexed.")
    #expect(overviewUsageCoverageCaveat(.unavailable).contains("absence of observed reads is not evidence"))
    #expect(!overviewUsageCoverageCaveat(.complete).contains("provisional"))
}

@Test func incompleteUsageProgressLabelsStayWithinTheirDisplayBounds() {
    #expect(incompleteUsageProgressLabel(-0.2) == 0.0.formatted(.percent.precision(.fractionLength(1))))
    #expect(incompleteUsageProgressLabel(0.25) == 0.25.formatted(.percent.precision(.fractionLength(1))))
    #expect(incompleteUsageProgressLabel(0.9999) == 0.999.formatted(.percent.precision(.fractionLength(1))))
}
