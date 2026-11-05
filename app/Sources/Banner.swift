// On-screen banners: a small floating card when a session needs your input or finishes,
// saying which session and what it's waiting for. Click to open it, × to dismiss it.
//
// Banners are occasional, so they get a short entrance (opacity plus an 8 pt slide, ease-out,
// 200 ms) and a faster exit (150 ms). With Reduce Motion on they only fade. A banner waits
// while the pointer is over it, and goes away by itself once the session no longer needs you.

import AppKit

/// The card's contents. Also used by --snapshot-banner.
final class BannerView: NSView {
    static let size = NSSize(width: 340, height: 66)

    private let onOpen: () -> Void
    private let onDismiss: () -> Void
    var onHoverChange: ((Bool) -> Void)?

    init(session s: SessionState, onOpen: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        super.init(frame: NSRect(origin: .zero, size: Self.size))

        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        let needs = s.status == .needsInput
        let icon = NSImageView(frame: NSRect(x: 14, y: (Self.size.height - 22) / 2, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: needs ? "exclamationmark.bubble.fill" : "checkmark.bubble.fill",
                             accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = needs ? .systemRed : .secondaryLabelColor

        let caption = NSTextField(labelWithString: needs ? "Needs your input" : "Ready for your reply")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = needs ? .systemRed : .secondaryLabelColor
        caption.frame = NSRect(x: 46, y: 42, width: 250, height: 14)

        let title = NSTextField(labelWithString: s.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 46, y: 24, width: 250, height: 17)

        let detail = NSTextField(labelWithString: needs ? (s.message ?? "Claude is waiting for you") : "Claude finished a reply")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 46, y: 8, width: 250, height: 15)

        let close = NSButton(frame: NSRect(x: Self.size.width - 32, y: (Self.size.height - 22) / 2, width: 22, height: 22))
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        close.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        close.imagePosition = .imageOnly
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        close.toolTip = "Dismiss (done with this session)"

        [icon, caption, title, detail, close].forEach(addSubview)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(caption.stringValue): \(s.title). \(detail.stringValue)")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Dismiss") { [weak self] in
            self?.onDismiss(); return true
        }])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onOpen() }
    }
    override func accessibilityPerformPress() -> Bool { onOpen(); return true }
    @objc private func closeTapped() { onDismiss() }
}

/// Shows, stacks, times out and removes banners. At most three are on screen; a newer one
/// for the same session replaces the old one.
@MainActor
final class BannerCenter {
    private final class Entry {
        let id: String
        let panel: NSPanel
        var timer: Timer?
        var hovering = false
        init(id: String, panel: NSPanel) { self.id = id; self.panel = panel }
    }

    private var entries: [Entry] = []      // newest first
    private let maxVisible = 3
    private let gap: CGFloat = 8, margin: CGFloat = 12
    var config: () -> Config = { Config.load() }
    var onOpen: (SessionState) -> Void = { _ in }
    var onDismiss: (SessionState) -> Void = { _ in }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(_ s: SessionState) {
        remove(id: s.id, animated: false)
        let c = config()

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: BannerView.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let entry = Entry(id: s.id, panel: panel)
        let view = BannerView(session: s,
                              onOpen: { [weak self] in self?.remove(id: s.id, animated: true); self?.onOpen(s) },
                              onDismiss: { [weak self] in self?.remove(id: s.id, animated: true); self?.onDismiss(s) })
        view.onHoverChange = { [weak self, weak entry] on in
            guard let self, let entry else { return }
            entry.hovering = on
            if on { entry.timer?.invalidate() } else { self.schedule(entry, seconds: c.bannerSeconds) }
        }
        panel.contentView = view

        entries.insert(entry, at: 0)
        while entries.count > maxVisible, let oldest = entries.last { remove(id: oldest.id, animated: true) }

        let target = frame(at: 0, position: c.bannerPosition)
        let fromTop = c.bannerPosition != .bottomRight
        panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: fromTop ? 8 : -8), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        relayout(skipNewest: true)
        schedule(entry, seconds: c.bannerSeconds)
    }

    /// Removes the banner for a session (for example after you reply to it).
    func remove(id: String, animated: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: i)
        entry.timer?.invalidate()
        let panel = entry.panel
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
        relayout(skipNewest: false)
    }

    func removeAll() { entries.map(\.id).forEach { remove(id: $0, animated: false) } }

    var visibleIDs: [String] { entries.map(\.id) }

    private func schedule(_ entry: Entry, seconds: Int) {
        entry.timer?.invalidate()
        guard seconds > 0, !entry.hovering else { return }
        entry.timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self, weak entry] _ in
            MainActor.assumeIsolated {
                guard let self, let entry else { return }
                self.remove(id: entry.id, animated: true)
            }
        }
    }

    private func relayout(skipNewest: Bool) {
        let position = config().bannerPosition
        for (i, e) in entries.enumerated() where !(skipNewest && i == 0) {
            let target = frame(at: i, position: position)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduceMotion ? 0 : 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
                e.panel.animator().setFrame(target, display: true)
            }
        }
    }

    /// Where the banner at stack position `index` goes, on the screen with the menu bar.
    private func frame(at index: Int, position: Config.BannerPosition) -> NSRect {
        let screen = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = BannerView.size
        let step = CGFloat(index) * (size.height + gap)
        switch position {
        case .topRight:
            return NSRect(x: screen.maxX - size.width - margin, y: screen.maxY - size.height - margin - step, width: size.width, height: size.height)
        case .topCenter:
            return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - margin - step, width: size.width, height: size.height)
        case .bottomRight:
            return NSRect(x: screen.maxX - size.width - margin, y: screen.minY + margin + step, width: size.width, height: size.height)
        }
    }
}
