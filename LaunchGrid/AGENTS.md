# LaunchGrid Repository Instructions

## 1. Product Goal

LaunchGrid is a native macOS application whose goal is to reproduce the appearance and interaction model of the classic macOS Launchpad as closely as reasonably possible.

The project exists primarily for macOS 26, where the classic Launchpad experience is no longer available.

The final product should prioritize:

1. Stability and correctness
2. Preservation of existing working behavior
3. Interaction fidelity to classic Launchpad
4. Visual fidelity to classic Launchpad
5. Performance and maintainability

Do not sacrifice stability merely to imitate undocumented system behavior.

## 2. Platform Requirements

* The macOS Deployment Target must be `26.0`.
* Supporting macOS 25 or earlier is not required.
* Do not add compatibility branches for macOS 25 or earlier.
* Do not intentionally prevent the application from running on future macOS versions.
* Build using the currently installed Xcode version that contains a macOS 26 SDK.
* Use only public Apple APIs.
* The application must support:

  * Intel Mac: `x86_64`
  * Apple Silicon Mac: `arm64`
* Do not configure the project as Apple-Silicon-only.
* Do not exclude `x86_64` from macOS builds.
* Do not exclude `arm64` from macOS builds.
* Prefer Xcode Standard Architectures instead of manually overriding architecture settings without a clear reason.

For normal local Debug builds, building only the active host architecture is acceptable.

For Release verification, build and verify a universal binary containing both:

* `x86_64`
* `arm64`

Do not introduce architecture-specific code unless absolutely necessary.

## 3. Technology Requirements

Use:

* Swift
* SwiftUI for the main interface and reusable views
* AppKit only where necessary for macOS-specific behavior
* `NSWindow` or `NSPanel` for launcher window management
* `NSWorkspace` for application icons and launching applications
* `NSScreen` and `NSEvent.mouseLocation` for current-screen resolution
* Swift concurrency where it improves correctness

Do not use:

* Electron
* JavaScript
* TypeScript
* HTML
* CSS
* WebView-based interfaces
* Catalyst
* Apple private frameworks
* Reverse-engineered Launchpad APIs
* Undocumented system injection
* AppleScript for normal application discovery
* Shell commands as the main application-scanning implementation

Do not add a third-party package unless the user explicitly approves it.

Prefer native frameworks and a small dependency surface.

## 4. Safety Restrictions

Never:

* Modify macOS system files
* Modify the Dock database
* Modify any former Launchpad database
* Delete or uninstall user applications
* Move installed applications
* Write into `/System`
* Disable System Integrity Protection
* Request Full Disk Access without a demonstrated need
* Request Accessibility permission during the initial phases
* Use `sudo` for project setup, building, running, or testing
* Execute destructive shell commands
* Execute destructive Git commands
* Access unrelated personal files
* Change global Xcode settings
* Change unrelated user preferences

Hiding an application inside LaunchGrid must only change LaunchGrid's own configuration. It must never affect the real application bundle.

## 5. Engineering Principles

Before modifying code:

1. Inspect the existing repository structure.
2. Read this `AGENTS.md`.
3. Run `git status`.
4. Inspect the relevant existing files.
5. Identify the smallest change needed.
6. Preserve currently working functionality.

During implementation:

* Make small, focused changes.
* Do not rewrite unrelated working code.
* Do not place the entire application in one Swift file.
* Separate UI, state, services, models, persistence, and window management.
* Avoid force unwraps.
* Avoid force casts.
* Avoid silently swallowing errors.
* Avoid blocking the main thread.
* Keep UI-related observable state on `MainActor`.
* Perform scanning and expensive file work away from the main actor.
* Return UI state updates to `MainActor`.
* Prefer clear code over premature abstraction.
* Do not add unnecessary protocols or generic layers.
* Do not duplicate business logic across views.
* Do not claim a feature works without building and testing it.

When a feature is already working, preserve its behavior unless the current task explicitly requests a change.

## 6. Recommended Project Structure

Maintain a structure similar to:

