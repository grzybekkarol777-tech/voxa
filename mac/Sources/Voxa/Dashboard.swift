// The window that opens with the app: status, stats, recent dictations and settings, in the Voxa colors. AppKit, not
// SwiftUI: the Command Line Tools' SwiftUI module was built by a different compiler build, so SwiftUI won't compile.
import AppKit
import AVFoundation
import ServiceManagement

let indigo = NSColor(srgbRed: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255, alpha: 1)
let violet = NSColor(srgbRed: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255, alpha: 1)
let magenta = NSColor(srgbRed: 0xDB / 255, green: 0x27 / 255, blue: 0x77 / 255, alpha: 1)

struct Entry: Codable {
    let date: Date
    let text: String
    let seconds: Double
    let via: String
}

enum Status { case ready, recording, busy }

/// What the dashboard shows and the app changes. Main thread only.
final class Store {
    static let shared = Store()
    private let path = home + "/Library/Application Support/Voxa/history.json"
    var onChange: () -> Void = {}

    private(set) var history: [Entry] = []
    var status = Status.ready { didSet { onChange() } }
    var useOpenAI = true { didSet { onChange() } }  // off keeps the audio on this Mac
    // Saved, unlike useOpenAI: turning paste off and finding it back on after a restart would type into the wrong app.
    var autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPaste, forKey: "autoPaste"); onChange() }
    }
    // Off by default: Return sends a Claude prompt (or a chat message) before you can read what was heard.
    var sendAfterPaste = UserDefaults.standard.bool(forKey: "sendAfterPaste") {
        didSet { UserDefaults.standard.set(sendAfterPaste, forKey: "sendAfterPaste"); onChange() }
    }
    var level: () -> Double = { 0 }  // the mic level while recording, for the dashboard's waveform
    private(set) var hasKey = false

    init() {
        if let data = FileManager.default.contents(atPath: path),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            history = saved
        }
    }

    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var accessOK: Bool { AXIsProcessTrusted() }  // Accessibility, which posting Cmd+V to another app needs

    func refresh() {
        onChange()
        DispatchQueue.global().async {
            let found = openAIKey() != nil  // runs the security tool: not on the main thread
            DispatchQueue.main.async {
                self.hasKey = found
                self.onChange()
            }
        }
    }

    func add(_ entry: Entry) {
        history.insert(entry, at: 0)
        history = Array(history.prefix(200))  // a long history only slows the window
        save()
        onChange()
    }

    func clear() {
        history = []
        save()
        onChange()
    }

    private func save() {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: URL(fileURLWithPath: path))
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notify("Couldn't change Open at Login", "Add Voxa in System Settings > General > Login Items. (\(error.localizedDescription))")
        }
        onChange()
    }

    var words: Int { history.reduce(0) { $0 + $1.text.split(separator: " ").count } }
    var today: Int { history.filter { Calendar.current.isDateInToday($0.date) }.count }
    /// Typing at 40 words a minute against speaking at 150.
    var minutesSaved: Double { Double(words) / 40 - Double(words) / 150 }
}

// MARK: Building blocks

/// The Voxa gradient, indigo to magenta, top left to bottom right.
final class GradientView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let g = CAGradientLayer()
        g.colors = [indigo.cgColor, violet.cgColor, magenta.cgColor]
        g.startPoint = CGPoint(x: 0, y: 1)
        g.endPoint = CGPoint(x: 1, y: 0)
        return g
    }

    /// Lets the colors drift back and forth while Voxa listens or works; off returns to the still gradient.
    func animate(_ on: Bool, period: Double = 1.6) {
        layer?.removeAnimation(forKey: "breathe")
        guard on else { return }
        let a = CABasicAnimation(keyPath: "colors")
        a.fromValue = [indigo.cgColor, violet.cgColor, magenta.cgColor]
        a.toValue = [violet.cgColor, magenta.cgColor, indigo.cgColor]
        a.duration = period
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(a, forKey: "breathe")
    }
}

