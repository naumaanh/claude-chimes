// On-screen banners: a small floating card when a session needs your input or finishes,
// saying which session and what it's waiting for. Click to open it, × to dismiss it.
//
// Banners are occasional, so they get a short entrance (opacity plus an 8 pt slide, ease-out,
// 200 ms) and a faster exit (150 ms). With Reduce Motion on they only fade. A banner waits
// while the pointer is over it, and goes away by itself once the session no longer needs you.

import AppKit

/// The card's contents. Also used by --snapshot-banner.
final class BannerView: NSView {
    static let width: CGFloat = 360
    /// The height a banner had before 1.8, and still has with nothing extra to say.
    static let size = NSSize(width: width, height: 66)

    private let onOpen: () -> Void
    private let onDismiss: () -> Void
    var onHoverChange: ((Bool) -> Void)?

    /**
     The banner's lines, top to bottom: what happened, the session, what it is about (the
     command or question it waits on, the error, or a summary of the turn: Claude's own recap
     where the app wrote one, up to three lines, else the start of the reply), the question
     Claude left you if any, then small facts (how long, how full the context is, which
     folder). The card is as tall as that.
     */
    init(session s: SessionState, preview: Bool = true, onOpen: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        let needsInput = s.status == .needsInput, didFail = s.isFailed
        let body: String = needsInput ? (s.message ?? "Claude is waiting for you")
            : didFail ? (s.message ?? "Claude hit an error")
            : (preview ? s.reply : nil) ?? "Claude finished a reply"   // the time is in the facts line
        // A question at the end of a turn is the thing to act on, so it gets its own line.
        let ask = (!needsInput && !didFail && preview) ? s.ask : nil
        var facts: [String] = []
        if !needsInput, let t = s.turnSeconds { facts.append(BannerView.duration(t)) }
        if s.remoteHost == nil, let c = ContextUse.label(s.transcriptPath) { facts.append(c) }
        let folder = s.cwd.isEmpty ? "" : URL(fileURLWithPath: s.cwd).lastPathComponent
        if !folder.isEmpty, folder != "/", !s.title.localizedCaseInsensitiveContains(folder) { facts.append(folder) }
        let layout = Layout(body: body, ask: ask, facts: facts.joined(separator: " · "),
                            maxLines: s.replyIsRecap == true && !needsInput ? 3 : 2)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: layout.height))
        build(s, layout: layout, needs: needsInput, failed: didFail)
    }

    /// Where each line goes, measured before the view exists so the card can be sized to fit.
    struct Layout {
        let body: String
        let ask: String?
        let facts: String
        let maxLines: Int
        let bodyHeight: CGFloat
        let askHeight: CGFloat
        let height: CGFloat
        static let textWidth: CGFloat = 270
        static let bodyFont = NSFont.systemFont(ofSize: 12.5)
        static let lineSpacing: CGFloat = 2
        /// Near-black in light mode, near-white in dark. Built per appearance, because a
        /// system color with an alpha applied is fixed to whichever appearance was current.
        static let bodyColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.8)
        }

        /// The body's text, near-black and with a little air between its two lines: it is
        /// the line that says whether to look now, so it reads first after the title.
        static func bodyText(_ body: String) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: body, attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: style,
            ])
        }

        static let askFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

        /// The height of `lines` lines of body text, with the spacing between them.
        static func height(lines: Int, font: NSFont) -> CGFloat {
            let line = ceil(font.ascender - font.descender + font.leading) + 1
            return line * CGFloat(lines) + lineSpacing * CGFloat(max(0, lines - 1))
        }

        static func lines(_ text: NSAttributedString, font: NSFont, max: Int) -> Int {
            let line = ceil(font.ascender - font.descender + font.leading) + 1
            let measured = text.boundingRect(with: NSSize(width: textWidth, height: 1000),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            return min(max, Swift.max(1, Int(((measured + lineSpacing) / (line + lineSpacing)).rounded(.up))))
        }

        init(body: String, ask: String?, facts: String, maxLines: Int = 2) {
            self.body = body
            self.ask = ask
            self.facts = facts
            self.maxLines = maxLines
            bodyHeight = Self.height(lines: Self.lines(Self.bodyText(body), font: Self.bodyFont, max: maxLines), font: Self.bodyFont)
            askHeight = ask.map { Self.height(lines: Self.lines(Self.askText($0), font: Self.askFont, max: 2), font: Self.askFont) + 4 } ?? 0
            // 8 top, caption 14, title 17, body, the question, facts 13 with a 6 pt gap, 9 bottom.
            height = 8 + 14 + 18 + bodyHeight + askHeight + (facts.isEmpty ? 0 : 20) + 9
        }

        /// The question Claude left you, in the accent color: the one thing to do next.
        static func askText(_ ask: String) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: ask, attributes: [
                .font: askFont, .foregroundColor: NSColor.controlAccentColor, .paragraphStyle: style,
            ])
        }
    }

    private func build(_ s: SessionState, layout: Layout, needs: Bool, failed: Bool) {
        let height = layout.height

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

        // The glass alone lets a busy window behind show through the text. A partly opaque
        // wash in the window color keeps the material's look but steadies the contrast.
        backing.frame = blur.bounds
        backing.autoresizingMask = [.width, .height]
        backing.wantsLayer = true
        blur.addSubview(backing)
        updateBacking()

        // The icon sits beside the caption and title, where the eye starts, not mid-card.
        let icon = NSImageView(frame: NSRect(x: 14, y: height - 8 - 32, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: needs ? "exclamationmark.bubble.fill"
                                : failed ? "exclamationmark.triangle.fill" : "checkmark.bubble.fill",
                             accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        let asks = layout.ask != nil
        let tint: NSColor = needs ? .systemRed : failed ? .systemOrange : asks ? .controlAccentColor : .secondaryLabelColor
        icon.contentTintColor = tint
        if asks { icon.image = NSImage(systemSymbolName: "questionmark.bubble.fill", accessibilityDescription: nil) }

        let what = needs ? "Needs your input" : failed ? "Turn failed" : asks ? "Waiting on your answer" : "Ready for your reply"
        let caption = NSTextField(labelWithString: s.remoteHost.map { "\(what) · on \($0)" } ?? what)
        caption.lineBreakMode = .byTruncatingTail
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = tint
        caption.frame = NSRect(x: 46, y: height - 8 - 14, width: Layout.textWidth, height: 14)

        let title = NSTextField(labelWithString: s.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 46, y: height - 8 - 14 - 18, width: Layout.textWidth, height: 17)

        let detail = NSTextField(wrappingLabelWithString: layout.body)
        detail.attributedStringValue = Layout.bodyText(layout.body)
        detail.maximumNumberOfLines = layout.maxLines
        // Word wrap with the last line cut: truncating-tail mode would hold it to one line.
        detail.lineBreakMode = .byWordWrapping
        detail.cell?.truncatesLastVisibleLine = true
        detail.frame = NSRect(x: 46, y: height - 8 - 14 - 18 - layout.bodyHeight, width: Layout.textWidth, height: layout.bodyHeight)

        let question = NSTextField(wrappingLabelWithString: layout.ask ?? "")
        question.attributedStringValue = Layout.askText(layout.ask ?? "")
        question.maximumNumberOfLines = 2
        question.lineBreakMode = .byWordWrapping
        question.cell?.truncatesLastVisibleLine = true
        question.frame = NSRect(x: 46, y: detail.frame.minY - layout.askHeight,
                                width: Layout.textWidth, height: max(0, layout.askHeight - 4))
        question.isHidden = layout.ask == nil

        let facts = NSTextField(labelWithString: layout.facts)
        facts.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        facts.textColor = .secondaryLabelColor
        facts.lineBreakMode = .byTruncatingTail
        facts.frame = NSRect(x: 46, y: 9, width: Layout.textWidth, height: 14)
        facts.isHidden = layout.facts.isEmpty

        let close = NSButton(frame: NSRect(x: Self.width - 32, y: height - 8 - 26, width: 22, height: 22))
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        close.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        close.imagePosition = .imageOnly
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        close.toolTip = "Dismiss (done with this session)"

        [icon, caption, title, detail, question, facts, close].forEach(addSubview)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(caption.stringValue): \(s.title). \(layout.body)" + (layout.ask.map { " \($0)" } ?? "")
                              + (layout.facts.isEmpty ? "" : ". \(layout.facts)"))
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Dismiss") { [weak self] in
            self?.onDismiss(); return true
        }])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private let backing = NSView()

    /// Layer colors don't follow light and dark mode by themselves, so resolve it again
    /// whenever the appearance changes.
    private func updateBacking() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backing.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBacking()
    }

    /// "45 s", "3 min", "1 hr 5 min".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) hr" + (s % 3600 >= 60 ? " \((s % 3600) / 60) min" : "")
    }

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

        let view = BannerView(session: s, preview: c.bannerPreview,
                              onOpen: { [weak self] in self?.remove(id: s.id, animated: true); self?.onOpen(s) },
                              onDismiss: { [weak self] in self?.remove(id: s.id, animated: true); self?.onDismiss(s) })
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
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

    /**
     Closes the banner after `seconds` of you being at the Mac. A banner that times out
     while you're away was never seen, so the countdown only runs while you're using the
     Mac: when it ends with no keyboard or mouse input for a while, it waits and checks again.
     */
    private func schedule(_ entry: Entry, seconds: Int) {
        entry.timer?.invalidate()
        guard seconds > 0, !entry.hovering else { return }
        entry.timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self, weak entry] _ in
            MainActor.assumeIsolated {
                guard let self, let entry else { return }
                if BannerCenter.idleSeconds() > BannerCenter.awayAfter {
                    // Away: look again soon, and give the full time once input resumes.
                    self.waitForReturn(entry, seconds: seconds)
                } else {
                    self.remove(id: entry.id, animated: true)
                }
            }
        }
    }

    /// No keyboard or mouse input for this long means you're not looking at the screen.
    static let awayAfter: TimeInterval = 10

    /// Seconds since the last keyboard or mouse input anywhere on the Mac.
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func waitForReturn(_ entry: Entry, seconds: Int) {
        entry.timer?.invalidate()
        entry.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak entry] timer in
            MainActor.assumeIsolated {
                guard let self, let entry else { timer.invalidate(); return }
                guard BannerCenter.idleSeconds() < 2 else { return }
                timer.invalidate()
                self.schedule(entry, seconds: seconds)   // back: the full time to read it
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
    /// Banners differ in height since 1.8, so each one moves past the ones before it.
    private func frame(at index: Int, position: Config.BannerPosition) -> NSRect {
        let screen = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = index < entries.count ? entries[index].panel.frame.size : BannerView.size
        let step = entries.prefix(index).reduce(CGFloat(0)) { $0 + $1.panel.frame.height + gap }
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