LaunchGrid/
├── AGENTS.md
├── README.md
├── LaunchGrid.xcodeproj
├── script/
│   ├── build_and_run.sh
│   └── verify_universal.sh
├── LaunchGrid/
│   ├── Application/
│   │   ├── LaunchGridApp.swift
│   │   └── AppDelegate.swift
│   ├── Models/
│   │   └── AppItem.swift
│   ├── Services/
│   │   ├── AppScanner.swift
│   │   ├── AppLauncher.swift
│   │   ├── IconCache.swift
│   │   └── LayoutStore.swift
│   ├── ViewModels/
│   │   └── LauncherViewModel.swift
│   ├── Window/
│   │   ├── LauncherPanel.swift
│   │   ├── LauncherWindowController.swift
│   │   └── MouseScreenResolver.swift
│   ├── Views/
│   │   ├── LauncherView.swift
│   │   ├── AppGridView.swift
│   │   ├── AppIconView.swift
│   │   ├── SearchBarView.swift
│   │   └── EmptyStateView.swift
│   ├── Design/
│   │   └── LaunchpadMetrics.swift
│   ├── Utilities/
│   └── Resources/
│       └── Assets.xcassets
└── LaunchGridTests/

The exact structure may be adjusted when justified, but responsibilities must remain separated.

Do not create empty abstraction files merely to match this tree.

## 7. Application Discovery Rules

Application discovery must inspect these locations:

* `/Applications`
* `/Applications/Utilities`
* `/System/Applications`
* `/System/Applications/Utilities`
* `~/Applications`

Requirements:

* Discover application bundles with the `.app` extension.
* Treat each `.app` bundle as a leaf.
* Do not recursively scan inside an application bundle.
* Skip hidden files and inaccessible entries safely.
* Do not crash if one directory does not exist.
* Do not crash if one application has an invalid `Info.plist`.
* Do not request Full Disk Access merely to scan ordinary application directories.
* Normalize application URLs before deduplication.
* Prefer Bundle Identifier for deduplication.
* Fall back to normalized path when a Bundle Identifier is unavailable.
* Prefer localized display names.
* Fall back in this order:

  1. Localized display name
  2. `CFBundleDisplayName`
  3. `CFBundleName`
  4. Application filename without `.app`
* Avoid displaying obvious internal helper applications.
* Helper filtering must be conservative.
* Do not hide a normal user-facing application merely because part of its name contains a broad keyword.
* Sort deterministically when no saved user order exists.
* Preserve user-defined order when persistence is introduced.
* Newly discovered applications should be appended without destroying existing order.

Scanning must run away from the main actor.

Scanning errors should be recorded and surfaced appropriately without terminating the app.

## 8. Application Model Rules

`AppItem` should remain a lightweight value type.

It should normally contain:

* Stable identifier
* Display name
* Bundle Identifier when available
* Application URL
* Normalized path
* Optional metadata required by later phases

Do not store `NSImage` directly inside a Codable model.

Do not use the array index as the persistent identity of an application.

The identifier should remain stable across launches whenever the application has not changed.

## 9. Icon Loading Rules

Use `NSWorkspace` to obtain application icons.

Requirements:

* Cache icons using `NSCache`.
* Use a normalized application path or stable identifier as the cache key.
* Do not reload icons every time a SwiftUI `body` is evaluated.
* Do not perform expensive icon loading synchronously during grid layout.
* Return a generic application icon if the real icon cannot be loaded.
* Avoid retaining an unlimited number of unnecessarily large image objects.
* Keep icon-loading code outside view layout code.

## 10. Application Launching Rules

Use the public `NSWorkspace` application-launching APIs.

Requirements:

* Launch the application represented by its URL.
* On successful launch, hide the LaunchGrid window.
* Bring the launched application to the foreground where supported.
* If launch fails, keep LaunchGrid stable.
* Present a concise user-facing error.
* Preserve enough error information for debugging logs.
* Do not invoke applications through arbitrary shell commands.
* Do not use `open` as the primary application-launching implementation inside the app.

## 11. Window Management Rules

The launcher must use an AppKit-managed borderless overlay window or panel.

Requirements:

* No title bar
* No traffic-light buttons
* No standard window border
* Do not enter a separate native macOS full-screen Space
* Cover the target screen using its screen frame
* Open on the display currently containing the mouse pointer
* Fall back safely if no matching screen is found
* Become key when shown so search can accept input
* Hide rather than terminate when dismissed
* Support being shown again without recreating unnecessary global state
* Avoid visible flashing when showing or hiding
* Avoid appearing in normal window cycling where practical
* Do not use `screenSaver` window level
* Do not interfere with system security dialogs
* Do not trap the user in the launcher

When appropriate, consider public window collection behaviors such as:

* `canJoinAllSpaces`
* `fullScreenAuxiliary`
* `transient`
* `ignoresCycle`