func whiteSpinner() -> NSProgressIndicator {
    let s = NSProgressIndicator()
    s.style = .spinning
    s.controlSize = .small
    s.appearance = NSAppearance(named: .darkAqua)  // a light spinner on the purple
    s.translatesAutoresizingMaskIntoConstraints = false
    s.widthAnchor.constraint(equalToConstant: 16).isActive = true
    s.heightAnchor.constraint(equalToConstant: 16).isActive = true
    return s
}

/// A rounded panel that follows light and dark mode (layer colors don't, so they are set again on every change).
final class Card: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }  // the scroll view starts at the top
}

/// Buttons and switches that run a closure.
final class Action: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .labelColor,
          rounded: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: s)
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
    field.font = font
    field.textColor = color
    return field
}

func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    return s
}

func pin(_ child: NSView, in parent: NSView, _ inset: NSEdgeInsets) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset.left),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset.right),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset.top),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset.bottom),
    ])
}

// MARK: Window

/// The dashboard. While it is open Voxa shows in the Dock and the app switcher, like a normal app; closing it returns
/// Voxa to the menu bar only.
final class DashboardWindow: NSObject, NSWindowDelegate {
    private let store = Store.shared
    private var window: NSWindow?
    private var stack: NSStackView!
    private var scroll: NSScrollView!
    private let dot = NSView()
    private let pillSpinner = whiteSpinner()
    private let statusLabel = text("", 13, .semibold, .white)
    private var actions: [Action] = []  // targets are weak, so the closures live here
    private var header: GradientView!, pill: NSView!
    // The purple card at the top while Voxa listens or transcribes. Built once: reload() rebuilds the rest of the
    // stack on every change, and a new card would lose its waveform.
    private let live = GradientView()
    private var liveWidth: NSLayoutConstraint!
    private let liveIcon = NSImageView()
    private let liveSpinner = whiteSpinner()
    private let liveTitle = text("", 17, .bold, .white, rounded: true)
    private let liveHint = text("", 12, .medium, NSColor.white.withAlphaComponent(0.8))
    private let wave = WaveView()
    private var waveTimer: Timer?
    private var shown: Status?  // the status the animations were last set for

    func show() {
        if window == nil { build() }
        store.onChange = { [weak self] in self?.reload() }
        store.refresh()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        waveTimer?.invalidate()
        waveTimer = nil
        shown = nil  // set everything again when it reopens
    }

    func windowDidResize(_ notification: Notification) { reload() }  // the dictation text wraps to the new width

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Voxa"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 520)
        w.delegate = self
        let content = w.contentView!

