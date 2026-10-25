import Foundation

/// Strong passwords made up, and how safe the kept ones are: the Vault
/// window's editor suggests one, and its Security list shows those that are
/// weak, or used on more than one site, where one site's leak opens the rest.
nonisolated enum PasswordCheck {
    enum Strength: Int, Comparable {
        case weak, fair, strong

        static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    /// What is wrong with the passwords kept, by account.
    struct Issues: Equatable {
        var weak: Set<Account> = []
        var reused: Set<Account> = []

        var all: Set<Account> { weak.union(reused) }
    }

    /// As Safari makes them: three groups of six, joined by hyphens, with one
    /// capital and one digit, about 90 bits. No letters that pass for others
    /// (l and 1, o and 0), so it can be read off the screen and typed.
    static func strong() -> String {
        var random = SystemRandomNumberGenerator()
        return strong(using: &random)
    }

    static func strong(using random: inout some RandomNumberGenerator) -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyz")
        let digits = Array("23456789")
        var characters = (0..<18).map { _ in letters.randomElement(using: &random)! }
        let capital = Int.random(in: 0..<18, using: &random)
        var digit = Int.random(in: 0..<17, using: &random)
        if digit >= capital { digit += 1 }
        characters[capital] = Character(characters[capital].uppercased())
        characters[digit] = digits.randomElement(using: &random)!
        return stride(from: 0, to: 18, by: 6).map { String(characters[$0..<$0 + 6]) }.joined(separator: "-")
    }

    /// From how many characters it might have been made of and how long it
    /// is: about 60 bits takes years to guess at a site's leaked hashes, under
    /// 40 hours. One of the passwords everyone tries first is weak however long.
    static func strength(_ password: String) -> Strength {
        guard !common.contains(password.lowercased()) else { return .weak }
        var pool = 0
        if password.contains(where: \.isLowercase) { pool += 26 }
        if password.contains(where: \.isUppercase) { pool += 26 }
        if password.contains(where: \.isNumber) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
        // aaaa, abab: repeats count once.
        let length = min(password.count, Set(password).count * 2)
        let bits = Double(length) * log2(Double(max(pool, 2)))
        return bits < 40 ? .weak : bits < 60 ? .fair : .strong
    }

    /// Weak passwords, and those kept for accounts on more than one site. A
    /// sign-in with another service has no password here to check.
    static func issues(_ logins: [Vault.Login]) -> Issues {
        let passwords = logins.filter { $0.provider == nil && !$0.password.isEmpty }
        var issues = Issues()
        for login in passwords where strength(login.password) == .weak {
            issues.weak.insert(login.account)
        }
        for same in Dictionary(grouping: passwords, by: \.password).values
        where Set(same.map { Site.of($0.host) }).count > 1 {
            issues.reused.formUnion(same.map(\.account))
        }
        return issues
    }

    /// The first of every leaked list.
    private static let common: Set = [
        "123456", "1234567", "12345678", "123456789", "1234567890", "111111", "000000", "123123", "654321",
        "password", "password1", "passw0rd", "qwerty", "qwerty123", "qwertyuiop", "abc123", "iloveyou",
        "admin", "welcome", "letmein", "monkey", "dragon", "football", "baseball", "sunshine", "princess",
    ]
}
