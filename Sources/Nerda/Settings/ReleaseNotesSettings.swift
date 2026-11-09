import SwiftUI

/// What every version brought, from CHANGELOG.md in the bundle, newest
/// first, the one running marked.
struct ReleaseNotesSettings: View {
    var body: some View {
        ForEach(ReleaseNotes.all) { release in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    ReleaseHeading(release: release)
                    if release.version == Updater.current {
                        Text("Installed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 22)
                ReleaseNotesList(notes: release.notes)
                    .padding(16)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