        header = GradientView()
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let titles = vstack([text("Voxa", 30, .bold, .white, rounded: true),
                             text("Your voice, typed.", 14, .medium, NSColor.white.withAlphaComponent(0.85))], spacing: 2)
        titles.translatesAutoresizingMaskIntoConstraints = false
        pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        pill.layer?.cornerRadius = 15
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        let pillRow = NSStackView(views: [dot, pillSpinner, statusLabel])
        pillRow.spacing = 8
        pin(pillRow, in: pill, NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14))
        pill.translatesAutoresizingMaskIntoConstraints = false
        for v in [icon, titles, pill!] as [NSView] { header.addSubview(v) }

        scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)
        let doc = FlippedView()
        scroll.documentView = doc
        stack = vstack([], spacing: 14)
        pin(stack, in: doc, NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24))
        doc.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 128),  // room above for the window buttons
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 28),
            icon.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -20),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            titles.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            titles.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            pill.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -28),
            pill.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        w.center()
        w.setFrameAutosaveName("VoxaDashboard")
        window = w
        buildLive()
    }

    private func buildLive() {
        live.layer?.cornerRadius = 14
        live.layer?.masksToBounds = true
        liveIcon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
        liveIcon.contentTintColor = .white
        let top = NSStackView(views: [liveIcon, liveSpinner, vstack([liveTitle, liveHint], spacing: 2)])
        top.spacing = 12
        wave.translatesAutoresizingMaskIntoConstraints = false
        wave.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let inner = vstack([top, wave], spacing: 10)
        wave.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        pin(inner, in: live, NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18))
        liveWidth = live.widthAnchor.constraint(equalToConstant: 400)
        liveWidth.isActive = true
    }

    /// The header, the pill and the purple card follow the status. Only on a change, so the animations don't restart
    /// every time something else (the key check, a new entry) reloads the window.
    private func showStatus() {
        let status = store.status
        guard status != shown else { return }
        shown = status
        let active = status != .ready
        statusLabel.stringValue = switch status {
        case .ready: "Ready · press ⌥ Space"
        case .recording: "Listening…"
        case .busy: "Transcribing…"
        }
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(active ? 0.28 : 0.18).cgColor
        dot.isHidden = status == .busy
        pillSpinner.isHidden = status != .busy
        dot.layer?.backgroundColor = (status == .ready ? NSColor.systemGreen : magenta).cgColor
        dot.layer?.removeAnimation(forKey: "pulse")
        if status == .recording {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.3
            a.duration = 0.7
            a.autoreverses = true
            a.repeatCount = .infinity
            dot.layer?.add(a, forKey: "pulse")
        }
        let period = status == .busy ? 0.8 : 1.6  // faster while it works
        header.animate(active, period: period)
        live.animate(active, period: period)

        waveTimer?.invalidate()
        waveTimer = nil
        liveIcon.isHidden = status == .busy
        liveSpinner.isHidden = status != .busy
        if status == .recording {
            liveTitle.stringValue = "Listening…"
            liveHint.stringValue = "⌥ Space to stop · esc to cancel"
            wave.clear()
            wave.alphaValue = 1
            waveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.wave.push(self.store.level())
            }
        } else if status == .busy {
            liveTitle.stringValue = "Transcribing…"
            liveHint.stringValue = "Your text lands on the clipboard"
            wave.alphaValue = 0.4  // the waveform freezes where the recording ended
        }
        if status == .busy { pillSpinner.startAnimation(nil); liveSpinner.startAnimation(nil) } else {
            pillSpinner.stopAnimation(nil)
            liveSpinner.stopAnimation(nil)
        }
    }

    private func reload() {
        guard let stack, window?.isVisible ?? true else { return }
        showStatus()

        actions = []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = max(400, scroll.contentSize.width - 48)
        if store.status != .ready {
            stack.addArrangedSubview(live)
            stack.setCustomSpacing(18, after: live)
        }
        stack.addArrangedSubview(stats())
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        let clear: (() -> Void)? = store.history.isEmpty ? nil : { [weak self] in self?.store.clear() }
        stack.addArrangedSubview(sectionTitle("Recent dictations", button: "Clear history", run: clear))
        if store.history.isEmpty {
            stack.addArrangedSubview(card(note("Nothing yet. Press ⌥ Space, speak, and press it again: your text lands here and on the clipboard.", width - 32)))
        }
        for entry in store.history.prefix(30) { stack.addArrangedSubview(row(entry, width)) }
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sectionTitle("Settings", button: "", run: nil))
        stack.addArrangedSubview(settings())
        liveWidth.constant = width
        for v in stack.arrangedSubviews where v !== live { v.widthAnchor.constraint(equalToConstant: width).isActive = true }
    }

    private func act(_ run: @escaping () -> Void) -> Action {
        let a = Action(run)
        actions.append(a)
        return a
    }

    private func card(_ inner: NSView, inset: CGFloat = 16) -> Card {
        let c = Card()
        pin(inner, in: c, NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
        return c
    }

    private func note(_ s: String, _ width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = width
        return f
    }

    private func stats() -> NSView {
        let saved = store.minutesSaved
        let items = [("\(store.today)", "Dictations today"),
                     (store.words.formatted(), "Words dictated"),
                     (saved < 60 ? "\(Int(saved.rounded())) min" : String(format: "%.1f h", saved / 60), "Time saved vs typing")]
        let row = NSStackView(views: items.map { value, caption in
            let accent = GradientView()
            accent.heightAnchor.constraint(equalToConstant: 4).isActive = true
            accent.widthAnchor.constraint(equalToConstant: 28).isActive = true
            accent.layer?.cornerRadius = 2
            return card(vstack([accent, text(value, 28, .bold, violet, rounded: true),
                                text(caption, 12, .medium, .secondaryLabelColor)], spacing: 6))
        })
        row.distribution = .fillEqually
        row.spacing = 14
        return row
    }

    private func sectionTitle(_ title: String, button label: String, run: (() -> Void)?) -> NSView {
        let row = NSStackView(views: [text(title, 16, .semibold)])
        row.addArrangedSubview(NSView())  // pushes the button to the right
        if let run {
            let a = act(run)
            let b = NSButton(title: label, target: a, action: #selector(Action.fire))
            b.isBordered = false
            b.contentTintColor = violet
            row.addArrangedSubview(b)
        }
        return row
    }

    private func row(_ entry: Entry, _ width: CGFloat) -> NSView {
        let strip = GradientView()
        strip.layer?.cornerRadius = 2
        strip.widthAnchor.constraint(equalToConstant: 4).isActive = true
        let body = NSTextField(wrappingLabelWithString: entry.text)
        body.font = .systemFont(ofSize: 13)
        body.maximumNumberOfLines = 3
        body.lineBreakMode = .byTruncatingTail
        body.isSelectable = true
        body.preferredMaxLayoutWidth = width - 24 - 4 - 12 - 12 - 28
        let meta = text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.0f", entry.seconds)) s · \(entry.via)",
                        11, .regular, .secondaryLabelColor)
        let a = act {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
        }
        let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")!, target: a,
                            action: #selector(Action.fire))
        copy.isBordered = false
        copy.toolTip = "Copy"
        let texts = vstack([body, meta], spacing: 4)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [strip, texts, copy])
        line.alignment = .top
        line.spacing = 12
        strip.heightAnchor.constraint(equalTo: texts.heightAnchor).isActive = true
        return card(line, inset: 12)
    }

    private func settings() -> NSView {
        func status(_ ok: Bool, _ good: String, _ bad: String) -> NSView {
            let l = text(ok ? "✓ \(good)" : "⚠︎ \(bad)", 13, .medium, ok ? .systemGreen : .systemOrange)
            return l
        }
        func toggle(_ on: Bool, _ run: @escaping (Bool) -> Void) -> NSView {
            let s = NSSwitch()
            s.state = on ? .on : .off
            s.target = act { [weak s] in run(s?.state == .on) }
            s.action = #selector(Action.fire)
            return s
        }
        let micButton: NSView = store.micAllowed ? status(true, "Allowed", "") : {
            let a = act {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            return NSButton(title: "Open Settings", target: a, action: #selector(Action.fire))
        }()
        let accessButton: NSView = store.accessOK ? status(true, "Allowed", "") : {
            let a = act {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            return NSButton(title: "Open Settings", target: a, action: #selector(Action.fire))
        }()
        let rows: [(String, String, NSView)] = [
            ("Use OpenAI", "Off keeps your voice on this Mac (local Whisper, slower).",
             toggle(store.useOpenAI) { [weak self] in self?.store.useOpenAI = $0 }),
            ("Paste into the front app", "The text lands where you're typing, like Claude Code. It stays on the clipboard too.",
             toggle(store.autoPaste) { [weak self] in self?.store.autoPaste = $0 }),
            ("Press Return after pasting", "Sends the prompt hands-free. You won't see the text before it goes.",
             toggle(store.sendAfterPaste) { [weak self] in self?.store.sendAfterPaste = $0 }),
            ("Accessibility", store.accessOK ? "Voxa can paste for you."
                : "Needed to paste into most apps (admin password). Terminal works without it, and presses Return.",
             accessButton),
            ("Open at Login", "Voxa waits in the menu bar from the moment you log in.",
             toggle(store.openAtLogin) { [weak self] in self?.store.setLogin($0) }),
            ("Microphone", store.micAllowed ? "Voxa can hear you." : "Voxa needs the microphone to hear you.", micButton),
            ("OpenAI key", store.hasKey ? "Found in your Keychain." : "Missing: Voxa uses local Whisper until it's added.",
             status(store.hasKey, "Found", "Missing")),
        ]
        var views: [NSView] = []
        for (i, (title, detail, control)) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                views.append(line)
            }
            let labels = vstack([text(title, 13, .medium), text(detail, 11, .regular, .secondaryLabelColor)], spacing: 2)
            labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let r = NSStackView(views: [labels, control])
            r.alignment = .centerY
            views.append(r)
        }
        let list = vstack(views, spacing: 12)
        for v in views { v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        return card(list)
    }
}