Do not add a window behavior merely because it appears in this list. Verify its actual effect.

The application should remain a normal Dock application during the MVP phase.

Do not convert it into an agent-only application unless explicitly requested later.

## 12. Keyboard and Dismissal Rules

Expected MVP behavior:

* `Escape` clears a non-empty search first.
* `Escape` hides the launcher when the search is already empty.
* `Command-F` focuses the search field.
* `Return` may launch the first valid search result.
* Clicking an application launches it.
* Clicking the true background may hide the launcher.
* Clicking an icon, search field, folder, or interactive control must not accidentally trigger background dismissal.
* Launching an application hides the launcher.
* `Command-Q` quits LaunchGrid normally.

Keyboard handling should not rely on inaccessible private event taps.

A global hotkey is a later phase and must not be implemented prematurely.

## 13. Search Rules

Search must:

* Update interactively
* Be case-insensitive
* Match the displayed application name
* Optionally match the Bundle Identifier
* Avoid expensive rescanning
* Avoid mutating the underlying full application collection
* Preserve stable result identity
* Display a clear empty state
* Remain responsive with several hundred applications

The search field should receive focus when the launcher is shown, provided doing so does not create unstable window behavior.

## 14. UI and Visual Fidelity Rules

The long-term visual target is classic macOS Launchpad.

However:

* Functional correctness comes before visual imitation.
* Do not invent exact visual measurements when no reference image is available.
* When reference screenshots are supplied, inspect them before modifying visual metrics.
* Centralize adjustable layout values in a dedicated metrics structure.
* Do not scatter icon size, spacing, corner radius, and animation constants across multiple views.
* Support different display sizes and scale factors.
* Avoid layouts that only work at one fixed resolution.
* Respect reduced-motion and accessibility settings where practical.
* Use native materials and public visual-effect APIs.
* Do not use private wallpaper APIs.

The MVP may temporarily use a vertically scrollable grid.

After the pagination phase is implemented, the normal launcher experience should use Launchpad-style pages rather than an endless vertical list.

Visual refinements must not rewrite the application scanner, launcher, or persistence layers.

## 15. Performance Rules

The project should remain responsive with at least several hundred discovered applications.

Requirements:

* Do not scan application directories inside SwiftUI view rendering.
* Do not load every icon repeatedly.
* Do not perform filesystem enumeration on the main thread.
* Avoid unnecessary whole-array reconstruction during simple hover state changes.
* Avoid one global animation applied indiscriminately to the entire application tree.
* Cancel or coalesce obsolete scanning tasks where appropriate.
* Prefer incremental state updates only when they do not create unstable ordering.
* Measure before introducing complex optimization.

## 16. Error Handling and Logging

Handle at least:

* Missing application directories
* Permission-denied entries
* Invalid application bundles
* Missing Bundle Identifiers
* Duplicate applications
* Failed icon loading
* Failed application launch
* Empty scan results
* Window creation failure
* Screen configuration changes
* Damaged persistence files when persistence is introduced

Errors should:

* Not crash the app
* Be understandable in logs
* Produce a concise user-facing message when user action is affected
* Avoid exposing unrelated private paths unnecessarily

Do not fill the codebase with permanent debug `print` statements.

Use structured or clearly categorized logging when practical.

## 17. Dependency Policy

Do not add third-party dependencies by default.

Before adding one:

1. Explain the exact problem it solves.
2. Explain why Apple frameworks are insufficient.
3. Verify macOS 26 support.
4. Verify both `x86_64` and `arm64` support.
5. Check whether it complicates signing or distribution.
6. Obtain explicit user approval.

Do not add an entire framework for a small utility that can be implemented safely in a limited amount of native code.

## 18. Build Configuration

The project must use:

* `MACOSX_DEPLOYMENT_TARGET = 26.0`
* Standard macOS architectures
* No intentional exclusion of `x86_64`
* No intentional exclusion of `arm64`
* A consistent application product name: `LaunchGrid`

Do not modify build settings blindly.

Before changing a build setting:

1. Inspect its current value.
2. Explain why it must change.
3. Make the smallest required adjustment.
4. Rebuild.
5. Confirm the result.

Local Debug builds may use the current host architecture.

Release verification must include a universal build when the installed toolchain supports it.

## 19. Build Scripts

Create:

`script/build_and_run.sh`

The script should:

