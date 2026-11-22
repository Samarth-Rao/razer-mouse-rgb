// Control the RGB lighting on Razer mice on macOS, no Synapse needed. Run with no arguments for help.
// Uses the Razer HID lighting protocol as documented by OpenRazer (github.com/openrazer/openrazer).
import Foundation
import IOKit.hid

let usage = """
usage: swift razer-rgb.swift <command> [zone]
  status                         show what each zone is set to
  off                            turn the lighting off
  undo                           go back to the lighting before the last change
  static <color>                 one solid color
  spectrum                       cycle through all colors (Razer's default)
  wave                           rainbow wave
  cycle <color> <color>... [sec] fade through your own colors, sec seconds each (default 2).
                                 Runs until Ctrl-C. Example: "cycle red off" breathes red.
  brightness <0-100>

color: red, orange, yellow, green, cyan, blue, purple, pink, white, off, or hex like ff8800
zone:  scroll, logo, underglow, backlight, left-side, right-side (default: all)
Everything except cycle is saved to the mouse, so it stays after unplugging, rebooting or
moving the mouse to another computer.
"""

// USB product ids of Razer mice that use the extended lighting protocol, per OpenRazer: every
// Basilisk, plus DeathAdder V2/Elite/Essential, Viper, Naga, Cobra, Lancehead, Mamba, Pro Click.
let mice: Set<Int> = [
    0x0053, 0x0059, 0x005A, 0x005C, 0x0060, 0x0064, 0x0065, 0x0067, 0x006A, 0x006B,
    0x006C, 0x006E, 0x006F, 0x0070, 0x0071, 0x0072, 0x0073, 0x0078, 0x007A, 0x007B,
    0x007C, 0x007D, 0x0084, 0x0085, 0x0086, 0x0088, 0x008A, 0x008C, 0x008D, 0x008F,
    0x0090, 0x0091, 0x0096, 0x0098, 0x0099, 0x00A1, 0x00A3, 0x00A7, 0x00A8, 0x00AA,
    0x00AB, 0x00AF, 0x00B0, 0x00B9, 0x00C7, 0x00C8, 0x00CB, 0x00CC, 0x00CD, 0x00D0,
    0x00D1, 0x00D3, 0x00D4, 0x00D6, 0x00D7, 0x00DA, 0x00DB,
]
let zoneNames: [UInt8: String] = [0x01: "scroll", 0x04: "logo", 0x05: "backlight", 0x0A: "underglow", 0x10: "right-side", 0x11: "left-side"]
let effectNames: [UInt8: String] = [0x01: "static", 0x02: "breathing", 0x03: "spectrum", 0x04: "wave", 0x05: "reactive", 0x07: "starlight"]
let colorNames = ["red": "ff0000", "orange": "ff6000", "yellow": "ffd000", "green": "00ff00", "cyan": "00ffff",
                  "blue": "0000ff", "purple": "8000ff", "pink": "ff40a0", "white": "ffffff", "off": "000000"]
// Lighting to return to on `undo`, one line per zone: "<product id>-<zone> <brightness><effect bytes>" in hex.
let backupFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".razer-rgb-undo")

