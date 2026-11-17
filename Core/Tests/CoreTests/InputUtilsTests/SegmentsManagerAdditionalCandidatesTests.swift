@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private func makeSegmentsManager(liveConversion: Bool? = nil) -> SegmentsManager {
    SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        containerURL: nil,
        context: .init(useZenzai: false, liveConversion: liveConversion)
    )
}

@MainActor
@Test func explicitConversionStartsWithTheFirstClauseFocused() throws {
    let manager = makeSegmentsManager(liveConversion: false)
    manager.insertAtCursorPosition("きょうはとうきょうへいきます", inputStyle: .direct)
    manager.insertCompositionSeparator(inputStyle: .direct)
    let displayed = manager.getCurrentMarkedText(inputState: .previewing).map(\.content).joined()

    manager.focusExplicitConversionPreview()
    let initial = manager.getCurrentMarkedText(inputState: .previewing)
    try #require(initial.first { $0.focus == .focused }?.content == "今日は")
    #expect(initial.map(\.content).joined() == displayed)
    try #require(manager.focusLiveConversionSegment(1))
    let next = manager.getCurrentMarkedText(inputState: .previewing)
    #expect(next.first { $0.focus == .focused }?.content == "東京へ")
    #expect(next.map(\.content).joined() == displayed)
}

@MainActor
@Test func movingRightAfterResizingFocusesIndividualTrailingPreviewClauses() {
    let manager = makeSegmentsManager(liveConversion: true)
    let suffix = "きょうはとうきょうへいきます"
    manager.insertAtCursorPosition("あしたは" + suffix, inputStyle: .direct)
    manager.editSegment(count: -suffix.count)
    let original = manager.getCurrentMarkedText(inputState: .selecting).map(\.content).joined()

    manager.moveConversionSegment(1)
    let first = manager.getCurrentMarkedText(inputState: .selecting)
    #expect(first.first { $0.focus == .focused }?.content == "今日は")
    #expect(first.map(\.content).joined() == original)

    manager.moveConversionSegment(1)
    let second = manager.getCurrentMarkedText(inputState: .selecting)
    #expect(second.first { $0.focus == .focused }?.content == "東京へ")
    #expect(second.map(\.content).joined() == original)
}

@MainActor
@Test(arguments: [InputStyle.direct, .roman2kana])
func navigatingLiveConversionPreservesTheDisplayedCandidate(inputStyle: InputStyle) throws {
    let manager = makeSegmentsManager(liveConversion: true)
    let input = inputStyle == .direct ? "きょうはとうきょうへいきます" : "kyouhatoukyouheikimasu"
    manager.insertAtCursorPosition(input, inputStyle: inputStyle)
    let displayed = manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
    try #require(manager.focusLiveConversionSegment(-1))
    let last = manager.getCurrentMarkedText(inputState: .previewing)
    #expect(last.map(\.content).joined() == displayed)
    #expect(last.first { $0.focus == .focused }?.content == "行きます")
    try #require(manager.focusLiveConversionSegment(-1))
    let previous = manager.getCurrentMarkedText(inputState: .previewing)
    #expect(previous.map(\.content).joined() == displayed)
    #expect(previous.first { $0.focus == .focused }?.content != last.first { $0.focus == .focused }?.content)
    try #require(manager.focusLiveConversionSegment(1))
    #expect(manager.getCurrentMarkedText(inputState: .previewing) == last)
    if case .hidden = manager.getCurrentCandidateWindow(inputState: .previewing) {
    } else {
        Issue.record("Moving focus should keep the candidate window closed")
    }
    #expect(manager.commitMarkedText(inputState: .previewing) == displayed)
}

@MainActor
@Test func restoringReadingRejoinsRetainedRomanInputAndSuppressesLiveConversion() {
    let manager = makeSegmentsManager(liveConversion: true)
    manager.insertAtCursorPosition("kyouhatoukyou", inputStyle: .roman2kana)
    manager.retainConversionCandidate(
        Candidate(text: "今日は", value: 0, composingCount: .surfaceCount(4), lastMid: 0, data: [])
    )

    #expect(manager.restoreReadingIfConverted(inputState: .composing))
    #expect(manager.retainedConversionText.isEmpty)
    #expect(manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined() == "きょうはとうきょう")
    #expect(!manager.restoreReadingIfConverted(inputState: .composing))

    manager.insertAtCursorPosition("he", inputStyle: .roman2kana)
    #expect(manager.convertTarget == "きょうはとうきょうへ")
}

