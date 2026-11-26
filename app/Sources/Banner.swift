// On-screen banners: a small floating card when a session needs your input or finishes,
// saying which session and what it's waiting for. Click to open it, × to dismiss it.
//
// Banners are occasional, so they get a short entrance (opacity plus an 8 pt slide, ease-out,
// 200 ms) and a faster exit (150 ms). With Reduce Motion on they only fade. A banner waits
// while the pointer is over it, and goes away by itself once the session no longer needs you.

import AppKit

/**
 What a banner says, worked out before anything is drawn: the verdict first (does this need
 you, and for what), then the session, one line of status, the question or the buttons that
 answer it, what the turn actually did, and small facts.
 */
struct BannerCard {
    enum Style { case body, ask, receipt, facts }
    struct Line { let text: String; let style: Style; let maxLines: Int }

    var symbol: String
    var tint: NSColor
    var caption: String
    var title: String
    var lines: [Line] = []
    /// Allow once and Deny, for a permission prompt the banner may answer.
    var decides = false

    init(session s: SessionState, preview: Bool = true) {
        let needs = s.status == .needsInput, failed = s.isFailed
        let permission = needs && (s.askedVia?.contains("permission") == true || (s.message ?? "").hasPrefix("Claude wants"))
        let ask = (!needs && !failed && preview) ? s.ask : nil
        if needs {
            symbol = permission ? "hand.raised.fill" : "exclamationmark.bubble.fill"
            tint = .systemRed
            caption = permission ? "Needs your permission" : "Needs your answer"
        } else if failed {
            symbol = "exclamationmark.triangle.fill"; tint = .systemOrange; caption = "Turn failed"
        } else if ask != nil {
            symbol = "questionmark.bubble.fill"; tint = .controlAccentColor; caption = "Needs your decision"
        } else {
            symbol = "checkmark.circle.fill"; tint = .systemGreen; caption = "Done · nothing needs you"
        }
        if let host = s.remoteHost { caption += " · on \(host)" }
        title = s.title

        // One line of status: the recap's first sentence, the command, or the error.
        let status: String = needs ? (s.message ?? "Claude is waiting for you")
            : failed ? (s.message ?? "Claude hit an error")
            : (preview ? s.reply.map(ReplyPreview.headline) : nil) ?? "Claude finished a reply"
        lines.append(Line(text: status, style: .body, maxLines: 2))
        if let ask { lines.append(Line(text: ask, style: .ask, maxLines: 2)) }
        decides = needs && s.decisionToken != nil && !s.isRemote
        if let receipt = s.receipt, !needs { lines.append(Line(text: receipt, style: .receipt, maxLines: 1)) }

        var facts: [String] = []
        if !needs, let t = s.turnSeconds { facts.append(BannerView.duration(t)) }
        if s.remoteHost == nil, let c = ContextUse.label(s.transcriptPath) { facts.append(c) }
        let folder = s.cwd.isEmpty ? "" : URL(fileURLWithPath: s.cwd).lastPathComponent
        if !folder.isEmpty, folder != "/", !s.title.localizedCaseInsensitiveContains(folder) { facts.append(folder) }
        if !facts.isEmpty { lines.append(Line(text: facts.joined(separator: " · "), style: .facts, maxLines: 1)) }
    }

    /// One card for several sessions that arrived together: "1 needs you · 2 done".
    init(digest sessions: [SessionState]) {
        let needing = sessions.filter { $0.status == .needsInput || $0.isFailed || $0.ask != nil }
        symbol = needing.isEmpty ? "checkmark.circle.fill" : "square.stack.fill"
        tint = needing.isEmpty ? .systemGreen : .systemRed
        caption = "\(sessions.count) sessions"
        let done = sessions.count - needing.count
        title = [needing.isEmpty ? nil : "\(needing.count) need\(needing.count == 1 ? "s" : "") you",
                 done == 0 ? nil : "\(done) done"].compactMap { $0 }.joined(separator: " · ")
        // Most urgent first, one line each.
        for s in (needing + sessions.filter { !needing.map(\.id).contains($0.id) }).prefix(4) {
            let what = BannerCard(session: s).caption.components(separatedBy: " · ").first ?? ""
            lines.append(Line(text: "\(s.title) — \(what)", style: needing.contains { $0.id == s.id } ? .body : .receipt, maxLines: 1))
        }
        if sessions.count > 4 { lines.append(Line(text: "and \(sessions.count - 4) more", style: .facts, maxLines: 1)) }
    }
}

/// The card's view. Also used by --snapshot-banner.
final class BannerView: NSView {
    static let width: CGFloat = 360
    /// The smallest a banner gets: a caption, a title and one line.
    static let size = NSSize(width: width, height: 66)
    static let textX: CGFloat = 46
    static let textWidth: CGFloat = 280
    static let lineSpacing: CGFloat = 2

    private let onOpen: () -> Void
    private let onDismiss: () -> Void
    var onHoverChange: ((Bool) -> Void)?
    /// Allow once / Deny. Set by the banner center for a card that `decides`.
    var onDecide: ((String) -> Void)?

