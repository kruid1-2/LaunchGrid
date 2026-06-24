import AppKit
import SwiftUI

struct AppIconView: View {
    let app: AppItem
    let layout: LaunchpadLayout
    let iconCache: IconCache
    let canLaunch: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var image: NSImage?
    @State private var requestedPath = ""

    var body: some View {
        Button(action: launchIfAllowed) {
            VStack(spacing: 8) {
                Image(nsImage: image ?? iconCache.placeholderIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: layout.iconSize, height: layout.iconSize)
                    .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 4)

                Text(app.name)
                    .font(.system(size: layout.labelFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: layout.labelWidth, height: layout.labelHeight, alignment: .top)
                    .shadow(color: .black.opacity(0.72), radius: 2, x: 0, y: 1)
            }
            .frame(width: layout.cellWidth, height: layout.cellHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(LaunchGridIconButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .onAppear {
            loadIcon()
        }
        .onChange(of: app.id) { _ in
            image = nil
            loadIcon()
        }
        .accessibilityLabel(app.name)
    }

    private func launchIfAllowed() {
        guard canLaunch else {
            return
        }

        action()
    }

    private func loadIcon() {
        let path = app.normalizedPath
        requestedPath = path
        iconCache.loadIcon(forPath: path) { loadedImage in
            guard requestedPath == path else {
                return
            }

            image = loadedImage
        }
    }
}

extension AppIconView: Equatable {
    static func == (lhs: AppIconView, rhs: AppIconView) -> Bool {
        lhs.app == rhs.app
            && lhs.layout == rhs.layout
            && lhs.canLaunch == rhs.canLaunch
    }
}

private struct LaunchGridIconButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovering ? 1.025 : 1.0))
            .animation(.spring(response: 0.18, dampingFraction: 0.78), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
