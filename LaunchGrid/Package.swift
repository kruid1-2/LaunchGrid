// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LaunchGrid",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "LaunchGrid", targets: ["LaunchGrid"])
    ],
    targets: [
        .executableTarget(
            name: "LaunchGrid",
            path: ".",
            exclude: [
                "Package.swift",
                "AGENTS.md",
                "PATCH_NOTES.md",
                "PATCH_NOTES_AE27476.md",
                "Resources",
                "script"
            ],
            sources: [
                "LaunchGridApp.swift",
                "AppDelegate.swift",
                "Models/AppItem.swift",
                "Services/AppScanner.swift",
                "Services/AppLauncher.swift",
                "Services/IconCache.swift",
                "ViewModels/LauncherViewModel.swift",
                "ViewModels/PagerViewModel.swift",
                "Window/LauncherPanel.swift",
                "Window/LauncherWindowController.swift",
                "Window/LauncherRootHostingView.swift",
                "Window/PagingEventView.swift",
                "Design/LaunchpadMetrics.swift",
                "Paging/PageSurfaceCache.swift",
                "Paging/PageSurfaceView.swift",
                "Paging/PagingGestureDriver.swift",
                "Paging/PagingSurfaceController.swift",
                "Views/LauncherView.swift",
                "Views/AppGridView.swift",
                "Views/AppPageHostingView.swift",
                "Views/AppPageView.swift",
                "Views/AppIconView.swift",
                "Views/PageIndicatorView.swift",
                "Views/SearchBarView.swift"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
