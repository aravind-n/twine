import SwiftUI

struct MemoryBadge: View {
    let title: String
    var tint = Color.secondary

    init(_ title: String, tint: Color = .secondary) {
        self.title = title
        self.tint = tint
    }

    var body: some View {
        Text(title).font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint).padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.08), in: .capsule)
            .overlay { Capsule().stroke(tint.opacity(0.12), lineWidth: 0.5) }
    }
}

#Preview { MemoryBadge("Codex", tint: .blue).padding() }
