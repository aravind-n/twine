import SwiftUI

struct FileGitBadge: View {
    let path: String
    let decoration: FileGitDecoration?
    let repository: FileGitRepository?
    @State private var showsDetails = false

    var body: some View {
        if repository != nil || decoration != nil {
            Button {
                showsDetails = true
            } label: {
                HStack(spacing: 3) {
                    if let repository {
                        if let branch = repository.branch {
                            Text(branch).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary).frame(maxWidth: 55)
                        }
                        Text(repository.summary).font(.system(size: 9))
                            .foregroundStyle(
                                repository.error != nil || repository.changes.isEmpty ? Color.secondary : .orange
                            )
                            .fixedSize()
                    } else if let change = decoration?.change {
                        changeGlyphs(change)
                    } else if decoration?.containsChanges == true {
                        if decoration?.containsConflicts == true {
                            glyph("!", color: .red)
                        } else {
                            Circle().fill(.orange).frame(width: 5, height: 5).padding(4)
                        }
                    }
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
        if let repository { return "\(repository.branchLabel) · \(repository.summary)" }
        return decoration?.change?.summary
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
            Text(repository == nil ? "Git status" : "Repository status").font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let repository {
                Text(repository.branchLabel).font(.callout)
                if let error = repository.error {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(repository.summary).font(.callout)
                    Text(repository.history).font(.caption).foregroundStyle(.secondary)
                    if !repository.changes.isEmpty {
                        Divider()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 9) {
                                ForEach(repository.changes) { change in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(
                                            FileEntry(path: change.path, name: "", kind: .file).relativePath(
                                                in: repository.root)
                                        )
                                        .font(.caption).textSelection(.enabled)
                                        Text(change.summary).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 240)
                    }
                }
            } else {
                Text(summary).font(.callout)
                if let original = decoration?.change?.originalPath {
                    Text("Renamed from \(original)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(16).frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("gitStatusDetails")
    }
}
