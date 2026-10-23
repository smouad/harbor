# Harbor architecture

This is a map of the code for contributors. [CLAUDE.md](../CLAUDE.md) holds the full reference, including the pitfalls each subsystem has run into; read the relevant section there before changing one.

## Priorities

When a choice is not settled otherwise, Harbor favors, in order:

1. **Speed on the Mac**: launch, tab switch, scrolling and sidebar interaction.
2. **Built-in ad blocking**: a core feature, not an add-on.
3. **Battery and CPU**: no polling timers. Work reacts to notifications and WebKit callbacks, and heavy work runs off the main actor.

## The big picture

```
HarborApp            @main, scenes, environment injection
 └─ ContentView      one per window, registers with WindowRegistry
     └─ WindowView   sidebar + page area + top bar + status bar
```

`HarborApp` creates the shared services (`BrowserManager`, `WindowRegistry`, `WebViewCoordinator`, `HarborSettingsService`, the keyboard shortcut and AI services) and injects them into the SwiftUI environment. Each window gets its own `BrowserWindowState`, which holds its space, its selection and its split view.

State is `@MainActor` throughout. Newer types use Swift Observation (`@Observable`). `BrowserManager` and a few older managers are still `ObservableObject`.

## Packages

Most of the model and shared UI lives in seven local Swift packages under `Packages/`, kept free of AppKit where that costs nothing so an iOS version can reuse them.

| Package | Holds |
|---------|-------|
| `HarborTabsCore` | The tab tree: spaces, items, ordering, device state and the JSON store. Foundation only, with a `swift test` suite. |
| `HarborSettings` | `HarborSettingsService` and every persisted setting type. |
| `HarborDesign` | Design tokens and surface recipes: radii, spacing, sizes, fonts, motion, fills, elevation. |
| `HarborBlocker` | The content blocker: filter lists, rule-list compiler, cosmetic engine and scripts. |
| `HarborTweaks` | Per-site tweaks: YouTube, Facebook, Reddit, X, SponsorBlock, Air Traffic Control. |
| `HarborWeb` | `TabsController`, `PageSession`, window state, history, search and favicons. |
| `HarborUI` | Shared SwiftUI: rows, the spaces list, context menus and most Settings pages. |

## Tabs and spaces

A **space** owns three sections: favorites, pinned and tabs. Each space also owns a `WKWebsiteDataStore`, so two spaces never share cookies or logins.

- Favorites and pinned items are **synced**: the item keeps its home URL, and closing ends the page but keeps the item.
- Items in the tabs section are **device** items: closing removes them.
- A tab opened from a page becomes that tab's child, a **trail**. Closing the parent moves its children up.

`TabsController` is the one place that changes the tree. Views call its intents (`open`, `select`, `close`, `move`, `drop`, `pin`, `setSpace` and so on). Every edit returns an undo change, and invalid edits are logged and ignored.

A page exists only once something opens it. `PageSession` wraps one live page: its web view, navigation, media and find state. Pages nobody looks at are unloaded after an idle period or under memory pressure, and keep their back history in memory.

The tree is saved to `~/Library/Application Support/com.mouad.harbor/Tabs/` as two JSON files, with daily backups. If a file cannot be read, Harbor loads the newest backup or runs read-only for the session rather than overwrite it.

## The sidebar

`SpacesSideBarView` (`Navigation/Sidebar/`) stacks the header, a pager of spaces, and the bottom bar. The pager (`Harbor/ThirdParty/BigUIPaging`) is Harbor's own trackpad pager. It follows two fingers across the sidebar and hands off to a spring when they lift. The space changes one frame after the lift, so the slide is already on the render server when the window starts its switch.

Each space's page is a separate hosting view, so it inherits no environment and is given what it needs explicitly.

## Windows and pages

- A page has one live web view. `WebViewCoordinator` moves it into whichever window last selected it, and other windows showing the same item draw a placeholder.
- Split view keeps its two panes alive while the pair is unchanged, because re-parenting a web view drops its video.
- Peek and the mini window show **detached** pages: full `PageSession`s outside the tree, so they get the blocker, extensions and downloads like any tab.

## Content blocking

Network rules are compiled from the filter lists by adblock-rust into WebKit content rule lists. Cosmetic filters and scriptlets come from a cosmetic-only adblock-rust engine, looked up per navigation and injected before the page runs. Scriptlets are uBlock Origin's own library, vendored at a pinned commit. Snapshots of every default list ship with the app, so the first launch is protected before any download.

The full design is in [adblocker-architecture.md](adblocker-architecture.md).

## Extensions

Extensions run on `WKWebExtension`. Tab web views must derive their configuration from the same configuration the extension controller uses. The details are in [Harbor/Managers/ExtensionManager/CLAUDE.md](../Harbor/Managers/ExtensionManager/CLAUDE.md).

## Design system

Every visual value comes from `HarborDesign`: no literal radii, spacing, fonts or animation curves in views. Corners are continuous, depth comes from elevation levels rather than ad hoc shadows, and Harbor draws its own surfaces instead of Liquid Glass. Space color tints the sidebar through a static gradient.

## Developer tools

With Developer Mode on (Settings > Developer), each page records console, network, blocker and performance data, and the docked Web Inspector and element picker are available. Browser Control starts a local MCP server on `127.0.0.1:47823` so a coding agent can drive a separate Agent space. It is off by default and protected by a token only readable by your user.

## Verifying a change

There is no test target. Build, launch and watch the logs:

```bash
xcodebuild -scheme Harbor -configuration Debug -arch arm64 -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
/usr/bin/log stream --level info --predicate 'subsystem == "com.mouad.harbor"'
```

Also build Release before shipping: some crashes only appear with optimizations on. Logic that deserves a check gets a small standalone program under a package's `Checks/` folder or `scripts/tests/`.
