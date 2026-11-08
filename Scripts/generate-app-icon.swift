#!/usr/bin/env swift
import Foundation

// Export the reviewed brand masters, without recreating or restyling the artwork.
// Run from the repository root. No image-generation service is needed to rebuild.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("Design/Brand")
let assets = root.appendingPathComponent("IllucetApp/Assets.xcassets")

func export(_ sourceName: String, to output: URL, size: Int) throws {
    let sourceURL = sources.appendingPathComponent(sourceName)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", String(size), String(size), sourceURL.path, "--out", output.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}

for color in ["Blue", "Orange", "Purple", "Pink"] {
    let name = "AppIcon" + (color == "Blue" ? "" : color)
    for appearance in ["Light", "Dark", "Tinted"] {
        let master = appearance == "Tinted" ? "Illucet-Tinted.png"
            : "Illucet" + (color == "Blue" ? "" : "-" + color) + "-\(appearance).png"
        try export(master, to: assets.appendingPathComponent("\(name).appiconset/AppIcon-\(appearance).png"), size: 1024)
        if appearance != "Tinted" {
            try export(master, to: assets.appendingPathComponent("IconPreview\(color)\(appearance).imageset/Icon.png"), size: 128)
        }
    }
}
try export("Illucet-Light.png", to: assets.appendingPathComponent("IllucetLaunchBrand.imageset/IllucetLaunchBrand.png"), size: 1024)
try export("Illucet-Dark.png", to: assets.appendingPathComponent("IllucetLaunchBrand.imageset/IllucetLaunchBrand-Dark.png"), size: 1024)
print("Exported four Illucet icon sets, previews and launch artwork from Design/Brand.")
