import AppKit
import Security
import WebKit

/// Browsing of its own on this Mac, as Safari's profiles: work kept apart from
/// personal, each with its own cookies and site data, history, bookmarks, open
/// tabs, site settings and saved passwords, and its own window. Personal, the
/// first, keeps what Nerda kept before there were profiles, where it always
/// was: the data folder, the default data store, the `Nerda Passwords`
/// keychain item. Each other one has a folder of its own (`Profiles/<id>`),
/// a data store of its own (`WKWebsiteDataStore(forIdentifier:)`) and a
/// keychain item of its own, read only once its window opens.
@Observable
final class Profile: Identifiable {
    nonisolated static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    /// Personal, there from the start, and never deleted.
    static let main = Profile(id: mainID, name: "Personal", symbol: "person", color: .blue)
    /// What a profile can be marked with (Settings › Profiles), as Safari offers.
    static let symbols = ["person", "briefcase", "house", "graduationcap", "heart", "star",
                          "book", "hammer", "gamecontroller", "airplane", "cart", "leaf"]

    let id: UUID
    var name: String
    var symbol: String
    var color: Palette.Accent
    /// Its window was open: it opens again at the next launch. Personal's
    /// always does, as Nerda's one window did.
    var open = false
    /// Where its files are kept.
    @ObservationIgnored let folder: URL
    var isMain: Bool { id == Self.mainID }

    init(id: UUID = UUID(), name: String, symbol: String, color: Palette.Accent, root: URL = Edition.folder) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        folder = id == Self.mainID ? root : root.appending(path: "Profiles/\(id.uuidString)")
    }

    var sessionFile: URL { folder.appending(path: "session.json") }

    /// Made when first asked for, and let go of when the profile is deleted,
    /// as WebKit removes only a store no longer in use.
    @ObservationIgnored private var store: WKWebsiteDataStore?
    var dataStore: WKWebsiteDataStore {
        if let store { return store }
        let made = isMain ? WKWebsiteDataStore.default() : WKWebsiteDataStore(forIdentifier: id)
        store = made
        return made
    }

    /// The keychain item its passwords are kept in.
    var passwordsService: String { isMain ? "\(Edition.name) Passwords" : "\(Edition.name) Passwords \(id.uuidString)" }

    // Each read the first time it is wanted: as its window opens.
    @ObservationIgnored private(set) lazy var history: History = {
        guard !isMain else { return .shared }
        let history = History()
        history.load(from: folder.appending(path: "history.json"), waiting: false)
        return history
    }()
    @ObservationIgnored private(set) lazy var bookmarks: Bookmarks = {
        guard !isMain else { return .shared }
        let bookmarks = Bookmarks()
        bookmarks.load(from: folder.appending(path: "bookmarks.json"))
        return bookmarks
    }()
    @ObservationIgnored private(set) lazy var siteSettings = isMain ? SiteSettings.shared
        : SiteSettings(defaults: nil, file: folder.appending(path: "site-settings.json"))
    @ObservationIgnored private(set) lazy var vault = isMain ? Vault.shared
        : Vault(service: passwordsService, names: folder.appending(path: "accounts.json"))

    /// Everything it kept, gone from this Mac: its files, its passwords, and
    /// its cookies and site data. Its window is closed first (`Windows.forget`).
    func erase() async {
        guard !isMain else { return }
        // Nothing is written to the folder again, as an import finishing
        // would, and what is on its way lands before it goes.
        history.close()
        bookmarks.close()
        siteSettings.close()
        await vault.close()
        Session.writer.sync {}
        try? FileManager.default.removeItem(at: folder)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: passwordsService] as CFDictionary)
        store = nil
        // Noted before trying, so that quitting meanwhile still leaves it for the next launch.
        Profiles.storesLeft.insert(id)
        if await Self.removeStore(id) { Profiles.storesLeft.remove(id) }
    }

    /// WebKit refuses while a page of the store is still being let go of,
    /// so it is asked again a moment later; false if it still refuses.
    static func removeStore(_ id: UUID) async -> Bool {
        for wait in [0.5, 2, 5] {
            try? await Task.sleep(for: .seconds(wait))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return true
            } catch {
                NSLog("Nerda: couldn't remove a profile's website data yet: \(error)")
            }
        }
        return false
    }
}

/// The profiles there are, Personal first, kept in `profiles.json` beside the
/// history once one is made or changed. Until then there is no file, and
/// nothing to do at launch.
@Observable
final class Profiles {
    static let shared = Profiles(file: Edition.folder.appending(path: "profiles.json"))

    nonisolated struct Saved: Codable, Equatable {
        let id: UUID
        var name: String
        var symbol: String
        var color: String
        var open: Bool?
    }

    private(set) var all: [Profile]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let root: URL

    /// More than Personal: only then does a profile show anywhere but Settings › Profiles.
    var many: Bool { all.count > 1 }

    init(file: URL, root: URL = Edition.folder, main: Profile = .main) {
        self.file = file
        self.root = root
        all = [main]
        guard let data = try? Data(contentsOf: file) else { return }
        guard let saved = try? JSONDecoder().decode([Saved].self, from: data) else {
            // Set aside rather than overwritten: it may be from a newer version.
            try? data.write(to: file.deletingLastPathComponent().appending(path: "profiles-unreadable.json"))
            return
        }
        for entry in saved {
            let color = Palette.Accent(rawValue: entry.color) ?? .blue
            if entry.id == Profile.mainID {
                (main.name, main.symbol, main.color) = (entry.name, entry.symbol, color)
            } else {
                let profile = Profile(id: entry.id, name: entry.name, symbol: entry.symbol, color: color, root: root)
                profile.open = entry.open ?? false
                all.append(profile)
            }
        }
    }

    func profile(_ id: UUID) -> Profile? { all.first { $0.id == id } }

    /// A new one, with no tabs, history or anything else yet.
    @discardableResult
    func add(name: String, symbol: String, color: Palette.Accent) -> Profile {
        let profile = Profile(name: name, symbol: symbol, color: color, root: root)
        all.append(profile)
        save()
        return profile
    }

    /// Gone, and all it kept with it. Personal stays.
    func remove(_ profile: Profile) async {
        guard !profile.isMain, all.contains(where: { $0 === profile }) else { return }
        all.removeAll { $0 === profile }
        save()
        await profile.erase()
    }

    /// Written whole on each change: a name, a symbol, a window opened or closed.
    func save() {
        let saved = all.map { Saved(id: $0.id, name: $0.name, symbol: $0.symbol, color: $0.color.rawValue, open: $0.isMain ? nil : $0.open) }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        } catch {
            NSLog("Nerda: couldn't save profiles: \(error)")
        }
    }

    /// Deleted profiles' website data WebKit wouldn't remove then, tried again at launch.
    private static let storesLeftKey = "profileStoresToRemove"
    static var storesLeft: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: storesLeftKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue.map(\.uuidString), forKey: storesLeftKey) }
    }

    static func removeStoresLeft() {
        let left = storesLeft
        guard !left.isEmpty else { return }
        Task {
            for id in left where await Profile.removeStore(id) { storesLeft.remove(id) }
        }
    }
}
