# LaunchGrid blank-area paging patch

This patch targets the issue where horizontal paging only works while the pointer is over application cells.

## Static diagnosis

The project combined three conditions that can make blank regions fall outside the useful input surface:

1. `LauncherPanel` used a completely clear backing (`backgroundColor = .clear`).
2. The two full-screen SwiftUI background rectangles explicitly disabled hit testing.
3. `PagingInputController` rejected any event whose `event.window` was not exactly identical to the stored window, even though the event had already entered `LauncherPanel.sendEvent`.

The application cells remained hit-testable, which matches the observed behavior: swiping worked over icons but not over visually blank areas.

## Changes

- Give the borderless panel and root hosting view an imperceptible nonzero backing alpha.
- Make the full-screen SwiftUI background a real hit-test target.
- Pin `NSHostingView` to all four edges of the root content view.
- Keep a single window-level paging entry in `LauncherPanel.sendEvent`.
- Remove the redundant `event.window === window` rejection and validate using the panel frame and global pointer location.
- Accept AppKit `.swipe` events as a fallback when macOS promotes a blank-area gesture instead of delivering raw scroll-wheel deltas.
- Coalesce high-frequency trackpad offsets to one SwiftUI update per main-loop turn.
- Add a compositing boundary around the moving three-page container.

## Files changed

- `Window/LauncherPanel.swift`
- `Window/LauncherRootHostingView.swift`
- `Window/LauncherWindowController.swift`
- `Window/PagingEventView.swift`
- `Views/LauncherView.swift`

## Required validation on macOS

1. Build and launch the app.
2. Test left/right swipes over an icon.
3. Test between icons.
4. Test the far-left and far-right blank areas.
5. Test above and below the grid.
6. Confirm blank clicks still dismiss the launcher.
7. Confirm search and icon clicks still work.
8. Confirm one gesture changes at most one page.
9. Test at least 20 page changes for increasing stutter.

This environment cannot run AppKit or Xcode, so the patch was syntax-parsed only and still requires an actual macOS build/test.
