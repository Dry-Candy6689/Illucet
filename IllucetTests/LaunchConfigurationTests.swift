import Testing
@testable import Illucet

struct LaunchConfigurationTests {
    @Test(arguments: [
        (["Illucet"], false),
        (["Illucet", "--stage0-live"], false),
        (["Illucet", "--stage0-autorun"], true),
        (["Illucet", "--stage0-autorun=false"], false),
    ])
    func harnessRoutingRespectsBuildConfiguration(arguments: [String], enabledInDebug: Bool) {
        #if DEBUG
        let expected = enabledInDebug
        #else
        let expected = false
        #endif
        #expect(IllucetLaunchRouting.usesStage0Harness(arguments: arguments) == expected)
    }

    @Test(arguments: [
        (["Illucet"], nil, false),
        (["Illucet"], false, false),
        (["Illucet"], true, true),
        (["Illucet", "--ui-testing"], nil, true),
        (["Illucet", "--ui-testing"], false, false),
        (["Illucet", "--ui-testing"], true, true),
        (["Illucet", "--ui-testing=false"], nil, false),
        (["Illucet", "--ui-testing=false"], false, false),
        (["Illucet", "--ui-testing=false"], true, true),
    ] as [([String], Bool?, Bool)])
    func fixtureRoutingRespectsBuildConfiguration(
        arguments: [String], override: Bool?, enabledInDebug: Bool
    ) {
        #if DEBUG
        let expected = enabledInDebug
        #else
        let expected = false
        #endif
        #expect(IllucetLaunchRouting.usesUITestFixtures(
            arguments: arguments, override: override
        ) == expected)
    }
}
