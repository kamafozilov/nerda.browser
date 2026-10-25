import SecurityInterface
import SwiftUI

extension Tab {
    /// Why an address couldn't be opened, as the page in its place says it.
    struct Failure {
        let url: URL
        var message: String
        /// The Mac was offline: the page opens again once it is back (`Online`).
        var offline = false
        /// The certificate the site gave, when it was the trouble, for Show Certificate.
        var trust: SecTrust?
        /// The list of dangerous sites it is on, when that kept it from opening.
        var dangerous: String?

        enum Certificate { case expired, notYetValid, wrongHost, selfSigned, untrusted }

        /// A site on a list of dangerous sites, which list, and how to go anyway:
        /// the site's own switch lifts Nerda's lists, that one too.
        static func dangerous(_ url: URL, on list: String) -> Failure {
            let anyway = SiteSettings.supportsSiteBlocking
                ? "turn off Ads and trackers for this site in Site Settings"
                : "turn off Block ads and trackers in Settings › Security & Privacy"
            return Failure(url: url, message: "\(url.host(percentEncoded: false) ?? "This site") is on the \(list), a list of sites known for phishing, scams or malware, so Nerda didn't open it. To open it anyway, \(anyway), then reload.", dangerous: list)
        }

        /// What went wrong, in plain words, for the errors people meet; nil
        /// for the rest, which keep WebKit's own words. `refused`: the server
        /// was reached and turned the connection away.
        nonisolated static func reason(code: Int, host: String, refused: Bool = false, certificate: Certificate? = nil) -> String? {
            switch code {
            case NSURLErrorNotConnectedToInternet:
                return "Your Mac isn't connected to the internet. The page opens once it is."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "Can't find the server at \(host). Check the address for a typo."
            case NSURLErrorTimedOut:
                return "\(host) took too long to answer."
            case NSURLErrorCannotConnectToHost:
                return refused ? "\(host) refused to connect." : "Can't connect to the server at \(host)."
            case NSURLErrorNetworkConnectionLost:
                return "The connection to \(host) was lost."
            case NSURLErrorSecureConnectionFailed:
                return "A secure connection to \(host) can't be made."
            case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
                // Without the certificate to look at, what the error itself says.
                let problem = certificate ?? [NSURLErrorServerCertificateHasBadDate: .expired,
                                              NSURLErrorServerCertificateNotYetValid: .notYetValid][code] ?? .untrusted
                return switch problem {
                case .expired: "The certificate of \(host) has expired."
                case .notYetValid: "The certificate of \(host) isn't valid yet. Check that your Mac's date and time are right."
                case .wrongHost: "The certificate is for another site, not \(host)."
                case .selfSigned: "The certificate of \(host) is signed by the site itself, so your Mac can't check it."
                case .untrusted: "The certificate of \(host) isn't from an issuer your Mac trusts."
                }
            case NSURLErrorClientCertificateRejected:
                return "\(host) didn't accept your certificate."
            case NSURLErrorClientCertificateRequired:
                return "\(host) asks for a certificate to identify you, and none was sent."
            case NSURLErrorFileDoesNotExist:
                return "There's no file at this address."
            default:
                return nil
            }
        }

        /// What is wrong with the certificates a site gave (each as DER, the
        /// site's own first), by the Mac's own check of them as a server's for
        /// `host`, off the main thread: it may wait on the network.
        @concurrent nonisolated static func problem(chain: [Data], host: String) async -> Certificate {
            let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            var trust: SecTrust?
            guard let leaf = certificates.first,
                  SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString),
                                                 &trust) == errSecSuccess, let trust else { return .untrusted }
            var error: CFError?
            guard !SecTrustEvaluateWithError(trust, &error) else { return .untrusted }
            switch error.map(CFErrorGetCode) {
            case Int(errSecCertificateExpired): return .expired
            case Int(errSecCertificateNotValidYet): return .notYetValid
            case Int(errSecHostNameMismatch): return .wrongHost
            default:
                guard let subject = SecCertificateCopyNormalizedSubjectSequence(leaf) as Data? else { return .untrusted }
                return subject == SecCertificateCopyNormalizedIssuerSequence(leaf) as Data? ? .selfSigned : .untrusted
            }
        }
    }
}

/// In place of a page that could not be opened: what went wrong, and what
/// can be done about it, as Safari's and Chrome's say.
struct PageFailure: View {
    /// The buttons find the tab when pressed, as the address bar's do.
    let browser: Browser
    let failure: Tab.Failure

    var body: some View {
        VStack(spacing: 8) {
            Text(failure.dangerous == nil ? "Can't Open This Page" : "Dangerous Site")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text(failure.message)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                if failure.trust != nil, browser.window != nil {
                    PromptButton(title: "Show Certificate", action: showCertificate)
                }
                if browser.selected?.canLeaveFailure == true {
                    PromptButton(title: "Go Back") { browser.selected?.leaveFailure() }
                }
                PromptButton(title: "Reload", prominent: true) { browser.selected?.reload() }
                    .help("Reload  ⌘R")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }

    /// The Mac's own sheet of the certificate and the chain above it, as Safari shows.
    private func showCertificate() {
        guard let trust = failure.trust, let window = browser.window else { return }
        SFCertificatePanel.shared()?.beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                                                trust: trust, showGroup: true)
    }
}

