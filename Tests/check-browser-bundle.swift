// Run after ./build.sh debug:
// swift Tests/check-browser-bundle.swift "build/Nerda Dev.app"
// Add --registered after opening through ./watch.sh once to check Launch Services too.
// Read-only: this never launches an app, registers one or changes a default.
import AppKit
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2,
      let bundle = Bundle(url: URL(filePath: CommandLine.arguments[1])) else {
    print("Usage: swift Tests/check-browser-bundle.swift <app> [--registered]")
    exit(1)
}

var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

let info = bundle.infoDictionary ?? [:]
let declarations = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
let documents = Set(declarations.filter { $0["CFBundleTypeRole"] as? String == "Viewer" }
    .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
let types: [UTType] = [.html, UTType("public.xhtml")!, .pdf]
for type in types {
    check(documents.contains(type.identifier), "Missing document support: \(type.identifier)")
}
let addresses = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
let schemes = Set(addresses.filter { $0["CFBundleTypeRole"] as? String == "Viewer" }
    .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
check(schemes.isSuperset(of: ["http", "https"]), "Missing HTTP/HTTPS support")

let expectedName = bundle.bundleIdentifier == "dev.nerda.browser"
    ? "Nerda Browser" : bundle.bundleURL.deletingPathExtension().lastPathComponent
check(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == expectedName,
      "Incorrect display name; expected \(expectedName)")
let iconName = info["CFBundleIconFile"] as? String ?? ""
let icon = bundle.url(forResource: iconName, withExtension: "icns")
let iconImage = icon.flatMap { NSImage(contentsOf: $0) }
check(iconImage?.isValid == true, "Missing or invalid app icon")
// Menu icons should fill their small canvas, including Retina representations.
let smallIcons = (iconImage?.representations ?? []).compactMap { $0 as? NSBitmapImageRep }
    .filter { $0.size.width <= 32 }
check(smallIcons.count == 4, "Missing 16/32-point app icon representations")
for bitmap in smallIcons {
    let width = bitmap.pixelsWide
    let opaqueWidth = (0..<width).filter {
        (bitmap.colorAt(x: $0, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) >= 0.9
    }.count
    check(Double(opaqueWidth) / Double(width) >= 0.85,
          "App icon has excessive padding at \(Int(bitmap.size.width)) points / \(width) pixels")
}

if CommandLine.arguments.contains("--registered") {
    func containsBundle(_ apps: [URL]) -> Bool {
        apps.contains { $0.standardizedFileURL.resolvingSymlinksInPath()
            == bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath() }
    }
    for scheme in ["http", "https"] {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "\(scheme)://example.com")!)
        check(containsBundle(apps), "Launch Services does not offer this bundle for \(scheme)")
    }
    for type in types {
        check(containsBundle(NSWorkspace.shared.urlsForApplications(toOpen: type)),
              "Launch Services does not offer this bundle for \(type.identifier)")
    }
}

for failure in failures { print("FAIL: \(failure)") }
guard failures.isEmpty else { exit(1) }
print("PASS: \(expectedName) has browser document types, web schemes and its app icon"
      + (CommandLine.arguments.contains("--registered") ? "; Launch Services offers this bundle" : ""))
