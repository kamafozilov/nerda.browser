import SwiftUI

/// Contact info and cards, as Safari's AutoFill has them: whether Nerda
/// fills them in and offers to keep them, and those kept, to add, change or
/// remove.
struct AutoFillSettings: View {
    /// Of the profile whose Settings is open.
    let autofill: AutoFill
    let edit: (Contact) -> Void
    let editCard: (Card) -> Void

    @AppStorage(AutoFill.addressesKey) private var fillsAddresses = true
    @AppStorage(AutoFill.cardsKey) private var fillsCards = true

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Contact info", detail: "Fill in names, addresses, email and phone numbers, and offer to save new ones",
                        icon: "person.text.rectangle") {
                SettingsToggle(title: "Contact info", isOn: $fillsAddresses)
            }
            SettingsRow(title: "Credit cards", detail: "Fill in after Touch ID or your Mac's password, and offer to save new ones",
                        icon: "creditcard") {
                SettingsToggle(title: "Credit cards", isOn: $fillsCards)
            }
        }
        SettingsGroup(title: "Addresses") {
            ForEach(autofill.addresses) { contact in
                SettingsRow(title: contact.title, detail: contact.summary.isEmpty ? nil : contact.summary, icon: "person.crop.circle") {
                    editButton(for: contact.title) { edit(contact) }
                }
            }
            SettingsRow(title: "Add an address",
                        detail: autofill.addresses.isEmpty ? "Nerda offers to save the address you send in a form, or add one here" : nil,
                        icon: "plus") {
                Button("Add…") { edit(Contact()) }
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
            }
        }
        SettingsGroup(title: "Cards") {
            ForEach(autofill.cards) { card in
                SettingsRow(title: card.title, detail: [card.name, "Expires \(card.expiry)"].filter { !$0.isEmpty }.joined(separator: " · "),
                            icon: "creditcard") {
                    editButton(for: card.title) { editCard(card) }
                }
            }
            SettingsRow(title: "Add a card",
                        detail: autofill.cards.isEmpty ? "Nerda offers to save the card you pay with on a secure page, or add one here" : nil,
                        icon: "plus") {
                Button("Add…") { editCard(Card()) }
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
            }
        }
    }

    private func editButton(for title: String, action: @escaping () -> Void) -> some View {
        Button("Edit…", action: action)
            .buttonStyle(SettingsButtonStyle())
            .fixedSize()
            .accessibilityLabel("Edit \(title)")
    }
}

/// An address added or changed: what forms ask for, in the order they ask it.
struct ContactDialog: View {
    let autofill: AutoFill
    let escapes: Bool
    let done: () -> Void

    @State private var contact: Contact
    @FocusState private var focused: String?

    init(autofill: AutoFill, contact: Contact, escapes: Bool, done: @escaping () -> Void) {
        self.autofill = autofill
        _contact = State(initialValue: contact)
        self.escapes = escapes
        self.done = done
    }

    private var isNew: Bool { !autofill.addresses.contains { $0.id == contact.id } }

    var body: some View {
        SettingsDialog(width: 460, escapes: escapes, cancel: done) {
            Text(isNew ? "New address" : "Edit address")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    field("First name", $contact.givenName)
                    field("Last name", $contact.familyName)
                }
                GridRow { field("Organisation", $contact.organisation, prompt: "Optional").gridCellColumns(2) }
                GridRow { field("Street", $contact.line1).gridCellColumns(2) }
                GridRow { field("Flat, suite or floor", $contact.line2, prompt: "Optional").gridCellColumns(2) }
                GridRow {
                    field("City", $contact.city)
                    field("Region", $contact.region, prompt: "State or county")
                }
                GridRow {
                    field("Postcode", $contact.postalCode)
                    field("Country", $contact.country)
                }
                GridRow {
                    field("Email", $contact.email)
                    field("Phone", $contact.phone)
                }
            }
            .padding(.top, 16)
            HStack(spacing: 8) {
                if !isNew {
                    Button("Remove", role: .destructive) {
                        autofill.remove(contact)
                        done()
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
                Spacer()
                Button("Cancel", action: done)
                    .buttonStyle(SettingsButtonStyle())
                Button("Save", action: save)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .disabled(contact.values.isEmpty)
            }
            .padding(.top, 22)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { focused = "First name" }
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .focused($focused, equals: title)
                .onSubmit(save)
        }
    }