// Sends a 90-byte lighting command; returns the reply's arguments if the mouse confirms it.
func send(_ mouse: IOHIDDevice, _ tid: UInt8, _ command: UInt8, _ args: [UInt8]) -> [UInt8]? {
    var request = [UInt8](repeating: 0, count: 90)
    request[1] = tid                            // transaction id
    request[5] = UInt8(args.count)              // data size
    request[6] = 0x0F                           // command class: lighting
    request[7] = command
    request.replaceSubrange(8..<8 + args.count, with: args)
    request[88] = request[2..<88].reduce(0, ^)  // checksum
    for _ in 0..<2 {                            // one retry
        guard IOHIDDeviceSetReport(mouse, kIOHIDReportTypeFeature, 0, request, request.count) == kIOReturnSuccess else { continue }
        var reply = request
        for _ in 0..<100 {
            usleep(2_000)
            var length = reply.count
            guard IOHIDDeviceGetReport(mouse, kIOHIDReportTypeFeature, 0, &reply, &length) == kIOReturnSuccess else { break }
            if reply[0] > 0x01 { break }        // 0x00/0x01 = not done yet
        }
        // 0x02 = success, and the reply must echo this request (not a stale one)
        if reply[0] == 0x02, reply[1] == tid, reply[7] == command, reply[9] == args[1] {
            return Array(reply[8..<8 + min(Int(reply[5]), 80)])
        }
    }
    return nil
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count - 1, by: 2).compactMap { UInt8(hex.dropFirst($0).prefix(2), radix: 16) }
}
func parseColor(_ text: String) -> [UInt8]? {
    let hex = colorNames[text.lowercased()] ?? text.replacingOccurrences(of: "#", with: "")
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

// Parse the command line into what to set on each zone.
var args = Array(CommandLine.arguments.dropFirst())
let onlyZones = Set(zoneNames.filter { args.contains($0.value) }.keys)
args.removeAll { zoneNames.values.contains($0) }
let command = args.first ?? ""
var params = Array(args.dropFirst())
var seconds = 2.0
if command == "cycle", let last = params.last, parseColor(last) == nil, let s = Double(last), s > 0 {
    seconds = s
    params.removeLast()
}
let colors = params.compactMap(parseColor)
let allColors = colors.count == params.count
var effect: [UInt8]?    // [effect id, mode, speed, color count, r, g, b]
var brightness: UInt8?
switch command {
case "status" where params.isEmpty, "undo" where params.isEmpty: break
case "cycle" where allColors && colors.count >= 2: break
case "off" where params.isEmpty: effect = [0x00, 0, 0, 0]; brightness = 0
case "static" where allColors && colors.count == 1: effect = [0x01, 0, 0, 1] + colors[0]
case "spectrum" where params.isEmpty: effect = [0x03, 0, 0, 0]
case "wave" where params.isEmpty: effect = [0x04, 0x01, 0x28, 0]
case "brightness" where params.count == 1 && (0...100).contains(Int(params[0]) ?? -1):
    brightness = UInt8(Int(params[0])! * 255 / 100)
default:
    print(usage)
    exit(2)
}

var saved: [String: String] = [:]
for line in ((try? String(contentsOf: backupFile, encoding: .utf8)) ?? "").split(separator: "\n") {
    let parts = line.split(separator: " ")
    if parts.count == 2 { saved[String(parts[0])] = String(parts[1]) }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532] as CFDictionary)
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter {
    mice.contains(IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int ?? 0)
        && IOHIDDeviceGetProperty($0, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? 0 >= 90
}
if devices.isEmpty {
    print("No supported Razer mouse found.")
    exit(1)
}

var allOK = true
var targets: [(mouse: IOHIDDevice, tid: UInt8, zones: [UInt8])] = []
for mouse in devices {
    IOHIDDeviceOpen(mouse, 0)
    let pid = IOHIDDeviceGetProperty(mouse, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let name = IOHIDDeviceGetProperty(mouse, kIOHIDProductKey as CFString) as? String ?? "Razer mouse"
    // Newer mice use transaction id 0x1F, older ones 0x3F. Find the lighting zones that answer
    // a brightness query (the 0x03 battery LED is left alone).
    var tid: UInt8 = 0
    var zones: [(zone: UInt8, brightness: UInt8)] = []
    for t: UInt8 in [0x1F, 0x3F] where zones.isEmpty {
        tid = t
        for zone in UInt8(0x00)...0x11 where zone != 0x03 && (onlyZones.isEmpty || onlyZones.contains(zone)) {
            if let reply = send(mouse, t, 0x84, [0x01, zone, 0]) { zones.append((zone, reply[2])) }
        }
    }
    print(name + (zones.isEmpty ? ": no lighting zones responded" : ":"))
    allOK = allOK && !zones.isEmpty
    targets.append((mouse, tid, zones.map { $0.zone }))

    for (zone, current) in zones {
        let key = String(format: "%04x-%02x", pid, zone)
        let zoneName = zoneNames[zone] ?? String(format: "zone-%02x", zone)
        // Saved effect: [storage, zone, effect id, mode, speed, color count, r, g, b, ...]
        let state = send(mouse, tid, 0x82, [0x01, zone] + [UInt8](repeating: 0, count: 10)) ?? []
        let isLit = current > 0 && state.count > 5 && state[2] != 0x00

        if command == "status" {
            let colorList = isLit ? (0..<Int(state[5])).compactMap { i in
                state.count >= 9 + 3 * i ? hex(Array(state[6 + 3 * i..<9 + 3 * i])) : nil } : []
            let effectName = !isLit ? "off" : effectNames[state[2]] ?? "effect \(state[2])"
            print("  \(zoneName): " + ([effectName] + colorList).joined(separator: " ")
                  + (isLit ? ", brightness \(Int(current) * 100 / 255)%" : ""))
            continue
        }
        if command == "cycle" {
            // Cycling isn't saved to the mouse (0x00 = don't save); just make sure the zone is visible.
            if current == 0 { _ = send(mouse, tid, 0x04, [0x00, zone, 255]) }
            continue
        }

        var newEffect = effect.map { [0x01, zone] + $0 }  // 0x01 = save to the mouse
        var newBrightness = brightness ?? (current == 0 && effect != nil ? 255 : nil)
        if command == "undo" {
            // Saved lighting, or Razer's default if nothing was saved: spectrum at full brightness.
            let restore = saved[key].map(bytes) ?? [0xFF, 0x00, zone, 0x03, 0, 0, 0]
            newEffect = [0x01, zone] + restore.dropFirst(3)
            newBrightness = restore[0]
        }
        if isLit { saved[key] = hex([current] + state) }  // remember this lighting for undo

        var ok = true
        if let newEffect { ok = send(mouse, tid, 0x02, newEffect) != nil }
        if let newBrightness { ok = send(mouse, tid, 0x04, [0x01, zone, newBrightness]) != nil && ok }
        print("  \(zoneName): " + (ok ? "done" : "failed"))
        allOK = allOK && ok
    }
}
if command != "status" && command != "cycle" {
    try? saved.map { "\($0.key) \($0.value)" }.sorted().joined(separator: "\n").write(to: backupFile, atomically: true, encoding: .utf8)
}

if command == "cycle" && allOK {
    // Fade between the colors in software, as Synapse does, without saving each frame to the mouse.
    print("Cycling (press Ctrl-C to stop; the mouse goes back to its saved lighting when replugged).")
    let start = Date()
    while true {
        let position = Date().timeIntervalSince(start) / seconds
        let from = colors[Int(position) % colors.count], to = colors[(Int(position) + 1) % colors.count]
        let t = position - position.rounded(.down)
        let rgb = (0..<3).map { UInt8((Double(from[$0]) * (1 - t) + Double(to[$0]) * t).rounded()) }
        for target in targets {
            for zone in target.zones { _ = send(target.mouse, target.tid, 0x02, [0x00, zone, 0x01, 0, 0, 1] + rgb) }
        }
        usleep(20_000)
    }
}
exit(allOK ? 0 : 1)
