import SwiftUI

struct MemorySidebar: View {
    @Bindable var model: MemoryModel
    let folder: String
    let isPresented: Bool
    let open: () -> Void
    @FocusState private var scopesHaveFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            MemoryHeader(model: model, isPresented: isPresented, open: open)
            if model.isExpanded {
                scopeTabs
                MemoryFilters(model: model)
                MemorySourceList(model: model, scope: model.scope, folder: folder, open: open)
                    .id(model.scope)
                footer
            }
        }.frame(maxHeight: model.isExpanded ? .infinity : nil, alignment: .top)
    }

    private var scopeTabs: some View {
        HStack(spacing: 2) {
            ForEach(MemoryScope.allCases) { scope in
                Button {
                    model.scope = scope
                    scopesHaveFocus = true
                    open()
                } label: {
                    Text(scope.title.replacingOccurrences(of: " ", with: "\n"))
                        .font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).frame(height: 36).contentShape(.rect)
                        .background(model.scope == scope ? Color.fileSelection : .clear, in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(scope.title)
                .accessibilityAddTraits(model.scope == scope ? [.isSelected] : [])
                .accessibilityIdentifier("memoryScope-\(scope.rawValue)")

            }
        }
        .focusable(interactions: .edit).focused($scopesHaveFocus).focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            moveScope(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveScope(1)
            return .handled
        }
        .padding(3).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.bottom, 10)
        .accessibilityElement(children: .contain).accessibilityLabel("Memory locations")
    }

    private func moveScope(_ delta: Int) {
        guard let index = MemoryScope.allCases.firstIndex(of: model.scope) else { return }
        model.scope = MemoryScope.allCases[(index + delta + MemoryScope.allCases.count) % MemoryScope.allCases.count]
        open()
    }

    private var footer: some View {
        HStack {
            if model.state == .loading { ProgressView().controlSize(.mini) }
            Text("\(model.filteredSources.count) sources · On this Mac").lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                ForEach(Array((model.catalog?.diagnostics ?? []).enumerated()), id: \.offset) { Text($0.element) }
            } label: {
                Image(systemName: "info.circle")
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Checked locations").accessibilityLabel("Checked locations")
                .accessibilityIdentifier("memoryLocations")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
    }
}

#Preview { MemoryViewPreview() }
