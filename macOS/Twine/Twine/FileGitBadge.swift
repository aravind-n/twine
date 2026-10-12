import SwiftUI

struct FileGitBadge: View {
    let path: String
    let isDirectory: Bool
    let decoration: FileGitDecoration?
    var containsChanges = false
    @State private var showsDetails = false

    var body: some View {
        if isDirectory {
            if containsChanges || decoration?.containsChanges == true || decoration?.change != nil {
                Circle().fill(.orange).frame(width: 5, height: 5).padding(4)
                    .frame(minWidth: 16, minHeight: SidebarLayout.rowHeight)
                    .help(summary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Git status for \(URL(filePath: path).lastPathComponent): \(summary)")
                    .accessibilityIdentifier("gitStatus-\(path)")
            }
        } else if let change = decoration?.change {
            Button {
                showsDetails = true
            } label: {
                HStack(spacing: 3) {
                    changeGlyphs(change)
                }
                .frame(minWidth: 16, minHeight: SidebarLayout.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(summary)
            .accessibilityLabel("Git status for \(URL(filePath: path).lastPathComponent)")
            .accessibilityValue(summary)
            .accessibilityIdentifier("gitStatus-\(path)")
            .popover(isPresented: $showsDetails) { details.appZoom() }
        }
    }

    private var summary: String {
        decoration?.change?.summary
            ?? (decoration?.containsConflicts == true ? "Contains merge conflicts" : "Contains Git changes")
    }

    @ViewBuilder private func changeGlyphs(_ change: FileGitChange) -> some View {
        if change.conflicted {
            glyph("!", color: .red)
        } else {
            if let staged = change.staged { glyph(staged.rawValue, color: color(staged), staged: true) }
            if let unstaged = change.unstaged { glyph(unstaged.rawValue, color: color(unstaged)) }
            if change.untracked { glyph("?", color: .green) }
        }
    }

    private func glyph(_ text: String, color: Color, staged: Bool = false) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color).frame(minWidth: 14, minHeight: 16)
            .background(staged ? color.opacity(0.16) : .clear, in: .rect(cornerRadius: 3))
    }

    private func color(_ kind: FileGitChangeKind) -> Color {
        switch kind {
        case .added, .copied: .green
        case .deleted: .red
        case .renamed: .purple
        case .modified, .typeChanged: .orange
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Git status").font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(summary).font(.callout)
            if let original = decoration?.change?.originalPath {
                Text("Original path: \(original)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(16).frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("gitStatusDetails")
    }
}
