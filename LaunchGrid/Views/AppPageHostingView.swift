// LEGACY RUNTIME NOTE: This SwiftUI page type is not used by the visible launcher
// paging surface. The active renderer is PagingSurfaceController + PageSurfaceView.
import AppKit
import SwiftUI

struct AppPageHostingView: NSViewRepresentable {
    let pageID: Int
    let apps: [AppItem]?
    let layout: LaunchpadLayout
    let iconCache: IconCache
    let canLaunchApps: Bool
    let onLaunch: (AppItem) -> Void
    let onHostingViewChanged: (NSView?) -> Void

    func makeNSView(context: Context) -> ContainerView {
        let containerView = ContainerView()
        containerView.wantsLayer = true
        containerView.layer?.name = "LaunchGridRealPageContainerLayer"
        containerView.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: pageRootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.name = "LaunchGridRealPageHostingLayer"
        hostingView.layer?.masksToBounds = true
        containerView.hostingView = hostingView
        containerView.onDismantle = {
            onHostingViewChanged(nil)
        }
        containerView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        onHostingViewChanged(containerView)

        return containerView
    }

    func updateNSView(_ containerView: ContainerView, context: Context) {
        containerView.hostingView?.rootView = pageRootView
        containerView.layer?.masksToBounds = true
        containerView.hostingView?.layer?.masksToBounds = true

        onHostingViewChanged(containerView)
    }

    static func dismantleNSView(_ nsView: ContainerView, coordinator: ()) {
        nsView.onDismantle?()
    }

    private var pageRootView: AnyView {
        guard let apps else {
            return AnyView(
                Color.clear
                    .frame(width: layout.pageWidth, height: layout.gridHeight)
            )
        }

        return AnyView(
            AppPageView(
                apps: apps,
                layout: layout,
                iconCache: iconCache,
                canLaunchApps: canLaunchApps,
                onLaunch: onLaunch
            )
            .frame(width: layout.pageWidth, height: layout.gridHeight)
            .id(pageID)
        )
    }

    final class ContainerView: NSView {
        var hostingView: NSHostingView<AnyView>?
        var onDismantle: (() -> Void)?

        override var isFlipped: Bool {
            true
        }
    }
}
