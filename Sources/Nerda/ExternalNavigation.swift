import Foundation
import UniformTypeIdentifiers

/// The web links and local documents accepted from Finder, other apps and Open File.
nonisolated enum ExternalNavigation {
    static let documentTypes: [UTType] = [.html, UTType("public.xhtml")!, .pdf]

    static func accepts(_ url: URL) -> Bool {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url.host?.isEmpty == false
        }
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host?.lowercased()),
              let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              documentTypes.contains(where: { type.conforms(to: $0) }),
              FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        else { return false }
        return values.isRegularFile == true
    }
}
