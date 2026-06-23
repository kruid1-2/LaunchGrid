import AppKit
import SwiftUI

struct AppIconView: View {
    let app: AppItem
    let image: NSImage
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .shadow(color: .black.opacity(0.26), radius: 7, x: 0, y: 4)

                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: 112, height: 34, alignment: .top)
                    .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
            }
            .frame(width: 116, height: 126, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(LaunchGridIconButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(app.name)
    }
}

private struct LaunchGridIconButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : (isHovering ? 1.06 : 1.0))
            .animation(.spring(response: 0.18, dampingFraction: 0.78), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