@MainActor
@Test func restoringReadingAllowsConversionAgainWithoutLiveConversion() {
    let manager = makeSegmentsManager(liveConversion: false)
    manager.insertAtCursorPosition("とうきょう", inputStyle: .direct)
    #expect(!manager.restoreReadingIfConverted(inputState: .composing))
    manager.insertCompositionSeparator(inputStyle: .direct)
    #expect(manager.getCurrentMarkedText(inputState: .previewing).map(\.content).joined() == "東京")

    #expect(manager.restoreReadingIfConverted(inputState: .previewing))
    #expect(manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined() == "とうきょう")
    manager.insertCompositionSeparator(inputStyle: .direct)
    #expect(manager.getCurrentMarkedText(inputState: .previewing).map(\.content).joined() == "東京")
}

@MainActor
@Test(arguments: [true, false])
func resizedRangePreviewsTrailingConversionWhenLiveConversionIsEnabled(liveConversion: Bool) {
    let manager = makeSegmentsManager(liveConversion: liveConversion)
    manager.insertAtCursorPosition("きょうはとうきょう", inputStyle: .direct)
    manager.editSegment(count: -5)
    let marked = manager.getCurrentMarkedText(inputState: .selecting).map(\.content)
    #expect(marked.last == (liveConversion ? "東京" : "とうきょう"))

    manager.retainVisibleConversion()
    #expect(manager.commitMarkedText(inputState: .previewing) == marked.joined())
}

@MainActor
@Test func shrinkingRangePreservesAnUnchangedLaterSelection() throws {
    let manager = makeSegmentsManager(liveConversion: true)
    manager.insertAtCursorPosition("きょうはとうきょう", inputStyle: .direct)
    manager.editSegment(count: -5)
    _ = manager.getCurrentMarkedText(inputState: .selecting)
    manager.moveConversionSegment(1)

    guard case let .selecting(candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("Expected candidates for the second segment")
        return
    }
    let index = try #require(candidates.indices.first { candidates[$0].text == "トウキョウ" })
    manager.requestSelectingRow(index)
    manager.moveConversionSegment(-1)
    manager.editSegment(count: -1)

    let marked = manager.getCurrentMarkedText(inputState: .selecting).map(\.content)
    #expect(marked.last?.hasSuffix("トウキョウ") == true)
    manager.retainVisibleConversion()
    #expect(manager.commitMarkedText(inputState: .previewing) == marked.joined())
}

@MainActor
@Test func retainedConversionSurvivesAppendingAndCommitsAsOneComposition() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("きょうははれ", inputStyle: .direct)
    manager.retainConversionCandidate(
        Candidate(text: "今日は", value: 0, composingCount: .surfaceCount(4), lastMid: 0, data: [])
    )
    manager.appendAfterRetainedConversion([.character("で")], inputStyle: .direct)

    #expect(manager.retainedConversionText == "今日は")
    #expect(manager.convertTarget == "はれで")
    if case .hidden = manager.getCurrentCandidateWindow(inputState: .composing) {
        // Expected after appending.
    } else {
        Issue.record("Appending after candidate selection should close the candidate window")
    }
    let suffix = manager.getCurrentMarkedText(inputState: .composing).dropFirst().map(\.content).joined()
    #expect(manager.commitMarkedText(inputState: .composing) == "今日は" + suffix)
    #expect(manager.isEmpty)
}

@MainActor
@Test func retainedConversionRestoresThePreviousSegmentWithoutDroppingTheSuffix() {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("きょうははれ", inputStyle: .direct)
    manager.editSegment(count: -2)
    _ = manager.getCurrentCandidateWindow(inputState: .selecting)
    guard let candidate = manager.selectedCandidate else {
        Issue.record("Expected a candidate for the first segment")
        return
    }
    manager.retainConversionCandidate(candidate)
    manager.moveConversionSegment(-1)

    #expect(manager.retainedConversionText.isEmpty)
    #expect(manager.convertTarget == "きょうははれ")
    #expect(manager.selectedCandidate?.text == candidate.text)
}

