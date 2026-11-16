import Cocoa
import Core
import CoreServices
import KanaKanjiConverterModule

protocol CandidatesViewControllerDelegate: AnyObject {
    func candidateSubmitted()
    func candidateSelectionChanged(_ row: Int)
}

class CandidatesViewController: BaseCandidateViewController {
    weak var delegate: (any CandidatesViewControllerDelegate)?
    private var showedRows: ClosedRange = 0...8
    private let dictionaryDefinitions: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()
    private let dictionaryQueue = DispatchQueue(label: "azooKey.dictionaryLookup", qos: .utility)
    private var pendingDictionaryLookups: Set<String> = []
    private var dictionarySelectionTimer: Timer?
    private var dictionarySelection: (row: Int, text: String)?
    private var displayedDefinition: String?
    private lazy var dictionaryTooltipLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var dictionaryTooltipWindow: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        let content = NSView()
        content.addSubview(self.dictionaryTooltipLabel)
        panel.contentView = content
        return panel
    }()
    var showCandidateIndex = false

    override func updateCandidatePresentations(_ candidates: [CandidatePresentation], selectionIndex: Int?, cursorLocation: CGPoint) {
        self.showedRows = selectionIndex == nil ? 0...8 : self.showedRows
        super.updateCandidatePresentations(
            candidates,
            selectionIndex: selectionIndex,
            cursorLocation: cursorLocation
        )
        if !self.showCandidateIndex || selectionIndex == nil || candidates.isEmpty {
            self.cancelDictionarySelection()
        } else {
            self.updateDictionaryTooltip()
        }
    }

    private func scheduleDictionarySelection(for row: Int) {
        guard self.showCandidateIndex, self.candidates.indices.contains(row) else {
            self.cancelDictionarySelection()
            return
        }
        let text = self.candidates[row].candidate.text
        if self.dictionarySelection?.row == row, self.dictionarySelection?.text == text {
            return
        }
        self.cancelDictionarySelection()
        self.dictionarySelection = (row, text)
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dictionarySelectionTimer = nil
                self?.updateDictionaryTooltip()
            }
        }
        self.dictionarySelectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateDictionaryTooltip() {
        guard self.dictionarySelectionTimer == nil,
              let selection = self.dictionarySelection,
              selection.row == self.currentSelectedRow,
              self.candidates.indices.contains(selection.row),
              self.candidates[selection.row].candidate.text == selection.text,
              let window = self.view.window, window.isVisible, let screen = window.screen,
              let definition = self.dictionaryDefinition(for: selection.text) else {
            self.hideDictionaryTooltip()
            return
        }
        let rowFrame = self.tableView.rect(ofRow: selection.row)
        let anchor = window.convertToScreen(self.tableView.convert(rowFrame, to: nil))
        let label = self.dictionaryTooltipLabel
        let panel = self.dictionaryTooltipWindow
        if self.displayedDefinition != definition {
            self.displayedDefinition = definition
            label.stringValue = definition
            let textWidth: CGFloat = 300
            let textSize = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 1000)) ?? .zero
            label.frame = NSRect(x: 10, y: 8, width: textWidth, height: ceil(textSize.height))
            panel.setContentSize(NSSize(width: textWidth + 20, height: label.frame.height + 16))
        }
        let bounds = screen.visibleFrame
        let size = panel.frame.size
        let x = window.frame.maxX + 6 + size.width <= bounds.maxX
            ? window.frame.maxX + 6 : window.frame.minX - size.width - 6
        let y = anchor.midY - size.height / 2
        let origin = NSPoint(x: max(bounds.minX, x), y: max(bounds.minY, min(y, bounds.maxY - size.height)))
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFrontRegardless()
        }
    }

    private func hideDictionaryTooltip() {
        guard self.displayedDefinition != nil else { return }
        self.displayedDefinition = nil
        if let parent = self.dictionaryTooltipWindow.parent {
            parent.removeChildWindow(self.dictionaryTooltipWindow)
        }
        self.dictionaryTooltipWindow.orderOut(nil)
    }

    private func cancelDictionarySelection() {
        self.dictionarySelectionTimer?.invalidate()
        self.dictionarySelectionTimer = nil
        self.dictionarySelection = nil
        self.hideDictionaryTooltip()
    }

    override internal func updateSelectionCallback(_ row: Int) {
        delegate?.candidateSelectionChanged(row)
        self.scheduleDictionarySelection(for: row)

        if !self.showedRows.contains(row) {
            if row < self.showedRows.lowerBound {
                self.showedRows = row...(row + 8)
            } else {
                self.showedRows = (row - 8)...row
            }
        }
    }

    override internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        let candidate = self.candidates[row].candidate
        let annotationText = self.candidates[row].displayContext.annotationText
        let isWithinShowedRows = self.showedRows.contains(row)
        let displayIndex = row - self.showedRows.lowerBound + 1 // showedRowsの下限からの相対的な位置
        let displayText: String

        if isWithinShowedRows && self.showCandidateIndex {
            if displayIndex > 9 {
                displayText = " " + candidate.text // 行番号が10以上の場合、インデントを調整
            } else {
                displayText = "\(displayIndex). " + candidate.text
            }
        } else {
            displayText = candidate.text // showedRowsの範囲外では番号を付けない
        }

        // 数字部分と候補部分を別々に設定
        let attributedString = NSMutableAttributedString(string: displayText)
        let numberRange = (displayText as NSString).range(of: "\(displayIndex).")

        if numberRange.location != NSNotFound {
            attributedString.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
                .foregroundColor: currentSelectedRow == row ? NSColor.white : NSColor.gray,
                .baselineOffset: 2
            ], range: numberRange)
        }

        cell.candidateTextField.attributedStringValue = attributedString

        if let annotationText {
            let annotationString = NSAttributedString(
                string: annotationText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: currentSelectedRow == row ? NSColor.white : NSColor.systemGray
                ]
            )
            cell.showCandidateAnnotationTextField(true)
            cell.candidateAnnotationTextField.attributedStringValue = annotationString
        } else {
            cell.showCandidateAnnotationTextField(false)
            cell.candidateAnnotationTextField.stringValue = ""
        }
        let definition = self.dictionaryDefinition(for: candidate.text)
        cell.showDictionaryDefinition(definition, isSelected: self.currentSelectedRow == row)
    }

    private func dictionaryDefinition(for text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let key = text as NSString
        if let cached = self.dictionaryDefinitions.object(forKey: key) {
            return cached.length == 0 ? nil : cached as String
        }
        guard self.pendingDictionaryLookups.insert(text).inserted else { return nil }
        self.dictionaryQueue.async { [weak self] in
            let range = CFRange(location: 0, length: text.utf16.count)
            let definition = DCSCopyTextDefinition(nil, text as CFString, range)?.takeRetainedValue() as String?
            let trimmed = definition?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tooltip = trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingDictionaryLookups.remove(text)
                self.dictionaryDefinitions.setObject(tooltip as NSString, forKey: text as NSString)
                if self.view.window?.isVisible == true {
                    self.updateVisibleRows()
                    if self.dictionarySelection?.text == text {
                        self.updateDictionaryTooltip()
                    }
                }
            }
        }
        return nil
    }

    func getNumberCandidate(num: Int) -> Int {
        let nextRow = self.showedRows.lowerBound + num - 1
        return nextRow
    }

    func hide() {
        self.cancelDictionarySelection()
        self.currentSelectedRow = -1
        self.showedRows = 0...8
    }

    override var numberOfVisibleRows: Int {
        min(9, self.tableView.numberOfRows)
    }

    override func getWindowWidth(maxContentWidth: CGFloat) -> CGFloat {
        let hasAnnotation = self.candidates.contains { $0.displayContext.annotationText != nil }
        let extraWidth = CandidateTableCellView.dictionaryIconSpace + (hasAnnotation ? 56 : 0)
        if self.showCandidateIndex {
            return maxContentWidth + 48 + extraWidth
        } else {
            return maxContentWidth + 20 + extraWidth
        }
    }
}

