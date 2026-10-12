import Testing
@testable import ZapFastShell

struct ResizeScenarioTests {
    @Test func defaultAndInvalidInputsKeepTheOriginalShortDrag() {
        for value in [nil, "", "bad", "0", "-1"] as [String?] {
            #expect(ResizeScenario(requestedRounds: value).rounds == 1)
        }
        #expect(ResizeScenario.steps * ResizeScenario.pointsPerStep == 80)
    }

    @Test func repeatedRoundsIncreaseSamplesWithinTheSameWidthRange() {
        let scenario = ResizeScenario(requestedRounds: "4")
        #expect(scenario.rounds * ResizeScenario.steps == 40)
        #expect(ResizeScenario(requestedRounds: "10000").rounds == 10)
        let short = BenchmarkReport.Distribution((1...10).map(Double.init))
        #expect(short.p95 == short.max)
        let repeated = BenchmarkReport.Distribution((1...40).map(Double.init))
        #expect(repeated.p95 == 38 && repeated.max == 40)
    }
}