@MainActor
private func makeEditedRangeScenario() -> (manager: SegmentsManager, selectedRuby: String) {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("hennkann", inputStyle: .roman2kana)
    manager.editSegment(count: -1)
    manager.requestSetCandidateWindowState(visible: true)
    _ = manager.getCurrentCandidateWindow(inputState: .selecting)

    let selectedRuby = manager.selectedCandidate!.data.map(\.ruby).joined()
    return (manager, selectedRuby)
}

@MainActor
@Test func testAdditionalHiraganaCandidateUsesEditedSelectionRuby() async throws {
    let (manager, selectedRuby) = makeEditedRangeScenario()
    manager.requestSelectingPrevCandidate()

    switch manager.getCurrentCandidateWindow(inputState: .selecting) {
    case .selecting(let candidates, _):
        let presentations = manager.makeCandidatePresentations(candidates)
        guard let hiraganaPresentation = presentations.first(where: { $0.displayContext.annotationText == "ひらがな" }) else {
            Issue.record("Expected additional hiragana candidate.")
            return
        }
        let hiraganaRuby = hiraganaPresentation.candidate.data.map(\.ruby).joined()
        #expect(hiraganaRuby == selectedRuby)
    case .hidden, .composing:
        Issue.record("Expected selecting state while showing additional candidates.")
    }
}

@MainActor
@Test func testAdditionalCandidatesExpandInSuffixOrder() async throws {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("abc", inputStyle: .direct)
    manager.requestSetCandidateWindowState(visible: true)

    manager.requestSelectingPrevCandidate()

    switch manager.getCurrentCandidateWindow(inputState: .selecting) {
    case .selecting(let candidates, let selectionIndex):
        #expect(selectionIndex == 0)
        let firstContexts = manager.makeCandidatePresentations(candidates).map(\.displayContext)
        #expect(firstContexts.count == candidates.count)
        #expect(firstContexts.first?.annotationText == "ひらがな")
    case .hidden, .composing:
        Issue.record("Expected selecting state after first previous-selection request.")
        return
    }

    manager.requestSelectingPrevCandidate()

    switch manager.getCurrentCandidateWindow(inputState: .selecting) {
    case .selecting(let candidates, let selectionIndex):
        #expect(selectionIndex == 0)
        let contexts = manager.makeCandidatePresentations(candidates).map(\.displayContext)
        if contexts.count >= 2 {
            #expect(contexts[0].annotationText == "カタカナ")
            #expect(contexts[1].annotationText == "ひらがな")
        } else {
            Issue.record("Expected at least 2 additional candidates after second request.")
        }
    case .hidden, .composing:
        Issue.record("Expected selecting state after second previous-selection request.")
    }
}

@MainActor
@Test func testAdditionalCandidatesExpansionCapsAtDeclaredCount() async throws {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("abc", inputStyle: .direct)
    manager.requestSetCandidateWindowState(visible: true)

    for _ in 0..<10 {
        manager.requestSelectingPrevCandidate()
    }

    switch manager.getCurrentCandidateWindow(inputState: .selecting) {
    case .selecting(let candidates, _):
        let annotationTexts = manager.makeCandidatePresentations(candidates)
            .map(\.displayContext)
            .compactMap(\.annotationText)
        #expect(annotationTexts == ["英数", "全角英数", "半角カナ", "カタカナ", "ひらがな"])
    case .hidden, .composing:
        Issue.record("Expected selecting state while additional candidates are expanded.")
    }
}

@MainActor
@Test func testResettingSelectionClearsAdditionalCandidateContexts() async throws {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("abc", inputStyle: .direct)
    manager.requestSetCandidateWindowState(visible: true)
    manager.requestSelectingPrevCandidate()

    switch manager.getCurrentCandidateWindow(inputState: .selecting) {
    case .selecting(let candidates, _):
        let beforeReset = manager.makeCandidatePresentations(candidates).map(\.displayContext)
        #expect(beforeReset.contains { $0.annotationText != nil })

        manager.requestResettingSelection()

        let afterReset = manager.makeCandidatePresentations(candidates).map(\.displayContext)
        #expect(afterReset.allSatisfy { $0.annotationText == nil })
    case .hidden, .composing:
        Issue.record("Expected selecting state after expanding additional candidates.")
    }
}
