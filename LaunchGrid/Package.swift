// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LaunchGrid",
    platforms: [
        .macOS(.v13)
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
                ".codex",
                ".build",
                "DerivedData",
                "dist",
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
                "Window/LauncherPanel.swift",
                "Window/LauncherWindowController.swift",
                "Views/LauncherView.swift",
                "Views/AppGridView.swift",
                "Views/AppIconView.swift",
                "Views/SearchBarView.swift"
            ]
        )
    ]
)