    convenience init(session s: SessionState, preview: Bool = true, onOpen: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.init(card: BannerCard(session: s, preview: preview), onOpen: onOpen, onDismiss: onDismiss)
    }

    init(card: BannerCard, onOpen: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        let measured = card.lines.map { Self.height(of: $0) }
        let buttons: CGFloat = card.decides ? 30 : 0
        let body = zip(card.lines, measured).reduce(CGFloat(0)) { $0 + $1.1 + Self.gap(before: $1.0.style) }
        let height = max(Self.size.height, 8 + 14 + 18 + body + buttons + 10)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        build(card, heights: measured)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Text

    static func font(_ style: BannerCard.Style) -> NSFont {
        switch style {
        case .body: return .systemFont(ofSize: 12.5)
        case .ask: return .systemFont(ofSize: 12.5, weight: .medium)
        case .receipt: return .systemFont(ofSize: 11.5, weight: .medium)
        case .facts: return .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
    }

    /// Near-black in light mode, near-white in dark. Built per appearance, because a system
    /// color with an alpha applied is fixed to whichever appearance was current.
    static func strong(_ alpha: (light: CGFloat, dark: CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: alpha.dark) : NSColor(white: 0, alpha: alpha.light)
        }
    }

    static func color(_ style: BannerCard.Style) -> NSColor {
        switch style {
        case .body: return strong((0.8, 0.85))
        case .ask: return .controlAccentColor
        case .receipt: return strong((0.62, 0.7))
        case .facts: return .secondaryLabelColor
        }
    }

    static func text(_ line: BannerCard.Line) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: line.text, attributes: [
            .font: font(line.style), .foregroundColor: color(line.style), .paragraphStyle: style,
        ])
    }

    /// The height a line of the card needs, up to its `maxLines`.
    static func height(of line: BannerCard.Line) -> CGFloat {
        let f = font(line.style)
        let one = ceil(f.ascender - f.descender + f.leading) + 1
        let measured = text(line).boundingRect(with: NSSize(width: textWidth, height: 1000),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let count = min(line.maxLines, max(1, Int(((measured + lineSpacing) / (one + lineSpacing)).rounded(.up))))
        return one * CGFloat(count) + lineSpacing * CGFloat(count - 1)
    }

    /// Space above a line: the question and the receipt stand a little apart from the status.
    static func gap(before style: BannerCard.Style) -> CGFloat {
        switch style {
        case .body: return 0
        case .ask, .receipt: return 4
        case .facts: return 3
        }
    }

    // MARK: Building

    private let backing = NSView()

    private func build(_ card: BannerCard, heights: [CGFloat]) {
        let height = bounds.height

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

        // The icon sits beside the caption and title, where the eye starts.
        let icon = NSImageView(frame: NSRect(x: 14, y: height - 8 - 32, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: card.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = card.tint
        addSubview(icon)

        let caption = NSTextField(labelWithString: card.caption)
        caption.lineBreakMode = .byTruncatingTail
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = card.tint
        caption.frame = NSRect(x: Self.textX, y: height - 8 - 14, width: Self.textWidth, height: 14)
        addSubview(caption)

        let title = NSTextField(labelWithString: card.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: Self.textX, y: height - 8 - 14 - 18, width: Self.textWidth, height: 17)
        addSubview(title)

        var y = height - 8 - 14 - 18
        var spoken: [String] = [card.caption, card.title]
        for (line, h) in zip(card.lines, heights) {
            y -= Self.gap(before: line.style) + h
            let field = NSTextField(wrappingLabelWithString: line.text)
            field.attributedStringValue = Self.text(line)
            field.maximumNumberOfLines = line.maxLines
            // Word wrap with the last line cut: truncating-tail mode would hold it to one line.
            field.lineBreakMode = .byWordWrapping
            field.cell?.truncatesLastVisibleLine = true
            field.frame = NSRect(x: Self.textX, y: y, width: Self.textWidth, height: h)
            addSubview(field)
            spoken.append(line.text)
            // The buttons go right under the status line they answer.
            if card.decides, line.style == .body, spoken.count == 3 {
                y -= 30
                addButtons(y: y + 2)
            }
        }

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
        addSubview(close)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(spoken.joined(separator: ". "))
        var actions = [NSAccessibilityCustomAction(name: "Dismiss") { [weak self] in self?.onDismiss(); return true }]
        if card.decides {
            actions.append(NSAccessibilityCustomAction(name: "Allow once") { [weak self] in self?.onDecide?("allow"); return true })
            actions.append(NSAccessibilityCustomAction(name: "Deny") { [weak self] in self?.onDecide?("deny"); return true })
        }
        setAccessibilityCustomActions(actions)
    }

    /// Deny on the left and Allow once on the right, the way macOS lays out a dialog. Neither
    /// is the default: a stray Return or click elsewhere on the card never approves anything.
    private func addButtons(y: CGFloat) {
        let deny = NSButton(title: "Deny", target: self, action: #selector(denyTapped))
        let allow = NSButton(title: "Allow once", target: self, action: #selector(allowTapped))
        for (button, x, w) in [(deny, Self.textX, CGFloat(80)), (allow, Self.textX + 88, CGFloat(100))] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.frame = NSRect(x: x - 6, y: y, width: w, height: 26)
            button.keyEquivalent = ""
            addSubview(button)
        }
        allow.bezelColor = .controlAccentColor
        allow.toolTip = "Allow this one request. No rule is added."
    }

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
    @objc private func allowTapped() { onDecide?("allow") }
    @objc private func denyTapped() { onDecide?("deny") }
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
        /// The sessions on this card: one, or several for the digest.
        var sessions: [SessionState]
        /// It has Allow/Deny: it never folds into the digest, and it never times out.
        let decides: Bool
        init(id: String, panel: NSPanel, sessions: [SessionState], decides: Bool) {
            self.id = id; self.panel = panel; self.sessions = sessions; self.decides = decides
        }
    }

    static let digestID = "digest"

    private var entries: [Entry] = []      // newest first
    private let maxVisible = 3
    private let gap: CGFloat = 8, margin: CGFloat = 12
    var config: () -> Config = { Config.load() }
    var onOpen: (SessionState) -> Void = { _ in }
    var onDismiss: (SessionState) -> Void = { _ in }
    /// Allow once or Deny on a permission banner: the session and "allow" or "deny".
    var onDecide: (SessionState, String) -> Void = { _, _ in }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /**
     Shows a session's banner. A third ordinary banner arriving while two are up folds all of
     them into one digest card ("1 needs you · 2 done"), and later ones join it. Permission
     banners with buttons always stand alone, since they wait on you.
     */
    func show(_ s: SessionState) {
        remove(id: s.id, animated: false)
        let c = config()
        let card = BannerCard(session: s, preview: c.bannerPreview)
        let plain = entries.filter { !$0.decides && $0.id != Self.digestID }
        if !card.decides, let digest = entries.first(where: { $0.id == Self.digestID }) {
            showDigest(digest.sessions + [s])
            return
        }
        if !card.decides, plain.count >= 2 {
            let folded = plain.flatMap(\.sessions) + [s]
            for e in plain { dropEntry(e.id, animated: false) }
            showDigest(folded)
            return
        }
        let view = BannerView(card: card,
                              onOpen: { [weak self] in self?.remove(id: s.id, animated: true); self?.onOpen(s) },
                              onDismiss: { [weak self] in self?.remove(id: s.id, animated: true); self?.onDismiss(s) })
        view.onDecide = { [weak self] behavior in
            self?.remove(id: s.id, animated: true)
            self?.onDecide(s, behavior)
        }
        present(view, entry: { Entry(id: s.id, panel: $0, sessions: [s], decides: card.decides) }, config: c)
    }

    /// The digest card, replacing any earlier one. Clicking it opens the most urgent session.
    private func showDigest(_ sessions: [SessionState]) {
        dropEntry(Self.digestID, animated: false)
        var seen = Set<String>()
        let list = sessions.reversed().filter { seen.insert($0.id).inserted }.reversed() as [SessionState]
        let c = config()
        let card = BannerCard(digest: list)
        let urgent = list.first { $0.status == .needsInput || $0.isFailed || $0.ask != nil } ?? list.last
        let view = BannerView(card: card,
                              onOpen: { [weak self] in
                                  self?.dropEntry(Self.digestID, animated: true)
                                  if let urgent { self?.onOpen(urgent) }
                              },
                              onDismiss: { [weak self] in self?.dropEntry(Self.digestID, animated: true) })
        present(view, entry: { Entry(id: Self.digestID, panel: $0, sessions: list, decides: false) }, config: c)
    }

    private func present(_ view: BannerView, entry make: (NSPanel) -> Entry, config c: Config) {
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

        let entry = make(panel)
        view.onHoverChange = { [weak self, weak entry] on in
            guard let self, let entry else { return }
            entry.hovering = on
            if on { entry.timer?.invalidate() } else { self.schedule(entry, seconds: c.bannerSeconds) }
        }
        panel.contentView = view

        entries.insert(entry, at: 0)
        while entries.count > maxVisible, let oldest = entries.last(where: { !$0.decides }) ?? entries.last {
            dropEntry(oldest.id, animated: true)
        }

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
        // A permission banner stays until it's answered: the hook takes it away when it stops waiting.
        if !entry.decides { schedule(entry, seconds: c.bannerSeconds) }
    }

    /// Removes the banner for a session (for example after you reply to it). A session in the
    /// digest leaves the digest, which closes once it's empty.
    func remove(id: String, animated: Bool) {
        if let digest = entries.first(where: { $0.id == Self.digestID }), digest.sessions.contains(where: { $0.id == id }) {
            let rest = digest.sessions.filter { $0.id != id }
            if rest.count >= 2 { showDigest(rest) } else {
                dropEntry(Self.digestID, animated: animated)
                if let last = rest.first { show(last) }
            }
            return
        }
        dropEntry(id, animated: animated)
    }

    private func dropEntry(_ id: String, animated: Bool) {
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

    func removeAll() { entries.map(\.id).forEach { dropEntry($0, animated: false) } }

    /// The sessions on screen, the digest's included.
    var visibleIDs: [String] { entries.flatMap { $0.sessions.map(\.id) } }

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
