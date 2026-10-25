import SwiftUI

/// After a sign-in that worked: keep its password?
struct PasswordOfferBar: View {
    let browser: Browser
    let offer: PasswordOffer

    var body: some View {
        OfferBar(icon: "key.fill", title: offer.replaces ? "Update the saved password?" : "Save this password?",
                 detail: offer.account.user.isEmpty ? offer.account.host : "\(offer.account.user) on \(offer.account.host)") {
            Button("Never for This Site", action: browser.neverSavePasswords)
            Button("Not Now", action: browser.dropPasswordOffer)
            Button(offer.replaces ? "Update" : "Save", action: browser.keepOfferedPassword)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Something a page sent, offered to keep, over the top of the page.
struct OfferBar<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(Palette.muted)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            // As wide as it says, up to a point: long names give way in the middle.
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, 8)
            actions
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .glassPanel(cornerRadius: 18)
    }
}