* Use `set -euo pipefail`
* Determine the repository root dynamically
* Avoid user-specific absolute paths
* Stop an older LaunchGrid process safely
* Run `xcodebuild`
* Stop immediately on build failure
* Locate the newly built `.app`
* Launch the newly built application
* Print the resulting application path
* Never use `sudo`
* Never delete unrelated DerivedData
* Remain usable on an Intel development Mac

Prefer a repository-local DerivedData directory such as:

`.build/DerivedData`

Add repository-generated build output to `.gitignore`.

Also create when universal verification is introduced:

`script/verify_universal.sh`

It should:

* Perform a Release build for generic macOS
* Request both `x86_64` and `arm64`
* Locate the executable inside the built `.app`
* Run `lipo -archs`
* Fail clearly if either required architecture is missing

Do not run a full universal Release build after every minor UI edit. Use it at meaningful phase checkpoints.

## 20. Standard Validation Commands

Before the first build, inspect the environment with commands such as:

```bash
xcodebuild -version
sw_vers
uname -m
xcodebuild -list -project LaunchGrid.xcodeproj
```

Normal Debug build:

```bash
xcodebuild \
  -project LaunchGrid.xcodeproj \
  -scheme LaunchGrid \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Preferred project script after it exists:

```bash
./script/build_and_run.sh
```

Universal Release verification at phase checkpoints:

```bash
xcodebuild \
  -project LaunchGrid.xcodeproj \
  -scheme LaunchGrid \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS='x86_64 arm64' \
  ONLY_ACTIVE_ARCH=NO \
  build
