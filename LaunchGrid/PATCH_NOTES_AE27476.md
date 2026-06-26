# LaunchGrid ae27476 Review Patch

## Root findings

1. The active animation does **not** use `AppPageView`, `AppGridView`, `AppIconView`, or `PagerViewModel.stepPage`. The live path is `PagingInputController` → `PagingSurfaceController` → `PageSurfaceView`. Editing the legacy SwiftUI path produces no visible change.
2. The settle animation used a `CASpringAnimation` whose natural spring curve was forcibly truncated to `0.14...0.28s`. That can end before the spring has actually settled, causing a hard stop when slots rotate.
3. The input fallback waited `0.34s` before finalizing gestures when phase information was incomplete, which can feel sticky.
4. The final row's label layout exceeded the short-display cell height (`80 + 8 + 36 > 120`), so the last few points were outside the page surface. Window-level click classification also depended on view-coordinate hit testing while the page was visually moved by a layer transform.
5. Loading a batch of offscreen icons could request many whole-page redraws during paging.

## Changes

- Added the active runtime documentation to `AGENTS.md`.
- Reduced gesture fallback debounce from `0.34s` to `0.14s`.
- Lowered tracking response time from `0.012s` to `0.008s`.
- Replaced the truncated spring timing with a complete near-critically-damped spring curve, speed-scaled to a dynamic settle duration.
- Adjusted spring values and duration range for a softer finish.
- Compensated app hit testing for the visible Core Animation translation.
- Routed completed app clicks at the window level so the final row does not depend on AppKit delivering the final mouse-up to a transformed page view.
- Made the label gap fit inside `cellHeight`; the final row no longer draws beyond the page surface.
- Coalesced icon-triggered redraws and preloaded farther neighboring pages.

## Local verification needed on macOS

1. Build with `./script/build_and_run.sh --verify`.
2. Click every icon in the final row, including its label area.
3. Click gaps around the final row and confirm the launcher closes rather than opening an app.
4. Test slow release, fast release, and interrupted settle animations.
5. Confirm quick consecutive paging still works.
6. Compare the end of the animation for a hard snap.

This environment cannot run AppKit or Xcode, so the project was syntax-parsed only.
