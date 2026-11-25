import SwiftUI

/// The line at the foot of an Agent tab's page while its Agent waits on the
/// owner there: what it asks, with Done (and Skip, when optional) for a
/// Handoff, or the choices for a question.
struct HandoffBar: View {
    let request: OwnerRequest
    let owner: OwnerRequests

    var body: some View {
        OfferBar(icon: request.isHandoff ? "hand.raised" : "questionmark.bubble", title: request.title,
                 detail: request.text) {
            if request.isHandoff {
                if request.canSkip { Button("Skip") { owner.skip(request) } }
                Button("Done") { owner.done(request) }
                    .buttonStyle(.borderedProminent)
            } else {
                ForEach(Array(request.choices.enumerated()), id: \.offset) { choice in
                    Button(choice.element) { owner.pick(request, choice.offset) }
                }
            }
        }
    }
}
