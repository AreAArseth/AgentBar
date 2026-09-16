import Cocoa

/// Which display the island lives on.
///
/// The default is to follow the pointer, which is right for one display and for
/// people who move between them. On a fixed multi-display desk it is the wrong
/// answer: the island jumps to whichever screen the mouse wandered onto, and a
/// status surface that moves is a status surface you have to look for. So the
/// choice can be pinned to one display instead, in the welcome window.
enum IslandScreen {
    enum Choice: Equatable {
        case followsPointer
        /// A display's stable UUID — see `uuid(of:)` for why not the display ID.
        case pinned(String)
    }

    private static let key = "islandScreen"

    /// Fired after `choice` changes, so the island can move without a relaunch.
    static var onChange: (() -> Void)?

    static var choice: Choice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key), !raw.isEmpty,
                  raw != "pointer" else { return .followsPointer }
            return .pinned(raw)
        }
        set {
            guard newValue != choice else { return }
            switch newValue {
            case .followsPointer: UserDefaults.standard.removeObject(forKey: key)
            case .pinned(let id): UserDefaults.standard.set(id, forKey: key)
            }
            onChange?()
        }
    }

    /// The screen the island belongs on, or nil when there is none at all.
    ///
    /// A pinned display that is not currently connected falls back to the pointer
    /// rather than to nothing: unplugging a monitor must not make AgentBar
    /// invisible, and the preference is kept so it takes effect again on replug.
    static var resolved: NSScreen? {
        if case .pinned(let id) = choice,
           let match = NSScreen.screens.first(where: { uuid(of: $0) == id }) {
            return match
        }
        return underPointer
    }

    static var underPointer: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// True when the pinned display is currently missing — the picker says so
    /// rather than silently showing "follow the pointer" as if nothing was set.
    static var pinnedDisplayMissing: Bool {
        guard case .pinned(let id) = choice else { return false }
        return !NSScreen.screens.contains { uuid(of: $0) == id }
    }

    /// A display's identity, stable across reboots and reconnects.
    ///
    /// `CGDirectDisplayID` is not: it is handed out per session, so a display
    /// unplugged and plugged back in can come back as a different number, and the
    /// island would quietly land on the wrong screen. The UUID survives that.
    static func uuid(of screen: NSScreen) -> String? {
        guard let id = displayID(of: screen),
              let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, ref) as String
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    /// Built-in displays are drawn as a laptop rather than a monitor, the way
    /// System Settings does it — it is how people recognise their own desk.
    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let id = displayID(of: screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}
