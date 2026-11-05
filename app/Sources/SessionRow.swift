// A menu row for one waiting session: icon, title, subtitle, and an × that dismisses just that
// session when you're done with it. Clicking anywhere else on the row opens the session.
//
// Menu items with a custom view lose the native highlight, so the row draws the standard
// rounded selection itself and switches its text to the selected-menu colors.
//
// Only one row is ever highlighted. While a menu is open, AppKit can drop a row's mouse-exited
// event when the pointer moves quickly, so rows don't decide on their own: `SessionRowView.highlight(_:)`
// is the single source of truth, fed by the menu delegate's willHighlight (authoritative) and by
// each row's mouse-entered (immediate). Closing the menu clears it.

import AppKit

final class SessionRowView: NSView {
    private let onOpen: () -> Void
    private let onDismiss: () -> Void
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let dismiss = NSButton()
    private let iconTint: NSColor
    private var hovering = false {
        didSet { guard hovering != oldValue else { return }; needsDisplay = true; applyColors() }
    }

    static let height: CGFloat = 40

    /// The one highlighted row, if any.
    private static weak var current: SessionRowView?

    /// Highlights `row` and un-highlights every other row. Pass nil to clear.
    static func highlight(_ row: SessionRowView?) {
        guard current !== row else { return }
        current?.hovering = false
        current = row
        row?.hovering = true
    }

    init(title titleText: String, subtitle subtitleText: String, symbol: String, iconTint: NSColor = .secondaryLabelColor,
         onOpen: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        self.iconTint = iconTint
        let titleWidth = (titleText as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
        super.init(frame: NSRect(x: 0, y: 0, width: min(400, max(300, ceil(titleWidth) + 90)), height: Self.height))
        autoresizingMask = [.width]

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)

        title.stringValue = titleText
        title.font = .menuFont(ofSize: 0)
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true

        subtitle.stringValue = subtitleText
        subtitle.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingTail

        dismiss.isBordered = false
        dismiss.bezelStyle = .regularSquare
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismiss.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        dismiss.imagePosition = .imageOnly
        dismiss.target = self
        dismiss.action = #selector(dismissTapped)
        dismiss.toolTip = "Dismiss (done with this session)"
        dismiss.setAccessibilityLabel("Dismiss \(titleText)")

        [icon, title, subtitle, dismiss].forEach(addSubview)
        applyColors()

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(titleText), \(subtitleText)")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Dismiss") { [weak self] in
            self?.dismissTapped(); return true
        }])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 14, y: (Self.height - 16) / 2, width: 16, height: 16)
        dismiss.frame = NSRect(x: w - 34, y: (Self.height - 22) / 2, width: 22, height: 22)
        let textX: CGFloat = 38, textW = w - textX - 40
        title.frame = NSRect(x: textX, y: 19, width: textW, height: 17)
        subtitle.frame = NSRect(x: textX, y: 4, width: textW, height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { Self.highlight(self) }
    override func mouseExited(with event: NSEvent) { if Self.current === self { Self.highlight(nil) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, Self.current === self { Self.highlight(nil) }   // menu closed or rebuilt
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), !dismiss.frame.contains(p) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onOpen()
    }

    override func accessibilityPerformPress() -> Bool {
        enclosingMenuItem?.menu?.cancelTracking()
        onOpen()
        return true
    }

    @objc private func dismissTapped() {
        Self.highlight(nil)
        onDismiss()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    private func applyColors() {
        let selected = NSColor.selectedMenuItemTextColor
        title.textColor = hovering ? selected : .labelColor
        subtitle.textColor = hovering ? selected.withAlphaComponent(0.8) : .secondaryLabelColor
        icon.contentTintColor = hovering ? selected : iconTint
        dismiss.contentTintColor = hovering ? selected : .tertiaryLabelColor
    }

    /// For snapshots: draw the row as if the pointer were over it, without touching the shared highlight.
    func setHovering(_ on: Bool) { hovering = on }
}
