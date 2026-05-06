# Contributing

Thanks for considering a contribution to `flutter_uwb`. This document
covers how to set up the repo, the conventions code is held to, and
the kinds of changes most likely to land cleanly.

## Quick start

```sh
git clone https://github.com/AhmedJHamdan/flutter_uwb.git
cd flutter_uwb
flutter pub get
cd example && flutter pub get && cd ..
```

Run the test suites before opening a PR:

```sh
flutter test
cd example/android && ./gradlew :flutter_uwb:testDebugUnitTest && cd ../..
flutter analyze
dart format --output=none --set-exit-if-changed .
```

CI runs the same four steps on every push.

## Project layout

| Path | What lives there |
| --- | --- |
| `lib/` | Public Dart API + facade |
| `lib/src/pigeon/` | Generated Dart from `pigeons/uwb_api.dart` — do not edit by hand |
| `pigeons/` | Pigeon source of truth for the Dart↔native contract |
| `android/src/main/kotlin/` | Android plugin implementation (Jetpack UWB + BLE OOB) |
| `ios/Classes/` | iOS plugin implementation (NearbyInteraction + CoreBluetooth + MultipeerConnectivity) |
| `test/` | Dart unit tests |
| `android/src/test/kotlin/` | Kotlin JVM unit tests (no Android device needed) |
| `ios/Tests/` | Swift XCTest cases |
| `example/` | Reference app demonstrating the public API |
| `doc/` | Architecture notes; `doc/agents/` is internal scratch |

## Regenerating Pigeon

Anytime you change `pigeons/uwb_api.dart`, regenerate the Dart, Kotlin
and Swift sides:

```sh
dart run pigeon --input pigeons/uwb_api.dart
```

Commit the regenerated `lib/src/pigeon/uwb.g.dart`,
`android/src/main/kotlin/com/ahmedhamdan/flutter_uwb/UwbPigeon.g.kt`,
and `ios/Classes/UwbPigeon.g.swift` alongside your source change.

## Coding conventions

These follow the project's `CLAUDE.md`; the short version:

- 80-column lines.
- `PascalCase` for classes, `camelCase` for members, `snake_case` for
  files.
- Functions short and single-purpose (under ~20 lines is the goal).
- No emojis in source, comments, commit messages or docs.
- Comments explain *why*, not *what*. If the code is self-evident,
  no comment is needed.
- Public Dart APIs ship with `///` dartdoc; new enum values document
  cause + recommended action.
- Logging through `dart:developer.log` (Dart), `android.util.Log`
  (Kotlin), `os_log` (Swift). For Dart, prefer `UwbLog` once
  available so verbosity stays user-controllable.

## Tests

- **Unit tests are required** for any change that adds or modifies
  Dart facade behaviour or Pigeon-mediated contracts.
- Native unit tests live in `android/src/test/` and `ios/Tests/`. They
  run on the host JVM / macOS — no device required.
- Integration tests in `example/integration_test/` exercise the
  plugin end-to-end against a connected device or emulator. UWB
  ranging itself can only be exercised on real hardware.

## Hardware verification

If your change touches:

- BLE GATT, advertising, or the OOB transport
- Any UWB session lifecycle (start, stop, pause, error)
- Anything in `ios/Classes/IosPeerStrategy.swift`,
  `IosAccessoryStrategy.swift`, or the matching Android strategies

… the change must be exercised on real hardware before merging. CI
cannot replace this. The PR description should state which devices
were used.

Verified hardware combinations the project tracks:

- Pixel 6 Pro, Pixel 7+, Pixel 8+ (Android UWB)
- iPhone 11 through iPhone 16 Pro Max (iOS U1 / U2)
- Qorvo DWM3001CDK reference accessory

## Commit and PR style

- One focused change per PR. A bug fix and a refactor are two PRs.
- Commit messages follow Conventional Commits (`feat:`, `fix:`,
  `docs:`, `chore:`, `ci:`, `refactor:`, `test:`).
- PR titles match the lead commit title.
- PR descriptions describe **what changed**, **why**, and **how it
  was tested** (especially for hardware-dependent changes).
- Squash-merge is the default; the PR title becomes the merge commit.

## Reporting bugs

Use the bug-report issue template; include:

- Plugin version.
- Flutter version (`flutter --version`).
- Device model, OS version (and Android API level if applicable).
- The peer's model and OS, if it was a pairing problem.
- A minimal reproducer or the relevant log snippet.

## Asking for a feature

Use the feature-request template. The fastest path to acceptance is a
proposal that includes:

- The end-user problem (not just the API shape).
- One or two example code snippets showing how callers would use it.
- Any platform constraints you've already discovered.

## Security

Do not file public issues for security-sensitive bugs. See
[`SECURITY.md`](SECURITY.md) for the disclosure process.
