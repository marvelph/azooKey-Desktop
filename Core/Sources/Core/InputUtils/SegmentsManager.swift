import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public final class SegmentsManager {
    public init(
        kanaKanjiConverter: KanaKanjiConverter,
        applicationDirectoryURL: URL,
        containerURL: URL?,
        context: Context = Context()
    ) {
        self.kanaKanjiConverter = kanaKanjiConverter
        self.applicationDirectoryURL = applicationDirectoryURL
        self.containerURL = containerURL
        self.context = context
    }

    /// テストなどの設定注入のための型。外部には設定を露出させない。
    public struct Context {
        public init() {}
        init(useZenzai: Bool, liveConversion: Bool? = nil) {
            self.useZenzai = useZenzai
            self.liveConversion = liveConversion
        }

        var useZenzai: Bool = true
        var liveConversion: Bool?
    }

    public weak var delegate: (any SegmentManagerDelegate)?
    private var kanaKanjiConverter: KanaKanjiConverter
    private let applicationDirectoryURL: URL
    private let containerURL: URL?
    private let context: Context

    private var composingText: ComposingText = ComposingText()
    private struct RetainedSegment {
        var input: ComposingText
        var candidate: Candidate
        var start: Int
    }
    private var retainedSegments: [RetainedSegment] = []
    private var laterSelections: [Int: RetainedSegment] = [:]
    private lazy var trailingConverter: KanaKanjiConverter = .withDefaultDictionary()
    private var trailingPreview: (input: ComposingText, context: String, candidates: [Candidate], reading: String)?
    private var lastInputStyle: InputStyle = .direct

    private var liveConversionEnabled: Bool {
        self.context.liveConversion ?? Config.LiveConversion().value
    }
    private var userDictionary: Config.UserDictionary.Value {
        Config.UserDictionary().value
    }
    private var systemUserDictionary: Config.SystemUserDictionary.Value {
        Config.SystemUserDictionary().value
    }
    private var zenzaiPersonalizationLevel: Config.ZenzaiPersonalizationLevel.Value {
        Config.ZenzaiPersonalizationLevel().value
    }
    private var rawCandidates: ConversionResult?

    private var selectionIndex: Int?
    private var didExperienceSegmentEdition = false
    private var lastOperation: Operation = .other
    private var shouldShowCandidateWindow = false

    private var isShowingAdditionalCandidates = false
    private var additionalCandidates: [CandidatePresentation] = []
    private var showingAdditionalCandidateCount = 0
    private var isFixingAdditionalCandidateTop = false

    private var shouldShowDebugCandidateWindow: Bool = false
    private var debugCandidates: [Candidate] = []

    private var replaceSuggestions: [Candidate] = []
    private var suggestSelectionIndex: Int?
    private var backspaceAdjustedPredictionCandidate: PredictionCandidate?
    private var backspaceTypoCorrectionLock: BackspaceTypoCorrectionLock?

    public struct PredictionCandidate: Sendable, Equatable {
        public var displayText: String
        public var appendText: String
        public var deleteCount: Int = 0
    }

    struct BackspaceTypoCorrectionLock: Sendable {
        var displayText: String
        var targetReading: String
    }

    private func candidateReading(_ candidate: Candidate) -> String {
        candidate.data.map(\.ruby).joined()
    }

    public func makeCandidatePresentations(_ candidates: [Candidate]) -> [CandidatePresentation] {
        let additionalPresentations = self.additionalCandidatePresentationsForSelectionIndex
        return candidates.indices.map { index in
            if index < additionalPresentations.count {
                return .init(candidate: candidates[index], displayContext: additionalPresentations[index].displayContext)
            }
            return .init(candidate: candidates[index])
        }
    }

    private lazy var zenzaiPersonalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode? = self.getZenzaiPersonalizationMode()

    private func getZenzaiPersonalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        let alpha = self.zenzaiPersonalizationLevel.alpha
        // オフなので。
        if alpha == 0 {
            return nil
        }
        guard let containerURL else {
            self.appendDebugMessage("❌ Failed to get container URL.")
            return nil
        }

        let base = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/", isDirectory: false).path + "/lm"
        let personal = containerURL.appendingPathComponent("Library/Application Support/p13n_v1").path + "/lm"
        // check personal lm existence
        guard [
            FileManager.default.fileExists(atPath: personal + "_c_abc.marisa"),
            FileManager.default.fileExists(atPath: personal + "_r_xbx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_abx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_xbc.marisa")
        ].allSatisfy(\.self) else {
            self.appendDebugMessage("❌ Seems like there is missing marisa file for prefix \(personal)")
            return nil
        }

        return .init(baseNgramLanguageModel: base, personalNgramLanguageModel: personal, alpha: alpha)
    }

    private enum Operation: Sendable {
        case insert
        case insertShowingReading
        case delete
        case editSegment
        case other
    }

    public func appendDebugMessage(_ string: String) {
        self.debugCandidates.insert(
            Candidate(
                text: string.replacingOccurrences(of: "\n", with: "\\n"),
                value: 0,
                composingCount: .surfaceCount(0),
                lastMid: 0,
                data: []
            ),
            at: 0
        )
        while self.debugCandidates.count > 100 {
            self.debugCandidates.removeLast()
        }
    }

    private func zenzaiMode(leftSideContext: String?, requestRichCandidates: Bool) -> ConvertRequestOptions.ZenzaiMode {
        if !self.context.useZenzai {
            return .off
        }
        return .on(
            weight: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ggml-model-Q5_K_M.gguf", isDirectory: false),
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            personalizationMode: self.zenzaiPersonalizationMode,
            versionDependentMode: .v3(
                .init(
                    profile: Config.ZenzaiProfile().value,
                    leftSideContext: leftSideContext
                )
            )
        )
    }

    private var metadata: ConvertRequestOptions.Metadata {
        if let tag = PackageMetadata.gitTag {
            .init(versionString: "azooKey on macOS (\(tag))")
        } else if let commit = PackageMetadata.gitCommit {
            .init(versionString: "azooKey on macOS (\(commit.prefix(7)))")
        } else {
            .init(versionString: "azooKey on macOS (unknown version)")
        }
    }

    private func options(
        leftSideContext: String?,
        requestRichCandidates: Bool,
        requireJapanesePrediction: ConvertRequestOptions.PredictionMode,
        requireEnglishPrediction: ConvertRequestOptions.PredictionMode
    ) -> ConvertRequestOptions {
        let canUseDebugTypoCorrection = Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights()
        return .init(
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            learningType: Config.Learning().value.learningType,
            memoryDirectoryURL: self.azooKeyMemoryDir,
            sharedContainerURL: self.azooKeyMemoryDir,
            textReplacer: .withDefaultEmojiDictionary(),
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: self.zenzaiMode(leftSideContext: leftSideContext, requestRichCandidates: requestRichCandidates),
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: self.metadata
        )
    }

    private func hasDebugTypoCorrectionWeights() -> Bool {
        DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: self.downloadedInputN5LMDir)
    }

    public var azooKeyMemoryDir: URL {
        self.applicationDirectoryURL
    }

    public var downloadedInputN5LMDir: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.applicationDirectoryURL.deletingLastPathComponent()
        )
    }

    @MainActor
    public func activate() {
        self.shouldShowCandidateWindow = false
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.zenzaiPersonalizationMode = self.getZenzaiPersonalizationMode()
    }

    @MainActor
    public func deactivate() {
        self.retainedSegments.removeAll()
        self.laterSelections.removeAll()
        self.trailingPreview = nil
        self.kanaKanjiConverter.stopComposition()
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.composingText.stopComposition()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// この入力を打ち切る
    public func stopComposition() {
        self.retainedSegments.removeAll()
        self.laterSelections.removeAll()
        self.trailingPreview = nil
        self.composingText.stopComposition()
        self.kanaKanjiConverter.stopComposition()
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    public func restoreReadingIfConverted(inputState: InputState, displayedText: String? = nil) -> Bool {
        let reading = self.retainedSegments.map(\.input.convertTarget).joined() + self.composingText.convertTarget
        let displayedText = displayedText ?? self.getCurrentMarkedText(inputState: inputState).map(\.content).joined()
        guard !reading.isEmpty, displayedText != reading else { return false }

        self.composingText = ComposingText(
            convertTargetCursorPosition: reading.count,
            input: self.retainedSegments.flatMap(\.input.input) + self.composingText.input,
            convertTarget: reading
        )
        self.retainedSegments.removeAll()
        self.laterSelections.removeAll()
        self.trailingPreview = nil
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .insertShowingReading
        self.shouldShowCandidateWindow = false
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.requestResettingSelection()
        return true
    }

    @MainActor
    /// 日本語入力自体をやめる
    public func stopJapaneseInput() {
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    /// 変換キーを押したタイミングで入力の区切りを示す
    @MainActor
    public func insertCompositionSeparator(inputStyle: InputStyle, skipUpdate: Bool = false) {
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            // 区切りがある場合も、候補が消去されていれば取得し直す
            if !skipUpdate, self.rawCandidates == nil {
                self.updateRawCandidate()
            }
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle, showReading: Bool = false) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(string, inputStyle: inputStyle)
        self.lastOperation = showReading ? .insertShowingReading : .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func editSegment(count: Int) {
        // 現在選ばれているprefix candidateが存在する場合、まずそれに合わせてカーソルを移動する
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            var afterComposingText = self.composingText
            afterComposingText.prefixComplete(composingCount: candidates[selectionIndex].composingCount)
            let prefixCount = self.composingText.convertTarget.count - afterComposingText.convertTarget.count
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + prefixCount)
        }
        if count > 0 {
            if self.composingText.isAtEndIndex && !self.didExperienceSegmentEdition {
                // 現在のカーソルが右端にある場合、左端の次に移動する
                _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + count)
            } else {
                // それ以外の場合、右に広げる
                _ = self.composingText.moveCursorFromCursorPosition(count: count)
            }
        } else {
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
        }
        if self.composingText.isAtStartIndex {
            // 最初にある場合は一つ右に進める
            _ = self.composingText.moveCursorFromCursorPosition(count: 1)
        }
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1) {
        if self.composingText.isEmpty {
            _ = self.restorePreviousConversionSegment()
        }
        self.laterSelections.removeAll()
        var previousComposingText = self.composingText.prefixToCursorPosition()
        if !self.composingText.isAtEndIndex {
            // 右端に持っていく
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // 一度segmentの編集状態もリセットにする
            self.didExperienceSegmentEdition = false
            previousComposingText = self.composingText.prefixToCursorPosition()
        }
        self.composingText.deleteBackwardFromCursorPosition(count: count)
        self.lastOperation = .delete
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        let currentConvertTarget = self.composingText.convertTarget
        guard count == 1 else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
            if self.backspaceAdjustedPredictionCandidate == nil {
                self.backspaceTypoCorrectionLock = nil
            }
            return
        }
        self.backspaceTypoCorrectionLock = self.lmBasedBackspaceTypoCorrectionLock(previousComposingText: previousComposingText)
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
        } else {
            self.backspaceAdjustedPredictionCandidate = nil
        }
    }

    @MainActor
    public func forgetMemory() {
        if let selectedCandidate {
            self.kanaKanjiConverter.forgetMemory(selectedCandidate)
            self.appendDebugMessage("\(#function): forget \(selectedCandidate.data.map {$0.word})")
        }
    }

    private var candidates: [Candidate]? {
        guard let rawCandidates = self.rawCandidatesList else {
            return self.isShowingAdditionalCandidates
                ? self.additionalCandidatesForSelectionIndex
                : nil
        }
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    private var rawCandidatesList: [Candidate]? {
        guard let rawCandidates else {
            return nil
        }
        if !self.didExperienceSegmentEdition {
            if rawCandidates.firstClauseResults.contains(where: { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }) {
                // firstClauseCandidateがmainResultsと同じサイズの場合は、何もしない方が良い
                return rawCandidates.mainResults
            } else {
                // 変換範囲がエディットされていない場合
                let seenAsFirstClauseResults = rawCandidates.firstClauseResults.mapSet(transform: \.text)
                return rawCandidates.firstClauseResults + rawCandidates.mainResults.filter {
                    !seenAsFirstClauseResults.contains($0.text)
                }
            }
        } else {
            return rawCandidates.mainResults
        }
    }

    private var candidateOffsetByAdditionalCandidates: Int {
        self.isShowingAdditionalCandidates ? self.showingAdditionalCandidateCount : 0
    }

    private var additionalCandidatesForSelectionIndex: [Candidate] {
        self.additionalCandidatePresentationsForSelectionIndex.map(\.candidate)
    }

    private var additionalCandidatePresentationsForSelectionIndex: [CandidatePresentation] {
        guard self.isShowingAdditionalCandidates else {
            return []
        }
        guard self.candidateOffsetByAdditionalCandidates > 0 else {
            return []
        }
        return Array(self.additionalCandidates.suffix(self.candidateOffsetByAdditionalCandidates))
    }

    public var convertTarget: String {
        self.composingText.convertTarget
    }

    public var isEmpty: Bool {
        self.composingText.isEmpty && self.retainedSegments.isEmpty
    }

    public func getCleanLeftSideContext(maxCount: Int) -> String? {
        self.delegate?.getLeftSideContext(maxCount: 30).map {
            var last = $0.split(separator: "\n", omittingEmptySubsequences: false).last ?? $0[...]
            // 前方の空白を削除する
            while last.first?.isWhitespace ?? false {
                last = last.dropFirst()
            }
            return String(last)
        }
    }

    /// Updates the `self.rawCandidates` based on the current input context.
    ///
    /// This function is responsible for handling candidate conversion,
    /// taking into account partial confirmations and optionally fetching rich candidates.
    /// It also allows an override for the left-side context when necessary.
    ///
    /// - Parameters:
    ///   - requestRichCandidates: A Boolean flag indicating whether to fetch rich candidates (default is `false`). Generating rich candidates takes longer time.
    ///   - forcedLeftSideContext: An optional string that overrides the left-side context (default is `nil`).
    ///
    /// - Note:
    ///   This function is executed on the `@MainActor` to ensure UI consistency.
    @MainActor private func updateRawCandidate(requestRichCandidates: Bool = false, forcedLeftSideContext: String? = nil) {
        self.trailingPreview = nil
        if self.lastOperation != .delete {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
        }
        self.resetAdditionalCandidates()
        // 不要
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.kanaKanjiConverter.stopComposition()
            return
        }
        // ユーザ辞書情報の更新
        var userDictionary: [DicdataElement] = userDictionary.items.map {
            .init(word: $0.word, ruby: $0.reading.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
        }
        self.appendDebugMessage("userDictionaryCount: \(userDictionary.count)")
        let systemUserDictionary: [DicdataElement] = systemUserDictionary.items.map {
            .init(word: $0.word, ruby: $0.reading.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
        }
        self.appendDebugMessage("systemUserDictionaryCount: \(systemUserDictionary.count)")
        userDictionary.append(contentsOf: consume systemUserDictionary)

        /// 日付・時刻変換を事前に入れておく
        let dynamicShortcuts: [DicdataElement] =
            [
                ("M/d", -18, DateTemplateLiteral.CalendarType.western),
                ("yyyy/MM/dd", -18.1, .western),
                ("yyyy-MM-dd", -18.2, .western),
                ("M月d日（E）", -18.3, .western),
                ("yyyy年M月d日", -18.4, .western),
                ("Gyyyy年M月d日", -18.5, .japanese),
                ("E曜日", -18.6, .western)
            ].flatMap { (format, value: PValue, type) in
                [
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-2", deltaUnit: 60 * 60 * 24).export(), ruby: "オトトイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-1", deltaUnit: 60 * 60 * 24).export(), ruby: "キノウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "キョウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "1", deltaUnit: 60 * 60 * 24).export(), ruby: "アシタ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "2", deltaUnit: 60 * 60 * 24).export(), ruby: "アサッテ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
                ]
            } + [
                // 月
                .init(word: DateTemplateLiteral(format: "MM月", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コンゲツ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                // 年
                .init(word: DateTemplateLiteral(format: "yyyy年", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "Gyyyy年", type: .japanese, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                // 時刻
                .init(word: DateTemplateLiteral(format: "HH:mm", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "HH時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                .init(word: DateTemplateLiteral(format: "aK時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.2)
            ]

        if self.lastOperation == .editSegment, self.liveConversionEnabled {
            self.trailingConverter.importDynamicUserDictionary(userDictionary, shortcuts: dynamicShortcuts)
        }
        self.kanaKanjiConverter.importDynamicUserDictionary(consume userDictionary, shortcuts: dynamicShortcuts)

        let prefixComposingText = self.composingText.prefixToCursorPosition()
        let leftSideContext = forcedLeftSideContext
            ?? ((self.getCleanLeftSideContext(maxCount: 30) ?? "") + self.retainedConversionText)
        let result = self.kanaKanjiConverter.requestCandidates(
            prefixComposingText,
            options: options(
                leftSideContext: leftSideContext,
                requestRichCandidates: requestRichCandidates,
                requireJapanesePrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
                requireEnglishPrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled
            )
        )
        self.rawCandidates = result
    }

    @MainActor public func update(requestRichCandidates: Bool) {
        self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        self.shouldShowCandidateWindow = true
    }

    public var retainedConversionText: String {
        self.retainedSegments.map(\.candidate.text).joined()
    }

    @MainActor
    @discardableResult
    public func retainConversionCandidate(_ candidate: Candidate? = nil) -> Bool {
        guard let candidate = candidate ?? self.selectedCandidate ?? self.candidates?.first else { return false }
        var remainder = self.composingText
        _ = remainder.moveCursorFromCursorPosition(count: remainder.convertTarget.count)
        remainder.prefixComplete(composingCount: candidate.composingCount)
        let length = self.composingText.convertTarget.count - remainder.convertTarget.count
        guard length > 0 else { return false }
        var prefix = self.composingText
        _ = prefix.moveCursorFromCursorPosition(count: length - prefix.convertTargetCursorPosition)
        let start = self.retainedReadingLength
        self.retainedSegments.append(.init(input: prefix.prefixToCursorPosition(), candidate: candidate, start: start))
        self.composingText = remainder
        self.requestResettingSelection()
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        return true
    }

    @MainActor
    public func retainVisibleConversion() {
        if let candidate = self.selectedCandidate ?? self.candidates?.first {
            let trailing = self.trailingConversion(after: candidate)
            if self.retainConversionCandidate(candidate) {
                for candidate in trailing.candidates {
                    guard self.retainConversionCandidate(candidate) else { break }
                }
            }
        }
        self.laterSelections.removeAll()
        self.trailingPreview = nil
    }

    private var wholePreviewCandidate: Candidate? {
        guard let candidate = self.rawCandidates?.mainResults.first,
              self.composingText.isWholeComposingText(composingCount: candidate.composingCount) else {
            return nil
        }
        return candidate
    }

    @MainActor
    public func retainConversionPreview() {
        if let candidate = self.wholePreviewCandidate {
            self.retainConversionCandidate(candidate)
        }
    }

    private var retainedReadingLength: Int {
        self.retainedSegments.reduce(0) { $0 + $1.input.convertTarget.count }
    }

    private func trailingConversion(after focused: Candidate) -> (candidates: [Candidate], reading: String) {
        var remaining = self.composingText
        _ = remaining.moveCursorFromCursorPosition(count: remaining.convertTarget.count)
        remaining.prefixComplete(composingCount: focused.composingCount)
        let start = self.retainedReadingLength + self.composingText.convertTarget.count - remaining.convertTarget.count
        let preview = self.lastOperation == .editSegment && self.liveConversionEnabled
        var context = preview ? (self.getCleanLeftSideContext(maxCount: 30) ?? "") + self.retainedConversionText + focused.text : ""
        if preview, let cached = self.trailingPreview, cached.input == remaining, cached.context == context {
            return (cached.candidates, cached.reading)
        }
        let input = remaining
        let initialContext = context
        var offset = start
        var candidates: [Candidate] = []
        // Match the old selections by reading position so boundaries farther right can survive a resize.
        for segment in self.laterSelections.values.sorted(by: { $0.start < $1.start }) {
            let gap = segment.start - offset
            guard gap >= 0, remaining.convertTarget.dropFirst(gap).hasPrefix(segment.input.convertTarget) else { continue }
            if gap > 0 {
                guard preview, let candidate = self.trailingPreviewCandidate(in: remaining, length: gap, context: context) else { break }
                candidates.append(candidate)
                context += candidate.text
                remaining.prefixComplete(composingCount: .surfaceCount(gap))
            }
            let length = segment.input.convertTarget.count
            var candidate = segment.candidate
            candidate.composingCount = .surfaceCount(length)
            candidates.append(candidate)
            context += segment.candidate.text
            remaining.prefixComplete(composingCount: .surfaceCount(length))
            offset = segment.start + length
        }
        if preview, let candidate = self.trailingPreviewCandidate(in: remaining, length: remaining.convertTarget.count, context: context) {
            candidates.append(candidate)
            remaining.stopComposition()
        }
        if preview {
            self.trailingPreview = (input, initialContext, candidates, remaining.convertTarget)
        }
        return (candidates, remaining.convertTarget)
    }

    private func trailingPreviewCandidate(in input: ComposingText, length: Int, context: String) -> Candidate? {
        guard length > 0 else { return nil }
        var prefix = input
        _ = prefix.moveCursorFromCursorPosition(count: length - prefix.convertTargetCursorPosition)
        prefix = prefix.prefixToCursorPosition()
        let result = self.trailingConverter.requestCandidates(
            prefix,
            options: self.options(
                leftSideContext: context,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            )
        )
        guard var candidate = result.mainResults.first(where: { prefix.isWholeComposingText(composingCount: $0.composingCount) }) else { return nil }
        candidate.composingCount = .surfaceCount(length)
        return candidate
    }

    private func restorePreviousConversionSegment() -> Bool {
        guard let segment = self.retainedSegments.popLast() else { return false }
        self.composingText = ComposingText(
            convertTargetCursorPosition: segment.input.convertTarget.count,
            input: segment.input.input + self.composingText.input,
            convertTarget: segment.input.convertTarget + self.composingText.convertTarget
        )
        self.laterSelections[segment.start] = segment
        self.didExperienceSegmentEdition = true
        return true
    }

    @MainActor
    public func moveConversionSegment(_ direction: Int) {
        if direction < 0 {
            guard !self.retainedSegments.isEmpty else { return }
            if self.retainConversionCandidate() {
                _ = self.restorePreviousConversionSegment()
            }
            guard self.restorePreviousConversionSegment() else { return }
        } else {
            guard let candidate = self.selectedCandidate else { return }
            var remainder = self.composingText
            _ = remainder.moveCursorFromCursorPosition(count: remainder.convertTarget.count)
            remainder.prefixComplete(composingCount: candidate.composingCount)
            guard !remainder.isEmpty else { return }
            self.retainConversionCandidate(candidate)
            if let next = self.laterSelections[self.retainedReadingLength],
               self.composingText.convertTarget.hasPrefix(next.input.convertTarget) {
                _ = self.composingText.moveCursorFromCursorPosition(
                    count: next.input.convertTarget.count - self.composingText.convertTargetCursorPosition
                )
                self.didExperienceSegmentEdition = true
            }
        }
        self.requestResettingSelection()
        self.update(requestRichCandidates: true)
        if let previous = self.laterSelections[self.retainedReadingLength] {
            self.selectionIndex = self.candidates?.firstIndex { $0.text == previous.candidate.text }
        }
    }

    @MainActor
    public func reopenConversionSegmentIfNeeded() -> Bool {
        if self.composingText.isEmpty, self.restorePreviousConversionSegment() {
            self.update(requestRichCandidates: true)
            if let previous = self.laterSelections[self.retainedReadingLength] {
                self.selectionIndex = self.candidates?.firstIndex { $0.text == previous.candidate.text }
            }
            return true
        }
        return false
    }

    @MainActor
    public func appendAfterRetainedConversion(_ pieces: [InputPiece], inputStyle: InputStyle) {
        _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count)
        self.laterSelections.removeAll()
        self.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        self.shouldShowCandidateWindow = false
    }

    @MainActor
    public func commitRetainedConversion() -> String {
        let text = self.retainedConversionText
        for segment in self.retainedSegments {
            self.kanaKanjiConverter.setCompletedData(segment.candidate)
            self.kanaKanjiConverter.updateLearningData(segment.candidate)
        }
        self.retainedSegments.removeAll()
        self.laterSelections.removeAll()
        return text
    }

    /// - note: 画面更新との整合性を保つため、この関数の実行前に左文脈を取得し、これを引数として与える
    @MainActor public func prefixCandidateCommited(_ candidate: Candidate, leftSideContext: String) {
        self.kanaKanjiConverter.setCompletedData(candidate)
        self.kanaKanjiConverter.updateLearningData(candidate)
        self.composingText.prefixComplete(composingCount: candidate.composingCount)

        if !self.composingText.isEmpty {
            // カーソルを右端に移動する
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.didExperienceSegmentEdition = false
            self.shouldShowCandidateWindow = true
            self.selectionIndex = nil
            self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext + candidate.text)
        }
    }

    public enum CandidateWindow: Sendable {
        case hidden
        case composing([Candidate], selectionIndex: Int?)
        case selecting([Candidate], selectionIndex: Int?)
    }

    public func requestSetCandidateWindowState(visible: Bool) {
        self.shouldShowCandidateWindow = visible
    }

    public func requestDebugWindowMode(enabled: Bool) {
        self.shouldShowDebugCandidateWindow = enabled
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = (self.selectionIndex ?? -1) + 1
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        let selectionIndex = self.selectionIndex ?? 0

        if self.isFixingAdditionalCandidateTop && self.isShowingAdditionalCandidates {
            if self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
                self.showingAdditionalCandidateCount += 1
            }
            self.selectionIndex = 0
            return
        }

        if selectionIndex == 0, !self.isShowingAdditionalCandidates {
            self.showAdditionalCandidatesIfNeeded()
            let additionalCount = self.candidateOffsetByAdditionalCandidates
            if additionalCount > 0 {
                self.isFixingAdditionalCandidateTop = true
                self.selectionIndex = 0
                return
            }
        }
        if selectionIndex == 0, self.isShowingAdditionalCandidates, self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
            self.isFixingAdditionalCandidateTop = true
            self.showingAdditionalCandidateCount += 1
            self.selectionIndex = 0
            return
        }
        self.selectionIndex = max(0, selectionIndex - 1)
    }

    public func requestSelectingRow(_ index: Int) {
        if self.isFixingAdditionalCandidateTop, index != 0 {
            self.isFixingAdditionalCandidateTop = false
        }
        self.selectionIndex = max(0, index)
    }

    public func requestSelectingSuggestionRow(_ row: Int) {
        suggestSelectionIndex = row
    }

    public func stopSuggestionSelection() {
        self.selectionIndex = nil
    }

    public func requestResettingSelection() {
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.resetAdditionalCandidates()
    }

    public var selectedCandidate: Candidate? {
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            return candidates[selectionIndex]
        }
        return nil
    }

    public func getCurrentCandidateWindow(inputState: InputState) -> CandidateWindow {
        switch inputState {
        case .none, .previewing, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            return .hidden
        case .composing:
            if self.shouldShowCandidateWindow, !self.liveConversionEnabled, let firstCandidate = self.rawCandidates?.mainResults.first {
                return .composing([firstCandidate], selectionIndex: 0)
            } else {
                return .hidden
            }
        case .selecting:
            if self.shouldShowDebugCandidateWindow {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, debugCandidates.count - 1))
                return .selecting(debugCandidates, selectionIndex: self.selectionIndex)
            } else if self.shouldShowCandidateWindow, let candidates, !candidates.isEmpty {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, candidates.count - 1))
                return .selecting(candidates, selectionIndex: self.selectionIndex)
            } else {
                return .hidden
            }
        }
    }

    public struct MarkedText: Sendable, Equatable, Hashable, Sequence {
        public enum FocusState: Sendable, Equatable, Hashable {
            case focused
            case unfocused
            case none
        }

        public struct Element: Sendable, Equatable, Hashable {
            public var content: String
            public var focus: FocusState
        }
        var text: [Element]

        public var selectionRange: NSRange

        public func makeIterator() -> Array<Element>.Iterator {
            text.makeIterator()
        }

        var isEmpty: Bool {
            self.text.isEmpty
        }
    }

    @MainActor
    public func getModifiedRubyCandidate(inputState: InputState, _ transform: (String) -> String) -> Candidate {
        let (ruby, composingCount): (String, ComposingCount) = switch inputState {
        case .selecting:
            if let selectedRuby = selectedCandidate?.data.map({ $0.ruby }).joined() {
                // `selectedCandidate.data` の全ての `ruby` を連結して返す
                (selectedRuby, .surfaceCount(selectedRuby.count))
            } else {
                // 選択範囲なしの場合はconvertTargetを返す
                (self.convertTarget, .inputCount(self.composingText.input.count))
            }
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            (self.convertTarget, .inputCount(self.composingText.input.count))
        }
        let candidateText = transform(ruby)
        return Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
    }

    @MainActor
    public func getModifiedRomanCandidate(inputState: InputState = .composing, _ transform: (String) -> String) -> Candidate {
        let targetComposingText: ComposingText
        switch inputState {
        case .selecting:
            targetComposingText = self.composingText.prefixToCursorPosition()
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            targetComposingText = self.composingText
        }
        let inputString = targetComposingText.input.map(\.piece).inputString(preferIntention: false)
        let composingCount: ComposingCount = .inputCount(targetComposingText.input.count)
        let candidateText = transform(inputString)
        let candidate = Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: inputString,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
        return candidate
    }

    @MainActor
    private func createAdditionalCandidates() -> [CandidatePresentation] {
        let candidates: [(candidate: Candidate, annotationText: String?)] = [
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0 }, "英数"),
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, "全角英数"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, "半角カナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana() }, "カタカナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toHiragana() }, "ひらがな")
        ]
        return candidates.map {
            .init(
                candidate: $0.candidate,
                displayContext: .init(annotationText: $0.annotationText)
            )
        }
    }

    @MainActor
    private func showAdditionalCandidatesIfNeeded() {
        if self.isShowingAdditionalCandidates {
            return
        }
        guard !self.convertTarget.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        let candidates = self.createAdditionalCandidates()
        guard !candidates.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        self.additionalCandidates = candidates
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
    }

    private func resetAdditionalCandidates() {
        self.isShowingAdditionalCandidates = false
        self.additionalCandidates = []
        self.showingAdditionalCandidateCount = 0
        self.isFixingAdditionalCandidateTop = false
    }

    @MainActor
    public func commitMarkedText(inputState: InputState) -> String {
        let markedText = self.getCurrentMarkedText(inputState: inputState)
        let text = markedText.reduce(into: "") {$0.append(contentsOf: $1.content)}
        if !self.retainedSegments.isEmpty {
            let suffix = String(text.dropFirst(self.retainedConversionText.count))
            _ = self.commitRetainedConversion()
            if let finalCandidate = self.candidates?.first(where: { $0.text == suffix }) {
                self.kanaKanjiConverter.setCompletedData(finalCandidate)
                self.kanaKanjiConverter.updateLearningData(finalCandidate)
            }
        } else if let candidate = self.candidates?.first(where: {$0.text == text}) {
            self.prefixCandidateCommited(candidate, leftSideContext: "")
        }
        self.stopComposition()
        return text
    }

    // サジェスト候補を設定するメソッド
    public func setReplaceSuggestions(_ candidates: [Candidate]) {
        self.replaceSuggestions = candidates
        self.suggestSelectionIndex = nil
    }

    // サジェスト候補の選択状態をリセット
    public func resetSuggestionSelection() {
        suggestSelectionIndex = nil
    }

    public func requestTypoCorrectionPredictionCandidates() -> [PredictionCandidate] {
        guard Config.DebugTypoCorrection().value else {
            return []
        }
        guard let backspaceAdjustedPredictionCandidate else {
            return []
        }
        return [backspaceAdjustedPredictionCandidate]
    }

    public static func preferredPredictionCandidates(
        typoCorrectionCandidates: [PredictionCandidate],
        predictionCandidates: [PredictionCandidate]
    ) -> [PredictionCandidate] {
        if !typoCorrectionCandidates.isEmpty {
            return typoCorrectionCandidates
        }
        return predictionCandidates
    }

    public static func shouldPresentTypoCorrectionPredictionCandidate(
        candidateDisplayText: String,
        previousComposingDisplayText: String
    ) -> Bool {
        // 削除前の previousComposingText と同じ表示候補は、訂正候補としては提示しない。
        candidateDisplayText != previousComposingDisplayText
    }

    public func requestPredictionCandidates() -> [PredictionCandidate] {
        guard Config.DebugPredictiveTyping().value else {
            return []
        }

        let target = self.composingText.convertTarget
        guard !target.isEmpty else {
            return []
        }

        guard let rawCandidates else {
            return []
        }

        for candidate in rawCandidates.predictionResults {
            let reading = candidateReading(candidate)
            guard !reading.isEmpty else {
                continue
            }
            if let predictionCandidate = Self.makePredictionCandidate(
                currentTarget: target,
                candidateReading: reading,
                displayText: candidate.text
            ) {
                return [predictionCandidate]
            }
        }

        return []
    }

    static func makePredictionCandidate(
        currentTarget: String,
        candidateReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        var matchTarget = currentTarget
        var deleteCount = 0
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            deleteCount = 1
        }
        guard matchTarget.count >= 2 else {
            return nil
        }

        let readingHiragana = candidateReading.toHiragana()
        let matchTargetHiragana = matchTarget.toHiragana()
        guard readingHiragana.hasPrefix(matchTargetHiragana) else {
            return nil
        }
        guard matchTargetHiragana.count < readingHiragana.count else {
            return nil
        }

        let appendText = String(readingHiragana.dropFirst(matchTargetHiragana.count))
        guard !appendText.isEmpty else {
            return nil
        }

        return .init(displayText: displayText, appendText: appendText, deleteCount: deleteCount)
    }

    private func requestTypoCorrectionCandidates(composingText targetComposingText: ComposingText, inputStyle: InputStyle) -> [String] {
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            return []
        }
        guard !targetComposingText.isEmpty else {
            return []
        }

        let leftSideContext = self.getCleanLeftSideContext(maxCount: 30) ?? ""
        let typoCandidates = self.kanaKanjiConverter.experimentalRequestTypoCorrection(
            leftSideContext: leftSideContext,
            composingText: targetComposingText,
            options: options(
                leftSideContext: leftSideContext,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            ),
            inputStyle: inputStyle,
            config: .init(
                languageModel: .ngram(.init(prefix: self.downloadedInputN5LMDir.path + "/lm_", n: 5, d: 0.75)),
                beamSize: 16,
                topK: 32,
                nBest: 3
            )
        )

        var seen: Set<String> = []
        return typoCandidates.compactMap { candidate in
            let text = candidate.convertedText.toHiragana()
            guard !text.isEmpty else {
                return nil
            }
            guard seen.insert(text).inserted else {
                return nil
            }
            return text
        }
    }

    private func convertedText(reading: String, leftSideContext: String?) -> String? {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)

        let result = self.kanaKanjiConverter.requestCandidates(
            composingText,
            options: options(
                leftSideContext: leftSideContext,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            )
        )
        return result.mainResults.first?.text
    }

    @MainActor
    private func lmBasedBackspaceTypoCorrectionLock(previousComposingText: ComposingText) -> BackspaceTypoCorrectionLock? {
        let typoCorrectionCandidates = self.requestTypoCorrectionCandidates(
            composingText: previousComposingText,
            inputStyle: self.lastInputStyle
        )
        guard let correctedReading = typoCorrectionCandidates.first else {
            return nil
        }

        let correctedDisplayText = self.convertedText(
            reading: correctedReading,
            leftSideContext: self.getCleanLeftSideContext(maxCount: 30)
        ) ?? correctedReading
        let previousComposingDisplayText = self.convertedText(
            reading: previousComposingText.convertTarget,
            leftSideContext: self.getCleanLeftSideContext(maxCount: 30)
        ) ?? previousComposingText.convertTarget
        guard Self.shouldPresentTypoCorrectionPredictionCandidate(
            candidateDisplayText: correctedDisplayText,
            previousComposingDisplayText: previousComposingDisplayText
        ) else {
            return nil
        }

        return .init(displayText: correctedDisplayText, targetReading: correctedReading)
    }

    static func makeBackspaceTypoCorrectionPredictionCandidate(
        currentConvertTarget: String,
        targetReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        let operation = Self.makeSuffixEditOperation(from: currentConvertTarget, to: targetReading)
            ?? Self.makeSuffixEditOperation(from: currentConvertTarget.toHiragana(), to: targetReading)
        guard let operation else {
            return nil
        }
        return .init(displayText: displayText, appendText: operation.appendText, deleteCount: operation.deleteCount)
    }

    private static func makeSuffixEditOperation(from currentText: String, to targetText: String) -> (appendText: String, deleteCount: Int)? {
        let sharedPrefixLength = zip(currentText, targetText).prefix(while: ==).count
        let deleteCount = currentText.count - sharedPrefixLength
        let appendText = String(targetText.dropFirst(sharedPrefixLength))
        guard deleteCount > 0 || !appendText.isEmpty else {
            return nil
        }
        return (appendText, deleteCount)
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        var marked = self.getActiveMarkedText(inputState: inputState)
        let retained = self.retainedConversionText
        if !retained.isEmpty, inputState != .none {
            marked.text.insert(.init(content: retained, focus: .unfocused), at: 0)
            if marked.selectionRange.location != NSNotFound {
                marked.selectionRange.location += retained.utf16.count
            }
        }
        return marked
    }

    private func getActiveMarkedText(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            let text = if self.lastOperation == .delete || self.lastOperation == .insertShowingReading {
                self.composingText.convertTarget
            } else if self.liveConversionEnabled,
                      self.composingText.convertTarget.count > 1,
                      let firstCandidate = self.rawCandidates?.mainResults.first {
                // それ以外の場合、ライブ変換が有効なら
                firstCandidate.text
            } else {
                // それ以外
                self.composingText.convertTarget
            }
            return MarkedText(text: [.init(content: text, focus: .none)], selectionRange: .notFound)
        case .previewing:
            if let fullCandidate = self.wholePreviewCandidate {
                return MarkedText(text: [.init(content: fullCandidate.text, focus: .none)], selectionRange: .notFound)
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .selecting:
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                let focused = candidates[self.selectionIndex!]
                let preview = self.trailingConversion(after: focused)
                let trailing = preview.candidates.map(\.text).joined() + preview.reading
                return MarkedText(
                    text: [
                        .init(content: focused.text, focus: .focused),
                        .init(content: trailing, focus: .unfocused)
                    ],
                    selectionRange: NSRange(location: focused.text.utf16.count, length: 0)
                )
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .replaceSuggestion:
            // サジェスト候補の選択状態を独立して管理
            if let index = suggestSelectionIndex,
               replaceSuggestions.indices.contains(index) {
                return MarkedText(
                    text: [.init(content: replaceSuggestions[index].text, focus: .focused)],
                    selectionRange: NSRange(location: replaceSuggestions[index].text.count, length: 0)
                )
            } else {
                return MarkedText(
                    text: [.init(content: composingText.convertTarget, focus: .none)],
                    selectionRange: .notFound
                )
            }
        case .unicodeInput(let codePoint):
            // Unicode入力モード: "U+" + コードポイントを表示
            let displayText = "U+" + codePoint
            return MarkedText(
                text: [.init(content: displayText, focus: .none)],
                selectionRange: NSRange(location: displayText.count, length: 0)
            )
        }
    }
}

public protocol SegmentManagerDelegate: AnyObject {
    func getLeftSideContext(maxCount: Int) -> String?
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
