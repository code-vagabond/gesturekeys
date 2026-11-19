// gesturekeys — trackpad / Magic Mouse gestures → keyboard shortcuts (BetterTouchTool replacement).
//
//   gesturekeys run [--debug]   the daemon (started by launchd)
//   gesturekeys list|set|...    edit ~/.config/gesturekeys/config (see Config.swift)

import AppKit
import ApplicationServices
import Foundation

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first != "run" { exit(runCLI(cliArgs)) }

let debug = cliArgs.contains("--debug")
func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(s)")
    fflush(stdout)
}
// Per-gesture chatter only in --debug, so the log stays small in normal use.
func trace(_ s: @autoclosure () -> String) { if debug { log(s()) } }

// MARK: - Actions

// Guarded by `lock` (read from the multitouch thread and the event tap).
var bindings: [String: Shortcut?] = [:]
var configStamp: Date?

func reloadConfig() {
    let stamp = configMTime()
    if stamp != nil, stamp == configStamp { return }
    configStamp = stamp
    do {
        let b = try parseConfig(readConfigText())
        lock.lock()
        bindings = b
        lock.unlock()
        log("config loaded: " + b.map { "\($0.key)=\($0.value == nil ? "none" : "set")" }.sorted().joined(separator: " "))
    } catch {
        log("config error, keeping previous mappings: \(error)")
    }
}

func send(_ s: Shortcut, _ name: String) {
    trace("fire \(name)")
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: s.key, keyDown: down) else { continue }
        e.flags = s.flags
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - Tuning

let tapMaxDuration = 0.30      // tapping finger must lift within this
let anchorMinRest = 0.10       // resting finger must be down this long before the tap
let anchorMaxMove: Float = 0.04 // normalized units the resting finger may drift
let tapMaxMove: Float = 0.06
let touchFreshness = 0.15      // how recent a touch frame must be to trust finger count
let tapClickWindow = 0.30      // swallow the tap-to-click that trails a TipTap
let clickHold = 0.08           // hold an ambiguous click this long to see if it was a tap

// MARK: - Touch state (written on the multitouch thread, read on main)

struct Contact {
    var start: Double
    var startPos: MTPoint
    var pos: MTPoint
}

struct Candidate {
    let tapperID: Int32
    let anchorID: Int32
    let anchorPos: MTPoint
    var spoiled: String? // why this can no longer be a TipTap
    var clickHeld = false
}

final class DeviceState {
    var contacts: [Int32: Contact] = [:]
    var candidate: Candidate?
    var lastFrame: Double = 0
    var firedTapper: Int32? // tapping finger of the last TipTap that fired
}

let lock = NSLock()
var devices: [UInt64: DeviceState] = [:]
var deviceKeys: [UnsafeMutableRawPointer: UInt64] = [:]
var lastTipTap: Double = -1

func now() -> Double { ProcessInfo.processInfo.systemUptime }

