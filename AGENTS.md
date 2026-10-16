# Drive Mirror

A personal macOS 14+ menu bar app that mirrors Markdown folders from iCloud Drive into Google
Drive as Google Docs, one way. iCloud is the source of truth; Drive holds a disposable copy.

Nearly all logic lives in the `MirrorCore` Swift package so it can be tested with `swift test`.
The app target (`App/`) is a thin SwiftUI layer. `mirrorctl` is a CLI over the same code.

## Commands

Run from the repo root. Use `/usr/bin/make`, not bare `make`.

| Task | Command |
|---|---|
| Install pinned tools | `mise install` |
| Everything CI runs | `/usr/bin/make check` |
| Package tests only | `swift test --package-path Packages/MirrorCore` |
| Package tests + app build | `scripts/test.sh` |
| Lint (no changes) | `scripts/lint.sh` |
| Format in place | `/usr/bin/make format` |
| Regenerate Xcode project | `mise exec -- xcodegen generate` |

`scripts/test.sh` builds unsigned when `Config/Local.xcconfig` has no `DEVELOPMENT_TEAM`.
Don't add signing flags to make a build pass.

## Layout and boundaries

- `Packages/MirrorCore/Sources/MirrorCore`: sync, Drive client, OAuth, scanning, state. Put new
  logic here, not in `App/`.
- `Packages/MirrorCore/Sources/mirrorctl`: CLI. Thin wrappers over `MirrorCore`.
- `Packages/MirrorCore/Tests/MirrorCoreTests/Fixtures`: Markdown corpus and golden request bodies.
- `App/`: views and view models only. View models get unit tests against fakes.
- `project.yml` is the source of truth for the Xcode project. The `.xcodeproj` is generated and
  gitignored. Never hand-edit it.

## Conventions

- Zero third-party dependencies. Build on Foundation, Network, and Security. Ask before adding
  a package.
- Tests use swift-testing (`import Testing`, `@Test`, `#expect`). Don't add XCTest.
- Swift 6 language mode with strict concurrency. Fix concurrency warnings properly; don't
  silence them with `@unchecked Sendable`, `nonisolated(unsafe)`, or `Task.detached`. If one
  is truly needed, leave a comment saying why it's safe.
- Prefer value types and actors. Keep `@MainActor` on UI-facing types. No blocking file or
  network I/O on the main actor.
- Use `@Observable` for view models, not `ObservableObject`.
- Make time, randomness, file system roots, and HTTP injectable so tests are deterministic.
  Engine tests use `InMemoryDriveClient`, temp directories, and an injectable clock.
- Run `/usr/bin/make format` rather than hand-fixing style. `.swift-format` holds the rules.

## Safety

- Never touch the real iCloud Drive folders or a real Google account from tests. Use temp
  directories and stubbed `URLProtocol` responses.
- Live Drive tests run only with `LIVE_DRIVE=1`. Don't set it unless asked.
- Never commit or print credentials: `google-client.json`, refresh tokens, access tokens.
- Never permanently delete Drive files. The app only trashes.
- The app is not sandboxed on purpose. Don't add sandbox entitlements to fix file access.

## Gotchas

- iCloud files can be dataless placeholders. Check `ubiquitousItemDownloadingStatus` before
  reading, and read through `NSFileCoordinator`.
- macOS file names may be NFD; normalize relative paths to NFC before comparing or hashing.
- The app is `LSUIElement` (no Dock icon, no main window). Verify behavior through tests and
  `mirrorctl`, not by launching the app.
- If `xcodebuild` fails to load a plug-in, run `xcodebuild -runFirstLaunch`.

## Working as an agent

- Delegate to cheaper subagents when the task makes sense for one: searches, research,
  mechanical edits, boilerplate tests. Keep design decisions and final review with the main
  agent.
- Done means `/usr/bin/make check` passed. If it didn't run, say so.
