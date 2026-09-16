import Carbon.HIToolbox
import Cocoa

/// AgentBar's Settings: one small window, five quiet sections — Sounds,
/// Notifications, the global Allow/Deny shortcut, the island, and Diagnostics.
/// Every control writes
/// UserDefaults directly and fires `onChange`, so changes apply live; the app
/// delegate owns the fan-out to whichever surfaces care. Diagnostics is the odd
/// one out: it sets nothing, it reports — see `DiagnosticsView`.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    /// Wide enough that a diagnostic's detail and its fix each sit on one or two
    /// lines rather than a paragraph.
    static let minWidth: CGFloat = 470
    var onChange: (() -> Void)?

    private var window: NSWindow?
    private var enableBox: NSButton!
    private var allowRecorder: ShortcutRecorder!
    private var denyRecorder: ShortcutRecorder!
    private var soundsBox: NSButton!
    private var volumeSlider: NSSlider!
    private var testButton: NSButton!
    private var volumeRow: NSStackView!
    private var hideIslandBox: NSButton!
    private var diagnostics: DiagnosticsView!
    private var notifyApprovalsBox: NSButton!
    private var notifyFailuresBox: NSButton!
    private var notifyQuietBox: NSButton!

    /// Lives in one place because the caption is rebuilt from scratch whenever macOS
    /// has something to say about authorization — two copies of it drifted once.
    static let notifyCaptionText =
        "A banner from macOS, with Allow and Deny on it. Only for what wants an\n"
        + "answer — nothing is announced just for finishing. The summary waits until\n"
        + "you've been away from the keyboard for two minutes. Sounds are separate, above."
    private var notifyCaption: NSTextField!
    private var notifySettingsButton: NSButton!
    private var notifyTestButton: NSButton!

    func show() {
        if window == nil { build() }
        cancelCaptures() // a stale recorder must not swallow keys after re-show
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The menu quick-toggle flips the same defaults this window shows; a visible
    /// stale checkbox would look like the click didn't land.
    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func cancelCaptures() {
        allowRecorder.cancelCapture()
        denyRecorder.cancelCapture()
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "AgentBar Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        // ---- Sounds ----
        soundsBox = NSButton(checkboxWithTitle: "Play sounds for agent events",
                             target: self, action: #selector(toggleSounds))
        let soundsCap = caption(
            "A soft cue when a session needs approval, asks a question,\nor finishes. Nothing plays while agents are working.")

        volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1,
                                target: self, action: #selector(volumeChanged(_:)))
        volumeSlider.isContinuous = true
        volumeSlider.widthAnchor.constraint(equalToConstant: 168).isActive = true
        volumeSlider.setAccessibilityLabel("Sound volume")
        testButton = NSButton(title: "Test", target: self, action: #selector(testClicked))
        testButton.bezelStyle = .rounded
        volumeRow = NSStackView(views: [speakerGlyph("speaker.fill"), volumeSlider,
                                        speakerGlyph("speaker.wave.3.fill"), testButton])
        volumeRow.orientation = .horizontal
        volumeRow.alignment = .centerY
        volumeRow.spacing = 8
        volumeRow.setCustomSpacing(12, after: volumeRow.arrangedSubviews[2])

        // ---- Shortcuts ----
        enableBox = NSButton(checkboxWithTitle: "Global Allow / Deny shortcut",
                             target: self, action: #selector(toggleEnabled))
        let enableCaption = caption(
            "Answer the newest pending permission request from anywhere,\nwithout opening the menu. No Accessibility permission needed.")

        allowRecorder = ShortcutRecorder(defaultsKey: "allowHotKey", fallback: .defaultAllow)
        denyRecorder = ShortcutRecorder(defaultsKey: "denyHotKey", fallback: .defaultDeny)
        for recorder in [allowRecorder!, denyRecorder!] {
            recorder.onCaptureChange = { [weak self, weak recorder] capturing in
                guard let self else { return }
                if capturing {
                    // One recorder at a time, and while recording the current combo
                    // must reach the recorder, not the Carbon hotkey — suspend,
                    // then re-register on the way out.
                    let other = recorder === self.allowRecorder ? self.denyRecorder : self.allowRecorder
                    other?.cancelCapture()
                    HotKeyCenter.shared.suspend()
                } else {
                    self.onChange?()
                }
            }
            recorder.rejectCombo = { [weak self, weak recorder] combo in
                // The two actions may not share one combo.
                let other = recorder === self?.allowRecorder ? self?.denyRecorder : self?.allowRecorder
                return combo == other?.combo
            }
            recorder.onRecord = { [weak self] in self?.onChange?() }
        }

        let grid = NSGridView(views: [
            [gridLabel("Allow:"), allowRecorder!],
            [gridLabel("Deny:"), denyRecorder!],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        // ---- Island ----
        hideIslandBox = NSButton(checkboxWithTitle: "Hide island when no sessions",
                                 target: self, action: #selector(toggleHideIsland))
        let islandCaption = caption(
            "The pill slips away when nothing is running and returns with\nthe next session. Applies when the menu bar mark is shown too.")

        // ---- Notifications ----
        // Off by default, and the ask for permission happens on the tick, never at
        // launch — see Notifier.start().
        notifyApprovalsBox = NSButton(checkboxWithTitle: "When an agent needs approval",
                                      target: self, action: #selector(toggleNotifications))
        notifyFailuresBox = NSButton(checkboxWithTitle: "When a session fails",
                                     target: self, action: #selector(toggleNotifications))
        notifyQuietBox = NSButton(checkboxWithTitle: "When everything goes quiet, and you're away",
                                  target: self, action: #selector(toggleNotifications))
        notifyCaption = caption(Self.notifyCaptionText)
        // Telling someone where a switch lives is not the same as taking them there.
        // Shown only when macOS has actually refused, so it is never a button that
        // opens a pane with nothing to do in it.
        notifySettingsButton = NSButton(title: "Open System Settings", target: self,
                                        action: #selector(openNotificationSettings))
        notifySettingsButton.bezelStyle = .rounded
        notifySettingsButton.controlSize = .small
        notifySettingsButton.font = .systemFont(ofSize: 11)
        notifySettingsButton.isHidden = true

        // Same affordance the Sounds section has, for the same reason: "is this
        // reaching me?" deserves an answer that isn't "wait for an agent to need
        // something". It also separates suppressed-by-Focus from broken, which from
        // the outside look identical.
        notifyTestButton = NSButton(title: "Send a test", target: self,
                                    action: #selector(sendTestNotification))
        notifyTestButton.bezelStyle = .rounded
        notifyTestButton.controlSize = .small
        notifyTestButton.font = .systemFont(ofSize: 11)
        notifyTestButton.toolTip = "Nothing appears? A Focus is probably on — macOS files banners in Notification Center instead of showing them."

        let notifyButtons = NSStackView(views: [notifyTestButton, notifySettingsButton])
        notifyButtons.orientation = .horizontal
        notifyButtons.spacing = 8

        // ---- Diagnostics ----
        diagnostics = DiagnosticsView()
        diagnostics.onResize = { [weak self] in self?.refit() }
        let diagnosticsCaption = caption(
            "Why an agent isn't showing up: hooks wired, the node they point at\nstill there, folders writable, when each agent last reported.")

        // A rule, not a per-section variable: each one is width-constrained
        // individually, and naming them sep1…sepN meant remembering a constraint
        // every time a section was added.
        let seps = (0..<4).map { _ in separator() }
        let stack = NSStackView(views: [
            sectionLabel("Sounds"), soundsBox, soundsCap, volumeRow, seps[0],
            sectionLabel("Notifications"), notifyApprovalsBox, notifyFailuresBox,
            notifyQuietBox, notifyCaption, notifyButtons, seps[1],
            sectionLabel("Shortcuts"), enableBox, enableCaption, grid, seps[2],
            sectionLabel("Island"), hideIslandBox, islandCaption, seps[3],
            sectionLabel("Diagnostics"), diagnosticsCaption, diagnostics,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[2]) // caption → volume row
        stack.setCustomSpacing(16, after: volumeRow)
        for sep in seps { stack.setCustomSpacing(16, after: sep) }
        stack.setCustomSpacing(14, after: enableCaption)
        stack.setCustomSpacing(16, after: grid)
        stack.setCustomSpacing(16, after: islandCaption)
        stack.setCustomSpacing(8, after: notifyCaption)
        stack.setCustomSpacing(14, after: notifyButtons)
        stack.setCustomSpacing(2, after: notifyApprovalsBox)
        stack.setCustomSpacing(2, after: notifyFailuresBox)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The grid indents to line up under the checkbox title, not its box.
        grid.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = NSView()
        w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 38),
            volumeRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 38),
            diagnostics.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            // Before Diagnostics the width fell out of whichever caption was longest,
            // which left a diagnostic row wrapping its fix across four lines and the
            // window running off the bottom of the screen. A floor is cheaper than
            // hand-breaking every caption to the same length.
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth),
        ] + seps.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40) })
        self.stack = stack
        w.setContentSize(stack.fittingSize)
        window = w
    }

    /// Diagnostics changes height as checks come and go, so the window has to be
    /// re-fitted *both* ways — one that only grows leaves a hole under the last row.
    private var stack: NSStackView?
    private func refit() {
        guard let window, let stack else { return }
        window.setContentSize(stack.fittingSize)
        // The window was centred at its old height and grows downward from its title
        // bar, so a few diagnostic rows push its bottom under the Dock. Nudge it back
        // into view rather than re-centring, which would yank it while it is read.
        guard let visible = window.screen?.visibleFrame else { return }
        var frame = window.frame
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.origin != window.frame.origin { window.setFrameOrigin(frame.origin) }
    }

    private func reload() {
        enableBox.state = UserDefaults.standard.bool(forKey: "globalApprovalShortcut") ? .on : .off
        allowRecorder.reload()
        denyRecorder.reload()
        soundsBox.state = SoundCenter.enabled ? .on : .off
        volumeSlider.doubleValue = SoundCenter.volume
        hideIslandBox.state = UserDefaults.standard.bool(forKey: "hideIslandWhenEmpty") ? .on : .off
        notifyApprovalsBox.state = Notifier.Prefs.approvals ? .on : .off
        notifyFailuresBox.state = Notifier.Prefs.failures ? .on : .off
        notifyQuietBox.state = Notifier.Prefs.quiet ? .on : .off
        notifyTestButton.isEnabled = Notifier.Prefs.anyEnabled
        syncNotificationCaption()
        // Re-run on every show: the answer changes with what the user did outside
        // this window — installed an agent, upgraded node, granted Accessibility.
        diagnostics.refresh()
        syncRecorderState()
        syncSoundControls()
    }

    @objc private func toggleEnabled() {
        UserDefaults.standard.set(enableBox.state == .on, forKey: "globalApprovalShortcut")
        syncRecorderState()
        onChange?()
    }

    /// Turning either switch on asks macOS for permission the first time. A refusal
    /// un-ticks the box rather than leaving a setting that quietly does nothing, and
    /// the caption says where to change your mind.
    @objc private func toggleNotifications(_ sender: NSButton) {
        let turningOn = sender.state == .on
        // One selector, three boxes: the sender says which preference it owns, so
        // adding a channel is a line here rather than a fourth near-identical method.
        let write: (Bool) -> Void = { [weak self] on in
            guard let self else { return }
            switch sender {
            case self.notifyApprovalsBox: Notifier.Prefs.approvals = on
            case self.notifyFailuresBox: Notifier.Prefs.failures = on
            default: Notifier.Prefs.quiet = on
            }
        }
        write(turningOn)

        if turningOn {
            Notifier.shared.requestAuthorization { [weak self] granted, error in
                guard let self else { return }
                // The refusal has to SAY something. Springing the box back with an
                // unchanged caption is indistinguishable from a dead control, which
                // is how this shipped the first time and how it was reported.
                Notifier.shared.authorizationStatus { [weak self] status in
                    guard let self else { return }
                    self.notificationProblem = Notifier.problem(granted: granted, error: error,
                                                                status: status)
                    if !granted {
                        write(false)
                        sender.state = .off
                    }
                    self.syncNotificationCaption()
                }
            }
        } else if sender === notifyApprovalsBox {
            // A banner already on screen must not outlive the setting that allowed it.
            Notifier.shared.withdrawAll()
        }
        notifyTestButton.isEnabled = Notifier.Prefs.anyEnabled
        onChange?()
    }

    /// Set when macOS last refused, and shown until it stops being true. Kept
    /// separate from the preferences: the refusal turns them back off, so a caption
    /// that keyed off "is anything enabled" would erase its own explanation.
    private var notificationProblem: String?

    /// Straight to the pane, not to a search box. The URL is the Notifications
    /// settings extension; if a future macOS renames it, the caption still says
    /// where to go by hand, so the worst case is a button that does nothing rather
    /// than instructions that are wrong.
    @objc private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func sendTestNotification() {
        Notifier.shared.preview()
    }

    private func syncNotificationCaption() {
        let base = Self.notifyCaptionText
        if let notificationProblem {
            notifyCaption.stringValue = notificationProblem
            notifyCaption.textColor = .systemOrange
            notifySettingsButton.isHidden = false
            refit()
            return
        }
        notifyCaption.textColor = .secondaryLabelColor
        notifySettingsButton.isHidden = true
        // Nothing switched on, nothing refused: there is no authorization state worth
        // reporting yet, and asking for it would be a round trip for no reason.
        guard Notifier.Prefs.anyEnabled else { notifyCaption.stringValue = base; refit(); return }
        Notifier.shared.authorizationStatus { [weak self] status in
            guard let self else { return }
            let problem = Notifier.problem(granted: false, error: nil, status: status)
            self.notifyCaption.stringValue = problem ?? base
            self.notifyCaption.textColor = problem == nil ? .secondaryLabelColor : .systemOrange
            self.notifySettingsButton.isHidden = problem == nil
            self.refit()
        }
    }

    @objc private func toggleSounds() {
        SoundCenter.enabled = soundsBox.state == .on
        syncSoundControls()
        if SoundCenter.enabled { SoundCenter.shared.preview() }
        onChange?()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        SoundCenter.volume = sender.doubleValue
        // Audition on release, not per tick — matches the system alert-volume slider.
        if NSApp.currentEvent?.type == .leftMouseUp { SoundCenter.shared.preview() }
    }

    @objc private func testClicked() {
        SoundCenter.shared.preview()
    }

    @objc private func toggleHideIsland() {
        UserDefaults.standard.set(hideIslandBox.state == .on, forKey: "hideIslandWhenEmpty")
        onChange?()
    }

    private func syncRecorderState() {
        let on = enableBox.state == .on
        allowRecorder.isEnabled = on
        denyRecorder.isEnabled = on
    }

    private func syncSoundControls() {
        let on = soundsBox.state == .on
        volumeSlider.isEnabled = on
        testButton.isEnabled = on
        volumeRow.alphaValue = on ? 1 : 0.5 // dims the glyphs too; NSImageView has no isEnabled
    }

    func windowWillClose(_ notification: Notification) {
        cancelCaptures()
    }

    /// Clicking away mid-recording: a background window can't see key events, so a
    /// still-armed recorder would leave the hotkeys suspended forever. End it now.
    func windowDidResignKey(_ notification: Notification) {
        cancelCaptures()
    }

    private func caption(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func speakerGlyph(_ symbol: String) -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        v.contentTintColor = .secondaryLabelColor
        return v
    }

    private func gridLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: NSFont.systemFontSize)
        return l
    }
}

/// A button that shows the current combo and, when clicked, records the next
/// keystroke as the new one. Esc cancels; a combo needs ⌘, ⌥ or ⌃ so a plain
/// letter typed anywhere can never become a global hotkey.
final class ShortcutRecorder: NSButton {
    private let defaultsKey: String
    private let fallback: KeyCombo
    private(set) var combo: KeyCombo
    var onRecord: (() -> Void)?
    var onCaptureChange: ((Bool) -> Void)?
    var rejectCombo: ((KeyCombo) -> Bool)?
    private var monitor: Any?

    init(defaultsKey: String, fallback: KeyCombo) {
        self.defaultsKey = defaultsKey
        self.fallback = fallback
        self.combo = KeyCombo.stored(defaultsKey, fallback: fallback)
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        combo = KeyCombo.stored(defaultsKey, fallback: fallback)
        title = combo.display
    }

    @objc private func beginCapture() {
        guard monitor == nil else { return }
        title = "Type shortcut… (esc cancels)"
        onCaptureChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // swallow the keystroke while recording
        }
    }

    func cancelCapture() {
        // Only a live capture may end — a plain call must not re-fire
        // onCaptureChange(false) and needlessly re-register the hotkeys.
        if monitor != nil { endCapture() }
    }

    private func endCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = combo.display
        onCaptureChange?(false)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt32(kVK_Escape) { endCapture(); return }
        let carbon = Self.carbonFlags(event.modifierFlags)
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            NSSound.beep()
            return // keep capturing until a real combo (or esc) arrives
        }
        let recorded = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon,
                                display: Self.display(for: event))
        if rejectCombo?(recorded) == true {
            NSSound.beep()
            return
        }
        combo = recorded
        combo.store(as: defaultsKey)
        endCapture()
        onRecord?()
    }

    private static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.option) { c |= UInt32(optionKey) }
        if flags.contains(.shift) { c |= UInt32(shiftKey) }
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        return c
    }

    private static func display(for event: NSEvent) -> String {
        var s = ""
        let f = event.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + keyName(event)
    }

    private static func keyName(_ event: NSEvent) -> String {
        if let n = fKeyNumber(event.keyCode) { return "F\(n)" }
        switch Int(event.keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }

    private static func fKeyNumber(_ code: UInt16) -> Int? {
        let map: [Int: Int] = [kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6,
                               kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12]
        return map[Int(code)]
    }
}