func dist(_ a: MTPoint, _ b: MTPoint) -> Float {
    let dx = a.x - b.x, dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

func handleFrame(_ dev: DeviceState, _ touches: UnsafeBufferPointer<MTTouch>) {
    let t = now()
    dev.lastFrame = t

    var current: [Int32: MTPoint] = [:]
    for touch in touches where touch.state == 4 || touch.state == 5 {
        current[Int32(touch.identifier)] = touch.normalized.position
    }

    // Lifted fingers
    for (id, c) in dev.contacts where current[id] == nil {
        dev.contacts[id] = nil
        guard var cand = dev.candidate else { continue }
        if id == cand.tapperID {
            dev.candidate = nil
            let dur = t - c.start
            var reject: String? = cand.spoiled
            if let anchor = dev.contacts[cand.anchorID] {
                let anchorMove = dist(anchor.pos, cand.anchorPos), tapMove = dist(c.pos, c.startPos)
                if reject != nil {
                } else if dur > tapMaxDuration {
                    reject = String(format: "tap too long %.2fs", dur)
                } else if anchorMove > anchorMaxMove {
                    reject = String(format: "resting finger moved %.3f", anchorMove)
                } else if tapMove > tapMaxMove {
                    reject = String(format: "tapping finger moved %.3f", tapMove)
                }
                let gesture = c.startPos.x < anchor.pos.x ? "tiptap-left" : "tiptap-right"
                if reject == nil, bindings[gesture] ?? nil == nil { reject = "\(gesture) is disabled" }
                if let reject {
                    trace("tiptap rejected: \(reject)")
                } else {
                    let shortcut = bindings[gesture]!!
                    // If the tap-to-click has not arrived yet, swallow it when it does.
                    lastTipTap = cand.clickHeld ? -1 : t
                    dev.firedTapper = cand.tapperID
                    trace(String(format: "tiptap ok (%.2fs)", dur))
                    DispatchQueue.main.async {
                        send(shortcut, gesture)
                    }
                }
            } else {
                trace("tiptap rejected: resting finger lifted")
            }
        } else if id == cand.anchorID {
            cand.spoiled = cand.spoiled ?? "resting finger lifted first"
            dev.candidate = cand
        }
    }

    // New and moving fingers
    for (id, p) in current {
        if dev.contacts[id] != nil {
            dev.contacts[id]!.pos = p
            continue
        }
        let others = dev.contacts
        dev.contacts[id] = Contact(start: t, startPos: p, pos: p)
        if dev.candidate != nil {
            dev.candidate!.spoiled = dev.candidate!.spoiled ?? "third finger landed"
        } else if others.count == 1, let (anchorID, anchor) = others.first {
            if t - anchor.start >= anchorMinRest {
                dev.candidate = Candidate(tapperID: id, anchorID: anchorID, anchorPos: anchor.pos)
                dev.firedTapper = nil
            } else if debug {
                log(String(format: "no tiptap: resting finger only down %.2fs", t - anchor.start))
            }
        } else if others.count == 2, debug {
            log("no tiptap: 2 other contacts already down (thumb/palm?)")
        }
    }

    if current.isEmpty { dev.candidate = nil }
}

// MARK: - MultitouchSupport (private framework, loaded at runtime)

typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<MTTouch>?, Int32, Double, Int32) -> Int32

let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
func sym<T>(_ name: String, _: T.Type) -> T {
    guard let mt, let p = dlsym(mt, name) else { fatalError("MultitouchSupport: missing \(name)") }
    return unsafeBitCast(p, to: T.self)
}