class PredictionCandidatesViewController: BaseCandidateViewController {
    private let prefixTabStop: CGFloat = 24
    private let prefixSymbolName = "arrow.forward.to.line.compact"
    private let prefixFontSize: CGFloat = 12

    override var numberOfVisibleRows: Int {
        min(3, self.tableView.numberOfRows)
    }

    override internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        let candidateText = candidates[row].candidate.text
        let attributedString = NSMutableAttributedString()

        let isSelected = currentSelectedRow == row
        let candidateColor = isSelected ? NSColor.white : NSColor.labelColor

        if let symbol = NSImage(systemSymbolName: prefixSymbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: prefixFontSize, weight: .regular)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let attachment = NSTextAttachment()
            attachment.image = configured
            attachment.bounds = NSRect(x: 0, y: -2, width: prefixFontSize + 2, height: prefixFontSize + 2)
            attributedString.append(NSAttributedString(attachment: attachment))
        }
        attributedString.append(NSAttributedString(string: "\t"))
        let candidateAttributed = NSAttributedString(
            string: candidateText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: candidateColor
            ]
        )
        attributedString.append(candidateAttributed)

        let fullRange = NSRange(location: 0, length: attributedString.length)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: prefixTabStop, options: [:])
        ]
        paragraphStyle.defaultTabInterval = prefixTabStop
        attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        cell.candidateTextField.attributedStringValue = attributedString
    }

    override func getWindowWidth(maxContentWidth: CGFloat) -> CGFloat {
        maxContentWidth + prefixTabStop + 20
    }
}
