import Security

/// Leave WebKit's native WebAuthn intact in builds Apple has authorized.
/// An unentitled build keeps the password/extension fallback instead.
enum Passkeys {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"
    /// Asked of the kernel, as the first page is made: reading the signature
    /// off disk instead would cost launch time.
    static let available = SecTaskCreateFromSelf(nil)
        .flatMap { SecTaskCopyValueForEntitlement($0, entitlement as CFString, nil) } as? Bool == true
}
