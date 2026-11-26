import Foundation

/// Whether pages may use the fonts installed on this Mac beyond its own,
/// as WebKit lets them by default and Safari does. A run turns it off with
/// NERDA_USER_INSTALLED_FONTS=0, read once; the tests do (TestRun.c).
enum UserInstalledFonts {
    static let allowed = ProcessInfo.processInfo.environment["NERDA_USER_INSTALLED_FONTS"] != "0"
}
