import Foundation
import CreateML
import CoreImage
import AppKit

// Build a deliberately trivial, deterministic training set: flat red vs flat
// blue tiles with a little structured variation so the feature extractor has
// something to key on. This is a FIXTURE, not a taxonomy -- what Walk should
// really classify is the operator's and Andy's call (decision #507).
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
for (label, base) in [("red", (1.0, 0.15, 0.15)), ("blue", (0.15, 0.15, 1.0))] {
    let dir = root.appendingPathComponent(label)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<16 {
        let jitter = Double(i) / 64.0
        let img = NSImage(size: NSSize(width: 96, height: 96))
        img.lockFocus()
        NSColor(red: base.0 - jitter*0.3, green: base.1 + jitter*0.2,
                blue: base.2 - jitter*0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 96, height: 96).fill()
        NSColor(white: jitter, alpha: 1).setFill()
        NSRect(x: Double(i)*2, y: 10, width: 12, height: 12).fill()
        img.unlockFocus()
        let tiff = img.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("\(label)_\(i).png"))
    }
}
print("training data written to \(root.path)")
let t0 = Date()
let clf = try MLImageClassifier(trainingData: .labeledDirectories(at: root))
print("trained in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
let out = root.deletingLastPathComponent().appendingPathComponent("WalkKnownAnswer.mlmodel")
try clf.write(to: out)
let sz = try fm.attributesOfItem(atPath: out.path)[.size] as! Int
print("wrote \(out.path) — \(sz) bytes")
