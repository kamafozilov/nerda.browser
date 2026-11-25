import Foundation
import UserNotifications

/// A notification telling the owner an Agent needs them (`OwnerRequests`).
nonisolated struct AgentNotice: Equatable, Sendable {
    /// The request's: a notice shown again takes the place of the last.
    let id: String
    let title: String
    let subtitle: String
    let body: String
    /// A question's choices, as the notification's buttons.
    var choices: [String] = []

    /// The button for the choice at `index`.
    static func choiceAction(_ index: Int) -> String { "choice.\(index)" }

    /// The choice a button stands for.
    static func choice(of action: String) -> Int? {
        action.hasPrefix("choice.") ? Int(action.dropFirst("choice.".count)) : nil
    }
}

/// Where notices go: the Mac's notifications in the app, a list in tests,
/// which must post none of the Mac's.
@MainActor
protocol AgentNotifier: AnyObject {
    /// Shows it, or shows it again; never brings Nerda forward.
    func post(_ notice: AgentNotice)
    /// Takes it away, shown or not.
    func withdraw(_ id: String)
}

/// The Mac's notifications, time-sensitive so Focus lets them through
/// where the Mac allows Nerda that. A click on one comes back through
/// `WebNotifications`' delegate, by `userInfo[key]`.
@MainActor
final class MacAgentNotifier: AgentNotifier {
    /// The `userInfo` key holding the request's id.
    nonisolated static let key = "agentRequest"
    /// The categories of questions on screen, each with its choices as buttons.
    private var categories: [String: UNNotificationCategory] = [:]

    func post(_ notice: AgentNotice) {
        WebNotifications.listen()
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "agents"
        content.userInfo = [Self.key: notice.id]
        let center = UNUserNotificationCenter.current()
        if !notice.choices.isEmpty {
            let category = "agent.\(notice.id)"
            categories[category] = UNNotificationCategory(
                identifier: category,
                actions: notice.choices.enumerated().map {
                    UNNotificationAction(identifier: AgentNotice.choiceAction($0.offset), title: $0.element)
                },
                intentIdentifiers: []
            )
            content.categoryIdentifier = category
            center.setNotificationCategories(Set(categories.values))
        }
        let request = UNNotificationRequest(identifier: "agent.\(notice.id)", content: content, trigger: nil)
        Task {
            // Asks the Mac once, the first time; after that it only answers.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    func withdraw(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["agent.\(id)"])
        center.removeDeliveredNotifications(withIdentifiers: ["agent.\(id)"])
        if categories.removeValue(forKey: "agent.\(id)") != nil {
            center.setNotificationCategories(Set(categories.values))
        }
    }
}
