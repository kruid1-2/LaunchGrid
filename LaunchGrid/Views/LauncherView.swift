import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel

    let iconCache: IconCache
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                BackgroundClickView(onClick: onDismiss)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(.black.opacity(0.68))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 30) {
                    SearchBarView(text: $viewModel.searchText)
                        .frame(width: min(max(geometry.size.width * 0.32, 260), 320))
                        .padding(.top, 42)

                    statusView

                    AppGridView(
                        apps: viewModel.filteredApps,
                        iconCache: iconCache,
                        onLaunch: { app in
                            viewModel.launch(app, onSuccess: onDismiss)
                        }
                    )
                    .padding(.horizontal, max(56, geometry.size.width * 0.08))
                    .padding(.bottom, 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var statusView: some View {
        if viewModel.isScanning {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.8))
                .frame(height: 20)
        } else if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(height: 20)
        } else {
            Color.clear
                .frame(height: 20)
        }
    }
}

private struct BackgroundClickView: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> ClickCatchingView {
        let view = ClickCatchingView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ClickCatchingView, context: Context) {
        nsView.onClick = onClick
    }
}

private final class ClickCatchingView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

extension Notification.Name {
    static let launchGridFocusSearch = Notification.Name("LaunchGridFocusSearch")
}