    private func save() {
        var kept = contact
        for key: WritableKeyPath<Contact, String> in [\.givenName, \.familyName, \.organisation, \.line1, \.line2, \.city,
                                                      \.region, \.postalCode, \.country, \.email, \.phone] {
            kept[keyPath: key] = kept[keyPath: key].trimmingCharacters(in: .whitespaces)
        }
        guard !kept.values.isEmpty else { return }
        autofill.save(kept)
        done()
    }
}

/// A card added or changed. A kept card's number shows only as its last
/// digits: one typed in takes its place, and left empty it stays as it is.
struct CardDialog: View {
    let autofill: AutoFill
    let escapes: Bool
    let done: () -> Void

    @State private var card: Card
    @State private var number = ""
    @State private var expiry: String
    @State private var saving = false
    @FocusState private var focused: String?

    init(autofill: AutoFill, card: Card, escapes: Bool, done: @escaping () -> Void) {
        self.autofill = autofill
        _card = State(initialValue: card)
        _expiry = State(initialValue: card.month == 0 ? "" : card.expiry)
        self.escapes = escapes
        self.done = done
    }

    private var isNew: Bool { !autofill.cards.contains { $0.id == card.id } }
    private var digits: String? { CardNumber.digits(number) }
    private var numberWorks: Bool { number.isEmpty ? !isNew : digits.map(CardNumber.isValid) ?? false }
    private var expires: (month: Int, year: Int)? { CardNumber.expiry(expiry) }

    /// Said once something is typed, not while a box is still empty.
    private var problem: String {
        if !number.isEmpty && !numberWorks { return "Check the card number" }
        if !expiry.isEmpty && expires == nil { return "Write the expiry as MM/YY" }
        return " "
    }

    var body: some View {
        SettingsDialog(width: 420, escapes: escapes, cancel: done) {
            Text(isNew ? "New card" : "Edit card")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    field("Card number", $number, prompt: isNew ? "1234 5678 9012 3456" : "Ending in \(card.ending)")
                        .gridCellColumns(2)
                }
                GridRow { field("Name on card", $card.name).gridCellColumns(2) }
                GridRow {
                    field("Expires", $expiry, prompt: "MM/YY")
                    field("Nickname", $card.nickname, prompt: "Optional")
                }
            }
            .padding(.top, 16)
            Text(problem)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.top, 8)
            HStack(spacing: 8) {
                if !isNew {
                    Button("Remove", role: .destructive) {
                        autofill.remove(card)
                        done()
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
                Spacer()
                Button("Cancel", action: done)
                    .buttonStyle(SettingsButtonStyle())
                Button("Save", action: save)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .disabled(!numberWorks || expires == nil || saving)
            }
            .padding(.top, 14)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { focused = isNew ? "Card number" : "Name on card" }
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .focused($focused, equals: title)
                .onSubmit(save)
        }
    }

    private func save() {
        guard numberWorks, let expires, !saving else { return }
        var kept = card
        kept.name = card.name.trimmingCharacters(in: .whitespaces)
        kept.nickname = card.nickname.trimmingCharacters(in: .whitespaces)
        kept.month = expires.month
        kept.year = expires.year
        let typed = number.isEmpty ? nil : digits
        if let typed {
            kept.ending = String(typed.suffix(4))
            kept.brand = CardNumber.brand(of: typed)
        }
        saving = true
        Task {
            let saved = await autofill.save(kept, number: typed)
            saving = false
            if saved { done() } else { Browser.tell("Couldn't save the card", "The keychain didn't take it.") }
        }
    }
}
