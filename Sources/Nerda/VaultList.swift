import SwiftUI

/// The Vault window's middle column: the search, and the sign-ins of the
/// kind picked, each with its site's icon, its name, and a mark for one that
/// signs in with a service or whose password wants looking at again.
struct VaultList<Menu: View>: View {
    let names: [Vault.Name]
    /// How many the Vault holds in all, for the count under the list.
    let total: Int
    let category: VaultCategory
    let issues: PasswordCheck.Issues
    @Binding var query: String
    @Binding var selection: Account?
    let add: () -> Void
    @ViewBuilder let menu: (Account) -> Menu
    let remove: (Account) -> Void

    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search the Vault", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear the Search")
                            .accessibilityLabel("Clear the Search")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button(action: add) { Image(systemName: "plus").font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.borderless)
                    .help("Add a Password or Sign-In")
                    .accessibilityLabel("Add")
            }
            .padding(.horizontal, 12)
            // Level with the kinds' title, below the window's buttons.
            .padding(.top, 48)
            .padding(.bottom, 8)

            Text(category.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            List(selection: $selection) {
                ForEach(names, id: \.account) { name in
                    VaultRow(name: name, flagged: issues.all.contains(name.account))
                        .tag(name.account)
                        .contextMenu { menu(name.account) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onDeleteCommand { if let selection { remove(selection) } }
            .overlay {
                if names.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
            }

            if total > 0 {
                Text(query.isEmpty && category == .all ? (total == 1 ? "1 item" : "\(total) items") : "\(names.count) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        // ⌘F puts the caret in the search, as in any Mac app's list.
        .background {
            Button("") { searching = true }.keyboardShortcut("f").hidden()
        }
    }
}

/// A saved sign-in in the list: its site's icon and name, the user name
/// under them, and at the end the service it signs in with, or a warning.
private struct VaultRow: View {
    let name: Vault.Name
    let flagged: Bool

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(host: name.host, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name.host)
                    .fontWeight(.medium)
                Text(name.user.isEmpty ? "No user name" : name.user)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 4)
            if let provider = SocialSignIn.provider(name.provider) {
                SiteIcon(host: provider.icon, size: 11)
                    .help("Signs in with \(provider.name)")
            } else if flagged {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("This password is weak or used on another site")
            }
        }
        .padding(.vertical, 3)
    }
}