let MTDeviceCreateList = sym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFMutableArray>?).self)
let MTRegisterContactFrameCallback = sym("MTRegisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void).self)
let MTUnregisterContactFrameCallback = sym("MTUnregisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void).self)
let MTDeviceStart = sym("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
let MTDeviceStop = sym("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
let MTDeviceGetDeviceID = sym("MTDeviceGetDeviceID", (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32).self)

let contactCallback: MTCallback = { device, touches, count, _, _ in
    guard let device else { return 0 }
    lock.lock()
    defer { lock.unlock() }
    guard let key = deviceKeys[device], let dev = devices[key] else { return 0 }
    handleFrame(dev, UnsafeBufferPointer(start: touches, count: touches == nil ? 0 : Int(count)))
    return 0
}

var registered: [UnsafeMutableRawPointer] = []

func startDevices() {
    lock.lock()
    defer { lock.unlock() }
    for d in registered {
        MTUnregisterContactFrameCallback(d, contactCallback)
        MTDeviceStop(d)
    }
    registered = []
    deviceKeys = [:]
    devices = [:]

    guard let list = MTDeviceCreateList()?.takeRetainedValue() as? [AnyObject] else {
        log("no multitouch devices found")
        return
    }
    for obj in list {
        let d = Unmanaged.passUnretained(obj).toOpaque()
        var id: UInt64 = 0
        _ = MTDeviceGetDeviceID(d, &id)
        _ = Unmanaged.passUnretained(obj).retain() // keep device alive while registered
        deviceKeys[d] = id
        devices[id] = DeviceState()
        MTRegisterContactFrameCallback(d, contactCallback)
        MTDeviceStart(d, 0)
        registered.append(d)
    }
    log("listening on \(registered.count) multitouch device(s)")
}

func deviceCountSignature() -> Int {
    (MTDeviceCreateList()?.takeRetainedValue() as? [AnyObject])?.count ?? 0
}

// MARK: - Three-finger click via event tap

var swallowUp: Set<CGEventType.RawValue> = []
var eventTap: CFMachPort?

func upType(for down: CGEventType) -> CGEventType {
    switch down {
    case .rightMouseDown: return .rightMouseUp
    case .otherMouseDown: return .otherMouseUp
    default: return .leftMouseUp
    }
}

// A click that lands while a TipTap is in progress is ambiguous: tap-to-click often
// arrives a few ms before the lift frame, and it looks exactly like a physical click
// (pressure 1.0). Hold it briefly: if the tapping finger lifts, it was the tap.
struct HeldClick {
    let down: CGEvent
    var up: CGEvent?
    let device: UInt64
    let tapperID: Int32
}
var held: HeldClick? // main thread only
let replayMarker: Int64 = 0x6765_6B79

func resolveHeld() {
    guard let h = held else { return }
    held = nil
    lock.lock()
    let dev = devices[h.device]
    let fired = dev?.firedTapper == h.tapperID
    if !fired, let dev, dev.candidate?.tapperID == h.tapperID {
        dev.candidate!.spoiled = "physical click"
    }
    lock.unlock()

    if fired {
        if debug { log("held click was the tap, dropped") }
        if h.up == nil { swallowUp.insert(CGEventType.leftMouseUp.rawValue) }
        return
    }
    if debug { log("held click was physical, replayed") }
    for e in [h.down, h.up].compactMap({ $0 }) {
        e.setIntegerValueField(.eventSourceUserData, value: replayMarker)
        e.post(tap: .cghidEventTap)
    }
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == replayMarker {
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseUp, held != nil, held!.up == nil {
        held!.up = event.copy()
        return nil
    }

    if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type), swallowUp.remove(type.rawValue) != nil {
        return nil
    }
    guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) else {
        return Unmanaged.passUnretained(event)
    }

    let t = now()
    lock.lock()
    if t - lastTipTap <= tapClickWindow {
        lastTipTap = -1
        lock.unlock()
        if debug { log("swallowed tap-to-click after tiptap") }
        swallowUp.insert(upType(for: type).rawValue)
        return nil
    }
    var fingers = 0
    var hold: (device: UInt64, tapperID: Int32)?
    for (key, dev) in devices where t - dev.lastFrame <= touchFreshness {
        fingers = max(fingers, dev.contacts.count)
        guard let cand = dev.candidate, cand.spoiled == nil, let tapper = dev.contacts[cand.tapperID] else { continue }
        if type == .leftMouseDown, held == nil, t - tapper.start <= tapMaxDuration {
            dev.candidate!.clickHeld = true
            hold = (key, cand.tapperID)
        } else {
            dev.candidate!.spoiled = "click during tap"
        }
    }
    let threeFinger = bindings["three-finger-click"] ?? nil
    lock.unlock()
    if debug { log("mouse down type=\(type.rawValue) fingers=\(fingers) held=\(hold != nil)") }

    if let hold, let copy = event.copy() {
        held = HeldClick(down: copy, up: nil, device: hold.device, tapperID: hold.tapperID)
        DispatchQueue.main.asyncAfter(deadline: .now() + clickHold) { resolveHeld() }
        return nil
    }

    if fingers >= 3, let threeFinger {
        swallowUp.insert(upType(for: type).rawValue)
        send(threeFinger, "three-finger-click")
        return nil
    }
    return Unmanaged.passUnretained(event)
}

func startEventTap() -> Bool {
    let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
        return false
    }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// MARK: - Main

let trusted = AXIsProcessTrusted() // no prompt: we restart every few seconds until granted
if !trusted {
    log("waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
    // The trust check is cached per process, so exit and let launchd (KeepAlive) restart us.
    Thread.sleep(forTimeInterval: 5)
    exit(1)
}

reloadConfig()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in reloadConfig() }

guard startEventTap() else {
    log("could not create event tap — check Accessibility permission")
    exit(1)
}
startDevices()

// Re-attach after wake and when a Magic Mouse / trackpad (dis)connects.
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    log("woke from sleep, re-attaching devices")
    startDevices()
}
var knownCount = registered.count
Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
    let n = deviceCountSignature()
    if n != knownCount {
        log("device count changed \(knownCount) → \(n)")
        knownCount = n
        startDevices()
    }
}

if debug {
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        lock.lock()
        let summary = devices.map { "\($0.key): \($0.value.contacts.count)" }.joined(separator: ", ")
        lock.unlock()
        log("fingers { \(summary) }")
    }
}

log("gesturekeys running")
RunLoop.main.run()
