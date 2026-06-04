// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("FirstRunWizardFlow")
struct FirstRunWizardFlowTests {
    @Test
    func builtInHasFourSteps() {
        let flow = FirstRunWizardFlow(viewerChoice: .builtIn)
        #expect(flow.steps == [.welcome, .viewerChoice, .builtInSettings, .firstLibrary])
        #expect(flow.count == 4)
    }

    @Test
    func externalHasThreeStepsNoBuiltInSettings() {
        let flow = FirstRunWizardFlow(viewerChoice: .external)
        #expect(flow.steps == [.welcome, .viewerChoice, .firstLibrary])
        #expect(flow.count == 3)
        #expect(flow.index(of: .builtInSettings) == nil)
    }

    @Test
    func nextAndPreviousTraverseVisibleStepsExternal() {
        let flow = FirstRunWizardFlow(viewerChoice: .external)
        #expect(flow.next(after: .welcome) == .viewerChoice)
        #expect(flow.next(after: .viewerChoice) == .firstLibrary)
        #expect(flow.next(after: .firstLibrary) == nil)
        #expect(flow.previous(before: .firstLibrary) == .viewerChoice)
        #expect(flow.previous(before: .welcome) == nil)
    }

    @Test
    func nextTraversesAllWhenBuiltIn() {
        let flow = FirstRunWizardFlow(viewerChoice: .builtIn)
        #expect(flow.next(after: .viewerChoice) == .builtInSettings)
        #expect(flow.next(after: .builtInSettings) == .firstLibrary)
        #expect(flow.previous(before: .builtInSettings) == .viewerChoice)
    }

    @Test
    func dotIndexDiffersByChoice() {
        #expect(FirstRunWizardFlow(viewerChoice: .external).index(of: .firstLibrary) == 2)
        #expect(FirstRunWizardFlow(viewerChoice: .builtIn).index(of: .firstLibrary) == 3)
    }
}
