// Turns off the RGB lighting on a wired Razer Basilisk V3 on macOS, no Synapse needed.
// Run: swift rgb-off.swift
import Foundation
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x0099] as CFDictionary)
let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
guard let mouse = devices.first(where: { IOHIDDeviceGetProperty($0, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int == 90 }) else {
    print("Razer Basilisk V3 not found")
    exit(1)
}
IOHIDDeviceOpen(mouse, 0)

// Sends a Razer 90-byte lighting command (protocol as documented by OpenRazer).
func send(_ command: UInt8, _ args: [UInt8]) -> Bool {
    var report = [UInt8](repeating: 0, count: 90)
    report[1] = 0x1F                          // transaction id
    report[5] = UInt8(args.count)             // data size
    report[6] = 0x0F                          // command class: lighting
    report[7] = command
    report.replaceSubrange(8..<8 + args.count, with: args)
    report[88] = report[2..<88].reduce(0, ^)  // checksum
    guard IOHIDDeviceSetReport(mouse, kIOHIDReportTypeFeature, 0, report, report.count) == kIOReturnSuccess else { return false }
    for _ in 0..<10 {
        usleep(20_000)
        var length = report.count
        IOHIDDeviceGetReport(mouse, kIOHIDReportTypeFeature, 0, &report, &length)
        if report[0] != 0x01 { break }        // 0x01 = busy
    }
    return report[0] == 0x02                  // 0x02 = success
}

var ok = true
for zone: UInt8 in [0x01, 0x04, 0x0A] {                 // scroll wheel, logo, underglow
    ok = send(0x02, [0x01, zone, 0x00, 0, 0, 0]) && ok  // effect: none (0x01 = save to mouse)
    ok = send(0x04, [0x01, zone, 0x00]) && ok           // brightness: 0
}
print(ok ? "Lighting off." : "Some commands failed.")
exit(ok ? 0 : 1)
