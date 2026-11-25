import Foundation
import os
import Security

/// Who may drive Nerda over its socket. Three checks, in order: the caller
/// runs as the owner's user (else it gets no answer at all), then its audit
/// token, then its code signature against a requirement, Nerda's own
/// designated one in a release build, so Nerda's own `nerda-browser` (the
/// app's binary in another mode) gets in and other programs get status only
/// (#132 asks the owner about those). A token's verdict is kept, as signature
/// checks cost.
nonisolated final class AgentCallers: Sendable {
    /// What a caller may do.
    enum Access: Sendable, Equatable {
        /// Every verb.
        case full
        /// Only `status`: what Nerda is and whether agents are on.
        case statusOnly
    }

    private let requirement: Requirement?
    private let verdicts = OSAllocatedUnfairLock<[Data: Access]>(initialState: [:])

    /// Every program of the owner's user: development and test builds,
    /// which are signed ad hoc, if at all.
    static let anyone = AgentCallers(requirement: nil)

    /// Programs signed to meet `requirement`, in the code signing language
    /// (`identifier "…" and anchor apple generic and …`).
    convenience init(requiring requirement: String) throws {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else { throw AgentSocket.Failure.system(status) }
        self.init(requirement: Requirement(compiled))
    }

    init(requirement: Requirement?) {
        self.requirement = requirement
    }

    /// The running edition's: anyone in development and test builds, and in
    /// a release build what Nerda's own designated requirement allows.
    static let nerdas: AgentCallers = {
        #if DEBUG
        return .anyone
        #else
        return AgentCallers(requirement: ownRequirement())
        #endif
    }()

    /// The requirement this process's own signature was made to meet; none
    /// when it has no signature to ask, which lets no other program in.
    static func ownRequirement() -> Requirement {
        var me: SecCode?, file: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &file) == errSecSuccess, let file,
              SecCodeCopyDesignatedRequirement(file, [], &requirement) == errSecSuccess, let requirement else {
            Logger.agents.error("No designated requirement of Nerda's own: other programs get status only")
            return Requirement(nil)
        }
        return Requirement(requirement)
    }

    /// What the caller of `connection` may do, nil for another user's
    /// program, which is answered nothing.
    func access(of connection: AgentSocket.Connection) -> Access? {
        guard connection.uid == getuid() else { return nil }
        guard let requirement else { return .full }
        guard let token = connection.token else { return .statusOnly }
        if let known = verdicts.withLock({ $0[token] }) { return known }
        let access: Access = Self.code(of: token).map { requirement.isMet(by: $0) } == true ? .full : .statusOnly
        verdicts.withLock { $0[token] = access }
        return access
    }

    /// The running code of the process behind an audit token.
    private static func code(of token: Data) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// A compiled requirement, or none that anything meets.
    struct Requirement: @unchecked Sendable {
        // Immutable once made; Security reads it from any thread.
        let requirement: SecRequirement?

        init(_ requirement: SecRequirement?) { self.requirement = requirement }

        func isMet(by code: SecCode) -> Bool {
            guard let requirement else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
    }
}