```

Verify the produced executable:

```bash
lipo -archs /path/to/LaunchGrid.app/Contents/MacOS/LaunchGrid
```

Do not copy placeholder paths literally into permanent scripts.

Resolve actual build paths programmatically.

## 21. Testing Requirements

After each implementation task:

1. Build the project.
2. Fix all compilation errors.
3. Launch the newest build.
4. Test the behavior changed in the current task.
5. Perform a small regression test.
6. Inspect relevant logs.
7. Review the Git diff.
8. Report anything that could not be verified.

Core regression checks once those features exist:

* Application scanning still works
* Real application icons still appear
* Search still filters results
* Clicking an application still launches it
* Successful launch hides LaunchGrid
* `Escape` still clears or dismisses correctly
* The launcher can be reopened
* The window appears on the expected display
* The app does not obviously block the main thread
* No new obvious console errors appear

Do not report a GUI action as tested unless it was actually performed.

If GUI automation or Computer Use is unavailable, state that manual UI verification remains necessary.

## 22. Git Rules

If the repository is not yet a Git repository, initialize it.

Create an appropriate `.gitignore` covering at least:

* `.DS_Store`
* `.build/`
* `DerivedData/`
* `xcuserdata/`
* User-specific Xcode state
* Temporary logs
* Local build products

Before modifications:

```bash
git status
```

After modifications:

```bash
git diff --stat
git diff
```

Rules:

* Never run `git reset --hard`.
* Never run `git clean -fd`.
* Never discard user changes.
* Never overwrite an unrelated branch.
* Never force-push.
* Never push to a remote without explicit permission.
* Keep commits focused on one development phase.
* Create a local checkpoint before a large refactor.
* Only create a phase-completion commit after the project builds successfully.
* Do not commit generated build products.
* Do not include unrelated modifications in a feature commit.

Suggested commit style:

* `chore: scaffold native macOS project`
* `feat: discover installed applications`
* `feat: launch applications from grid`
* `feat: add application search`
* `feat: add launcher overlay window`
* `style: match classic Launchpad layout`
* `feat: add pagination`
* `feat: add persistent app reordering`
* `feat: add Launchpad-style folders`

## 23. Development Phases

Development order:

### Phase 0 — Project Foundation

* Create the Xcode project
* Configure macOS 26.0 deployment target
* Establish project structure
* Add `AGENTS.md`
* Add `.gitignore`
* Add build-and-run script
* Confirm the project builds and launches

### Phase 1 — Runnable MVP

* Discover installed applications
* Display real application icons
* Display application names
* Show applications in a grid
* Launch an application when clicked
* Add search
* Add the borderless overlay window
* Support `Escape` dismissal
* Hide LaunchGrid after successful launch

### Phase 2 — Visual Matching

* Match classic Launchpad proportions
* Refine background material
* Refine search appearance
* Refine icon and label sizing
* Refine spacing and safe areas
* Add controlled presentation and dismissal animations

### Phase 3 — Pagination

* Calculate page capacity
* Add horizontal pages
* Add page indicators
* Support mouse and trackpad page navigation
* Preserve stable page assignment

### Phase 4 — Reordering

* Add drag reordering
* Animate surrounding icons
* Persist positions
* Preserve ordering after application rescans

### Phase 5 — Cross-Page Dragging

* Edge-triggered page changes
* Stable drag state
* Safe cancellation behavior
* Persistent cross-page placement

### Phase 6 — Folders

* Create folders by dragging one application onto another
* Open and close folders
* Rename folders
* Move applications into and out of folders
* Remove empty folders safely

### Phase 7 — System Integration

* Global keyboard shortcut
* Optional menu bar entry
* Login item
* Automatic application-list refresh
* Final performance and accessibility review

Do not begin a later phase merely because its code seems convenient.

Complete and validate the current phase first.

## 24. Current Active Scope

The current active scope is:

* Phase 0
* Phase 1

Implement only the project foundation and runnable MVP.

Do not currently implement:

* Horizontal pagination
* Page indicator dots
* Drag reordering
* Cross-page dragging
* Folders
* Global hotkeys
* Trackpad gesture interception
* Login items
* A settings window
* Custom persistence beyond what is strictly needed
* Complex visual animation
* Private system integration

A basic scrollable grid is acceptable temporarily during the MVP.

Do not update the active scope unless the user explicitly requests the next phase.

## 25. Current Acceptance Criteria

The current phase is complete only when:

1. `LaunchGrid.xcodeproj` exists.
2. Deployment Target is `26.0`.
3. The project builds on the current Intel Mac.
4. The application launches successfully.
5. Installed applications are discovered.
6. Real application icons are displayed.
7. Application names are displayed.
8. Search filters applications.
9. Clicking an application launches it.
10. Successful application launch hides LaunchGrid.
11. `Escape` clears search or hides the launcher.
12. The launcher can be reopened.
13. Expensive scanning does not run on the main actor.
14. No obvious crash occurs during normal use.
15. Existing working behavior remains intact.
16. The implementation is separated into appropriate files.
17. The executed commands and test results are reported honestly.

Universal `x86_64 + arm64` Release verification is required at a meaningful phase checkpoint, but failure to run an arm64 binary on the Intel host must not be misrepresented as a failure of the arm64 build itself.

## 26. Definition of Done

A task is not complete merely because code was generated.

A task is complete only when:

* The requested scope has been implemented.
* The project compiles.
* The latest build launches.
* The changed behavior was tested where possible.
* Relevant core behavior was regression-tested.
* The Git diff was reviewed.
* No unrelated code was rewritten.
* Created and modified files are listed.
* Actual commands executed are listed.
* Build and test results are stated accurately.
* Remaining limitations are disclosed.
* No prohibited future-phase feature was added.

## 27. Required Completion Report

At the end of every task, report:

### Files

* Files created
* Files modified
* Files deleted, if any, with justification

### Commands

* Exact build commands executed
* Exact test or launch commands executed
* Relevant Git inspection commands executed

### Results

* Whether compilation succeeded
* Whether the app launched
* What behavior was actually tested
* What behavior remains manually unverified

### Architecture

At meaningful phase checkpoints, report:

* Deployment Target
* Debug build architecture
* Release build architectures
* Result of `lipo -archs` when universal verification was performed

### Remaining Issues

* Known bugs
* Known visual differences
* Deferred features
* Any environment or permission limitation

Never hide an unresolved error and never describe an unverified feature as complete.

## Active Paging Runtime (Important)

The live launcher page renderer is:

`LauncherPanel.sendEvent` → `PagingInputController` (`Window/PagingEventView.swift`) → `PagingSurfaceController` → `PageSurfaceView`.

`LauncherView` only renders the background, search UI, status UI, an empty paging placeholder, and the page indicator.

The following SwiftUI page types are legacy/reference code and are not used by the visible runtime paging surface:

- `Views/AppGridView.swift`
- `Views/AppIconView.swift`
- `Views/AppPageView.swift`
- `Views/AppPageHostingView.swift`
- legacy animation methods in `PagerViewModel`

Do not attempt to tune the live paging animation by editing those legacy paths. Motion changes must be made in `PagingSurfaceController`, `PagingGestureDriver`, or `PagingInputController`.
