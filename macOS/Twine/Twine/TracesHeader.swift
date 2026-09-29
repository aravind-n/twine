import SwiftUI

/// The collapsed panel. Trace data and expansion arrive with TWINE-23.
struct TracesHeader: View {
    var body: some View {
        HStack {
            Text("Traces")
                .panelTitleStyle()
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: TracesLayout.chevronSize, height: TracesLayout.chevronSize)
                .glassEffect(in: .rect(cornerRadius: CornerRadius.glassIconButton))
        }
        .padding(.horizontal, TracesLayout.headerHorizontalPadding)
        .frame(height: TracesLayout.collapsedHeight)
        .background(.terminalBackground, in: .rect(cornerRadius: CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.panel)
                .strokeBorder(.tracesPanelHairline, lineWidth: Surface.hairlineWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Traces, collapsed")
        .accessibilityIdentifier("tracesHeader")
    }
}
