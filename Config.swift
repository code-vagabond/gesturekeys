// Config file + key-combo parsing. The daemon polls the file and reloads on change,
// so editing mappings never touches the signed binary (and never resets Accessibility).

import CoreGraphics
import Foundation

struct Shortcut: Equatable {
    let key: CGKeyCode
    let flags: CGEventFlags
}

let gestures: [(name: String, help: String)] = [
    ("tiptap-left", "rest one finger, tap another finger to its left"),
    ("tiptap-right", "rest one finger, tap another finger to its right"),
    ("three-finger-click", "click with three fingers on the trackpad / Magic Mouse"),
]

let defaultConfig = """
# gesturekeys config — one mapping per line: <gesture> = <combo>
# Combos: modifiers (cmd, alt, ctrl, shift, fn) + one key, joined with "+".
# Use "none" to disable a gesture. Run `gesturekeys keys` for all key names.
# Changes are picked up automatically, no restart needed.

tiptap-left        = cmd+alt+left
tiptap-right       = cmd+alt+right
three-finger-click = cmd+w

"""

let configURL: URL = {
    let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    return base.appendingPathComponent("gesturekeys/config")
}()

// US ANSI virtual key codes (Carbon kVK_*)
let keyCodes: [String: CGKeyCode] = {
    var k: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    let fKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    for (i, code) in fKeys.enumerated() { k["f\(i + 1)"] = code }
    return k
}()

let keyAliases = ["enter": "return", "esc": "escape", "backspace": "delete", "del": "forwarddelete"]

let modifierNames: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand,
    "alt": .maskAlternate, "opt": .maskAlternate, "option": .maskAlternate, "⌥": .maskAlternate,
    "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
    "shift": .maskShift, "⇧": .maskShift,
    "fn": .maskSecondaryFn,
]

// Real keyboards set these on arrows / navigation keys; some apps check for them.
let navKeys: Set<CGKeyCode> = [115, 116, 117, 119, 121, 123, 124, 125, 126]

enum ConfigError: Error, CustomStringConvertible {
    case badCombo(String), unknownGesture(String), badLine(Int, String)
    var description: String {
        switch self {
        case .badCombo(let s): return "can't parse combo '\(s)' (run `gesturekeys keys`)"
        case .unknownGesture(let s): return "unknown gesture '\(s)' (run `gesturekeys gestures`)"
        case .badLine(let n, let s): return "line \(n): \(s)"
        }
    }
}

/// Returns nil for "none".
func parseCombo(_ raw: String) throws -> Shortcut? {
    let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if s == "none" || s.isEmpty { return nil }
    let parts = s.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    var flags: CGEventFlags = []
    var key: CGKeyCode?
    for p in parts {
        if let m = modifierNames[p] {
            flags.insert(m)
        } else if key == nil, let k = keyCodes[keyAliases[p] ?? p] {
            key = k
        } else {
            throw ConfigError.badCombo(raw)
        }
    }
    guard let key else { throw ConfigError.badCombo(raw) }
    if navKeys.contains(key) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
    return Shortcut(key: key, flags: flags)
}

func stripComment(_ line: String) -> String {
    (line.components(separatedBy: "#").first ?? "").trimmingCharacters(in: .whitespaces)
}

func parseConfig(_ text: String) throws -> [String: Shortcut?] {
    var out: [String: Shortcut?] = [:]
    for (i, line) in text.components(separatedBy: .newlines).enumerated() {
        let l = stripComment(line)
        if l.isEmpty { continue }
        let kv = l.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard kv.count == 2 else { throw ConfigError.badLine(i + 1, "expected <gesture> = <combo>") }
        guard gestures.contains(where: { $0.name == kv[0] }) else { throw ConfigError.badLine(i + 1, ConfigError.unknownGesture(kv[0]).description) }
        do { out[kv[0]] = try parseCombo(kv[1]) } catch { throw ConfigError.badLine(i + 1, "\(error)") }
    }
    return out
}

func readConfigText() -> String {
    if let t = try? String(contentsOf: configURL, encoding: .utf8) { return t }
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
    return defaultConfig
}

func configMTime() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
}

// MARK: - CLI

func rawValue(_ text: String, _ gesture: String) -> String? {
    for line in text.components(separatedBy: .newlines) {
        let l = stripComment(line)
        let kv = l.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if kv.count == 2, kv[0] == gesture { return kv[1] }
    }
    return nil
}

func runCLI(_ args: [String]) -> Int32 {
    let cmd = args.first ?? "help"
    switch cmd {
    case "list":
        let text = readConfigText()
        do { _ = try parseConfig(text) } catch { print("config error: \(error)") }
        for g in gestures {
            print("\(g.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(rawValue(text, g.name) ?? "none")")
        }
        print("\n(\(configURL.path))")
    case "set":
        guard args.count >= 3 else { print("usage: gesturekeys set <gesture> <combo|none>"); return 2 }
        let gesture = args[1], combo = args[2...].joined(separator: "")
        guard gestures.contains(where: { $0.name == gesture }) else { print(ConfigError.unknownGesture(gesture)); return 1 }
        do { _ = try parseCombo(combo) } catch { print(error); return 1 }
        var lines = readConfigText().components(separatedBy: "\n")
        let newLine = "\(gesture.padding(toLength: 18, withPad: " ", startingAt: 0)) = \(combo)"
        if let i = lines.firstIndex(where: { rawValue($0, gesture) != nil }) {
            lines[i] = newLine
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += [newLine, ""]
        }
        do {
            try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
        } catch { print("could not write \(configURL.path): \(error)"); return 1 }
        print("\(gesture) = \(combo)  (live within ~1s)")
    case "gestures":
        for g in gestures { print("\(g.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(g.help)") }
    case "keys":
        print("modifiers: cmd, alt (option), ctrl, shift, fn")
        print("keys:      " + keyCodes.keys.sorted { ($0.count, $0) < ($1.count, $1) }.joined(separator: " "))
        print("aliases:   " + keyAliases.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        print("example:   gesturekeys set tiptap-left 'cmd+shift+['   (quote combos with [ ] ; etc. in zsh)")
    case "check":
        do {
            let b = try parseConfig(readConfigText())
            print("ok — \(b.count) mapping(s)")
        } catch { print("config error: \(error)"); return 1 }
    case "path":
        print(configURL.path)
    default:
        print("""
        gesturekeys — trackpad gestures → keyboard shortcuts

          gesturekeys list                      show current mappings
          gesturekeys set <gesture> <combo>     change one (combo "none" disables)
          gesturekeys gestures                  gestures it can detect
          gesturekeys keys                      key and modifier names
          gesturekeys check                     validate the config file
          gesturekeys path                      print config file path
          gesturekeys run [--debug]             run the daemon (launchd does this)
        """)
        return cmd == "help" || cmd == "--help" || cmd == "-h" ? 0 : 2
    }
    return 0
}
