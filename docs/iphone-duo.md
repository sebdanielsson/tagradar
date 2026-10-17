# iPhone Duo and iOS 27

Tågradar on iOS 27 and the foldable iPhone Duo, announced 2026-09-09 and shipping 2026-10-23.

## Toolchain

| Target | Needs | Status |
| --- | --- | --- |
| iOS 27.0 | Xcode 27 (27A266a) | Released 2026-09-14 |
| iPhone Duo | Xcode 27.1 (27A9275) + iOS 27.1 simulator runtime | Released 2026-10-15 |

The app builds with Xcode 27.1 against the iOS 27.1 SDK and still deploys to iOS 26.5; every Duo API sits behind `#available(iOS 27.1, *)`. The iOS 27.1 simulator runtime only runs the iPhone Duo (other devices stay on iOS 27.0), and needs Xcode 27.1's system components (`sudo xcodebuild -runFirstLaunch`) before any simulator will boot.

DeviceHub, which replaced Simulator.app in Xcode 27, is the only way to change the Duo's pose: its bottom bar has rotate, closed, partially open (book) and fully open. `simctl` has no command for it. `simctl io <device> enumerate` lists both framebuffers (outer 1398 × 2034, inner 2007 × 2853), and `simctl io screenshot --display=<port UUID>` captures either. DeviceHub ignores Simulator.app's `-CurrentDeviceUDID`, but `open "devices://device/open?id=<UDID>"` shows a given simulator (and launches DeviceHub if needed); `Scripts/simulator.sh` and `Scripts/screenshots.sh` use it. A device opened that way gets its own DeviceHub window, with the pose controls along its bottom.

## Audit result

The app is already well positioned, because it was written size-class-first rather than device-first. A sweep for the patterns Apple calls out in *Prepare your app for iPhone Duo* found no violations:

- No `UIScreen.main` anywhere — nothing assumes a single display.
- No `userInterfaceIdiom`, `UIDevice.current` or interface-orientation branching.
- Layout is driven by `horizontalSizeClass` in `MapScreen` and `TrainDetailView`. `RootView` does not branch on it at all, and `MapSheet` deliberately does not read it: a split-view sidebar column is compact width on every device, so it takes an explicit style from `MapScreen` instead. `StationBoardView` picks its navigation behaviour from whether a selection callback was supplied, not from the size class.
- One deliberate exception to size-class-only layout: the regular layout reads the window's own proportions to decide whether the sidebar is shown, because binding `columnVisibility` at all opts out of `NavigationSplitView`'s automatic behaviour and the sidebar would otherwise stay wherever the previous pose left it. This is the one place a pose change, rather than a size-class change, moves the layout, so it is worth re-checking against the real device.
- The regular-width layout is a `NavigationSplitView` (the card as a sidebar beside the map) with an `.inspector` for the selected train or station, so columns collapse, tile and overlay on their own across poses.
- `Info.plist` sets `UIApplicationSupportsMultipleScenes` and has no `UIRequiresFullScreen` and no orientation lock.
- Hard-coded `.frame(width:height:)` calls are fixed-size glyphs and hit targets (dots, 44 pt buttons) and a few narrow column widths in the stop timeline and the map card. None is derived from or assumes a screen size.

The inner display is **regular in both dimensions** and does not honour `UISupportedInterfaceOrientations`, so unfolding the device puts the app straight into the existing regular-width layout. That is the intended behaviour and needs no new code.

## Fixed: state reset when the layout switched

`RootView` used to choose between two structurally different subtrees:

```swift
Group {
    if sizeClass == .regular { tabs } else { phone }
}
```

`phone` hosted `MapScreen()` directly; `tabs` hosted it inside a `Tab` in a `TabView`. Those are different positions in the view tree, so SwiftUI treated them as different view identities. When the size class flips, the old `MapScreen` is destroyed and a new one is built with fresh `@State`, discarding `camera`, `visibleRegion`, `selectedTrainID`, `selectedKey`, `selectedStation`, `sheetDetent`, the card's trail (`sheetPath` and `navigationStack`) and any `deferredFocus`. The map snaps back to the whole-of-Sweden region, the selected train is lost and the card returns to its root.

This is not Duo-specific. iPhone Plus and Max models report a regular width in landscape, so rotating an iPhone 17 Pro Max already triggers it today.

It reproduced on an iPhone 17 Pro Max simulator: select a train, rotate to landscape with Cmd+Left or Cmd+Right, and the map reset to the whole country. `TagradarUITests` now covers the same transition.

On iPhone Duo this stops being an edge case and becomes a core interaction — every open and close of the device crosses the same boundary.

### Fix

The map's durable state — camera, visible region, selection, the card's trail and its detent, and any deferred focus — now lives in `MapState` (`Tagradar/Views/Map/MapState.swift`), an `@Observable` model owned by `RootView` as `@State` and injected with `.environment(mapState)`, exactly the way `AppNavigation` already is. `RootView` never changes identity, so the object survives the swap and each freshly built `MapScreen` picks up where the last one left off. Neither layout changed; `MapScreen` reads and writes `mapState.…` instead of its own `@State`.

Selecting in the regular layout does not push onto the card's trail (there is no card), so a preserved trail could lag the selection: closing a Duo after picking a different train on the inner display would leave the card on whatever it showed before the device opened. `MapScreen` therefore reconciles when the size class becomes compact, appending the current selection to the trail so the card and the map agree and "back" still returns to what the card showed before.

