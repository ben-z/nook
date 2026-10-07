# Nook

[![CI](https://github.com/ben-z/nook/actions/workflows/ci.yml/badge.svg)](https://github.com/ben-z/nook/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

**A small home for the menu-bar icons you only need sometimes.**

Nook hides a group of icons and lets you reveal one when you need it. You use the app's actual menu-bar icon and native menu or popover. After the interface closes, Nook puts the icon back in its hidden position.

**Experimental:** native icon ordering and layout settlement can fail. The system Sound popup is affected. Use Nook with that limitation in mind; it is not ready for dependable daily use.

## Use Nook

1. Click Nook's menu-bar button, or press **Control–Option–M**.
2. Open **Manage icons** and choose **Hide _app_** to add an icon to the hidden group.
3. Choose **Show _app_** to reveal it, then click the actual icon to use it.
4. Close its menu, popover, panel or window. Nook hides the icon after a short grace period.

In **Manage icons**, choose **Keep _app_ visible** to take an icon out of the hidden group. **Launch at login** is optional. The Clock and Control Center stay visible.

If an action fails, Nook marks its button and provides details in its menu. **Retry hiding the icon** is available when Nook still has its original position. Close the app's open interfaces before retrying. Quitting Nook shows the hidden group.

Automatic hiding waits while a native interface is open, the manager menu is open, or a mouse button is held. Reopening an interface cancels a pending hide. Nook remembers hidden selections when an app quits and relaunches.

## Install

Nook requires **macOS 26 or newer** and **Accessibility permission**. Release apps contain both Apple Silicon and Intel code.

1. Download the `Nook-<version>-macos-universal.zip` app from [Releases](https://github.com/ben-z/nook/releases).
2. Extract it and move **Nook.app** to **Applications**.
3. Open Nook. Enable it in **System Settings → Privacy & Security → Accessibility**, then reopen the app.

Packages are **ad-hoc signed and not notarized**. If macOS blocks the first launch, follow Apple's [instructions for opening an app you trust](https://support.apple.com/en-us/102445). Developer ID signing and Apple notarization are not configured.

Each release includes `SHA256SUMS.txt`. Run `shasum -a 256` on a downloaded ZIP and compare its digest with the matching entry before opening it.

To uninstall, turn off **Launch at login**, quit Nook, and remove the app from Applications.

## Build from source

You need **Xcode 26 or newer**, including Swift 6.2 or newer, and Python 3. No third-party Swift or Python packages are required. Build in a local folder such as `~/Projects`; storage providers can add bundle metadata that prevents signing in synced folders.

```sh
mkdir -p ~/Projects
cd ~/Projects
git clone https://github.com/ben-z/nook.git
cd nook
./build.sh
open dist/Nook.app
```

The build produces `dist/Nook.app` and the developer test app `dist/Nook Fixture.app`. Both are universal, ad-hoc signed bundles with the license and attribution included. `VERSION` is the single source for the app version; the minimum macOS version comes from `Package.swift`.

## How it works

- Two persistent status items manage the hidden group and selector.
- Accessibility identifies icons and tracks their native interfaces.
- Native window metadata and targeted mouse events move the selected icon into view and restore its place.
- A generation-checked timer handles automatic hiding. Temporary observers and event channels are released after an interaction.
- Nook does not capture icon images or poll continuously while idle.

Native movement relies on private macOS window queries and event routing. macOS updates may change those interfaces. Nook has no floating icon strip, updater or network service.

## Testing and limitations

Run the state-machine tests while developing:

```sh
swift test -c release -Xswiftc -warnings-as-errors
```

From a **clean, committed checkout**, run the complete build and packaging checks:

```sh
./scripts/check.sh "v$(cat VERSION)"
```

This builds both architectures, checks the packaged and extracted app signatures, validates version and source correspondence, and runs Swift and packaging tests. Packaging tests reject altered resources, stale versions and unsafe ZIP paths.

CI runs these checks on both [Apple Silicon and Intel macOS 26 runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). Hosted CI does not run the interactive GUI suite or establish long-term memory stability.

The interactive harness is `NookAudit`; `Nook Fixture.app` supplies a harmless test icon and native interfaces. These tests require an unlocked Mac with Accessibility granted to the test executables. The complete suite also requires Maccy, Tailscale and the system Sound icon. It moves icons and quits/relaunches the fixture. Keep the mouse and keyboard idle while it runs. Outside clicks, typing, scrolling and locking the Mac make the GUI audit fail as inconclusive.

```sh
.build/apple/Products/Release/NookAudit --e2e --system \
  --manager <nook-pid> --fixture <fixture-pid> \
  --diagnostics <nook-diagnostics.json> --output <result.json>
```

Launch the test Nook process with `--diagnostics <nook-diagnostics.json>` to create the required state file. Other harness modes cover three-icon order, fullscreen Spaces, source lifecycle, repeated interaction and API allocation/teardown. Use `--sound-e2e --cycles 20` with the same process and diagnostics arguments to repeat the native Sound popup and restoration case. Add `--trace-movement` when launching Nook to log drag transactions and changing window bounds. Missing prerequisites are errors.

Known limits:

- Native icon movement can time out during layout changes. Moving an icon clipped by a display notch has failed in testing. Nook reports movement failures explicitly.
- Some apps do not expose usable or stable Accessibility identities. Nook reports unavailable native icons and preserves inspection errors for real icon providers.
- Native Command-drags can move the pointer and interfere with simultaneous mouse input.
- External displays, display hot-plug and helper-owned popovers beyond the tested cases are not validated.
- Finite heap scans and repeated-use tests cannot exclude leaks over days of use. The protected WindowServer heap has not been audited.
- Intel builds are compiled and tested in CI; interactive behavior has been tested on Apple Silicon.

When reporting a bug, include the Nook version, macOS version, display arrangement, exact steps and the error shown by Nook.

## Releases

Update `VERSION`, commit the change to `main`, and wait for CI to pass. Then tag that commit:

```sh
git tag "v$(cat VERSION)"
git push origin "v$(cat VERSION)"
```

The release workflow requires both CI runners to pass. It verifies that the tag matches `VERSION` and that the downloaded artifacts came from the tagged commit. It then publishes an **experimental prerelease** containing:

- The universal Nook app ZIP.
- The corresponding source ZIP, taken directly from that commit.
- SHA-256 checksums and a manifest with the version, source commit, architectures and signing status.

The test fixture and audit tool are available in the source build and are not included in the app ZIP. Workflow actions are pinned to commit hashes; Dependabot proposes updates.

## License and attribution

Nook is licensed under [GPL-3.0](LICENSE). Its native icon movement and drag-event delivery are adapted from [Ice](https://github.com/jordanbaird/Ice) by Jordan Baird and contributors. See [NOTICE](NOTICE) for the upstream revision and attribution. LICENSE and NOTICE are also inside the distributed app.