The iPad redesign that followed removed the tabs altogether: `RootView` no longer branches on size class, `MapScreen` is the single root and swaps its own compact and regular layouts. `MapState` stays where it is, because the views inside those layouts are still rebuilt on the flip.

## iPhone Duo support (iOS 27.1)

Checked in the iPhone Duo simulator in every pose DeviceHub offers: closed, partially open, fully open, and fully open rotated to portrait.

- **Outer display (closed).** Compact layout: the map with the card at the bottom. The status bar runs down the right-hand side next to the outer camera, and the map controls and the card respect it. The card's content keeps the system sheet's asymmetric margin on the status-bar side. The map controls follow the card's measured top edge rather than a fraction of the screen per detent: in landscape the middle detent is no taller than the search bar, and the old guess floated the controls halfway up the map. Where no status bar runs along the top (landscape), the status pill row gets 16 pt from the top edge instead of 4 pt.
- **Inner display, landscape (open or partially open).** Regular layout with the sidebar beside the map. The display is about 950 pt wide, so the sidebar (360 pt) and the inspector (400 pt) together left the map a 100 pt sliver; `MapScreen.updateColumnVisibility` now shows the sidebar only when there is room for it, the inspector if one is open, and 360 pt of map, so here it steps aside while a train or station is open. iPads in landscape are wide enough for all three. Folding does not change the window's shape, so the sidebar does not move between partially and fully open; only rotating moves it, the same as on iPad.
- **Inner display, portrait.** Regular layout with the sidebar tucked away behind its button, as on an iPad in portrait.
- **Reserved regions.** The status pill and the map controls float over a full-bleed map, so the safe area alone does not keep them clear. `ReservedRegionAvoidance` (`Tagradar/Views/Map/ReservedRegionAvoidance.swift`) reads the active `.occlusion` and `.division` regions on iOS 27.1 and steps an overlay out of any it overlaps, by the shortest move that keeps it on screen. Partially open in landscape, the inner camera sits at the top of the fold with a 124 × 84 pt margin, right where the status pill is; the pill steps to the right of it. No `.division` region was reported in any pose in the simulator, only `.occlusion` ones (each camera with its margin).
- **Reading reserved regions.** They are reported in the querying view's own coordinate space, which `.offset` moves too: measuring the regions on the view you are offsetting moves the region with it and never settles. The modifier reads them from an unshifted probe behind the overlay.
- **Vertical toolbars.** Where the bars run down the side, items overflow from the bottom up. Follow and Save (train detail) and Save (station board) have a high `visibilityPriority`, Share, Directions and Show on map a low one (iOS 27).
- **App Store screenshots.** Both displays are part of the screenshot set; see `docs/app-store.md`.
- **Testing.** XCUITest cannot change the pose (`XCUIDevice` rotates but has no posture API), so the layout rules live in `MapLayout` as plain functions and `TagradarTests/MapLayoutTests.swift` tests them with the window sizes and reserved regions measured in the simulator. `idb` taps still work on the iPhone Duo, but on iOS 27.1 it cannot read its accessibility tree (a `SimulatorFrameworkBridgeProtocol` error), so the Duo screenshot run makes no taps and ad-hoc checks find controls from screenshots.
- **Concentricity.** The map controls use `.rect(corners: .concentric(minimum: 14), isUniform: true)`. In every pose they sit out of reach of the display's corners, so they resolve to 14 pt and nothing moves; they follow if a layout change ever brings them into a corner. The card's row backgrounds keep a fixed 16 pt: they scroll, and a concentric shape would take a larger radius as a row passed the sheet's rounded bottom corners. `GeometryProxy.containerCornerInsets` reports zero for views that do not touch the window's corners, so it cannot be used to place an overlay that sits inside safe-area padding.
- **Live Activity on the outer display.** The Dynamic Island moves to the side, stacked vertically next to the camera, and its compact views are a few points wide. The leading view's icon took the room and truncated the train number to an ellipsis; it now falls back to the number alone. The expanded and Lock Screen presentations are laid out horizontally across the top and read as on other iPhones. In the expanded island the arrival time's last digit is clipped by the island's corner (`18:0…`) on iPhone 17 Pro Max too, so that is not Duo-specific; the Lock Screen draws the same view in full.
- **Widgets on the outer display.** The small and medium widgets fit its home screen grid. The small Saved train widget's last line held the next stop, its planned and expected times and the delay, and truncated to `Next… … 1…`; the delay now sits beside the departure time and when both next-stop times do not fit only one is shown (the expected time in its delay colour, or the planned time without an estimate). When the departure times and the badge do not fit side by side, the badge goes.
- **`ArrangementView` not adopted.** It arranges two panes (split or overlay). The regular layout has three columns (sidebar, map, inspector) and the inspector is a navigation container, which Apple says to keep outside an arrangement view; train detail has no map of its own to arrange beside its timeline. `NavigationSplitView` + `.inspector` already adapt across poses, and `MapLayout.showsSidebar` handles the one width the Duo adds.

## CI

Every Xcode job in `.github/workflows/ci.yml` runs on the `xcode-27` image with `DEVELOPER_DIR` pinned to Xcode 27.1, because the image still defaults to 27.0. Verify downloads the iOS 27.1 simulator runtime, which the image does not install. CodeQL's Swift analysis is off until CodeQL supports Xcode 27's Swift 6.4: it needs Xcode 26, which cannot compile iOS 27.1 APIs.

## Sources

- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/) — Apple Tech Talk
- [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) — Human Interface Guidelines
- [Apple Developer releases](https://developer.apple.com/news/releases/) — toolchain availability
