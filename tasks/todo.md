# MacTop · Implementation tasks

The [MVP plan](plan.md) defines the scope. The first 0.1.0 test on the MacBook found a restoration failure on reconnect.

### Release packaging

MacTop's code is MIT licensed. The bundle includes that license and the four third-party notices. Before signing, the script removes the debug map containing build paths from the Swift executable.

The original `v0.1.8-beta.1` ZIP retains local build paths. Starting with 0.1.9, the Swift executable is stripped before signing.

For public downloads, build from a clean checkout with a Developer ID Application certificate and submit the app for notarization. Use the actual certificate and keychain profile names in these commands.

```sh
SIGN_IDENTITY='Developer ID Application: Holder Name (TEAMID)' ./scripts/build-app.sh
xcrun notarytool submit dist/MacTop-universal.zip --keychain-profile MacTop --wait
```

When the submission shows `Accepted`, staple the ticket to the app, validate the signature, and create the ZIP for distribution.

```sh
xcrun stapler staple dist/MacTop.app
xcrun stapler validate dist/MacTop.app
codesign --verify --deep --strict dist/MacTop.app
spctl --assess --type execute --verbose=2 dist/MacTop.app
ditto -c -k --sequesterRsrc --keepParent dist/MacTop.app dist/MacTop-universal-notarized.zip
```

Check the ZIP on the MacBook with Accessibility enabled, including reconnecting a monitor with multiple desktops. [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

### MacBook result with macOS 26.6.2

The user had three numbered desktops on the external monitor. On disconnecting it, they observed macOS move its desktops to the laptop. On reconnecting it, the external monitor showed a single desktop and MacTop 0.1.0 failed to return the windows to their destinations. The number of desktops left on the built-in display at the end of that cycle is unknown. The ten-cycle series remains pending for the corrected version.

With 0.1.1 the user reported that restoration appeared to work. With 0.1.2 they observed a noticeable speed improvement and asked to avoid repeatedly opening Mission Control.

### Per-monitor profiles in 0.1.9 (10)

- The shared profile remains in `macbook.json`. Each external monitor has its layout and desktop record in two files with a suffix derived from its identifier. Restoration still checks the monitor identifier and the record's capture date.
- If there is not yet a per-monitor file, MacTop reads the old one only when the saved identifier matches. Identities from the old record apply only to that capture. Saving a monitor's layout writes to its files and retains the legacy files so they remain available in 0.1.8.
- 173 tests passed. They cover home → MacBook → office → MacBook → home, reading legacy data, isolated saving for the office, and the open menu with a new monitor. On the Mac Studio, macOS returned an empty name. The menu test confirms that the short identifier is shown in that case. Physical switching between both monitors on the MacBook remains to be verified.
- The [public beta release](https://github.com/CarlosCaceres86/MacTop/releases/tag/v0.1.9-beta.1) includes the universal ZIP and its SHA-256 checksum.

### Automatic reconnection in 0.1.8 (9)

On the MacBook the overlay appeared, some desktops or windows were out of place, and a subsequent manual restoration completed the layout. In 0.1.7 tests reproduced two sequences consistent with that observation.

- Two display notifications during the first drag interrupted the batch return. The physical configuration is now compared with the one observed on reconnect. If the displays and geometry match, the same Mission Control session continues. A physical change or an uncertain read still interrupts the operation.
- A window missing from the first inventory could reappear in the final check without receiving its move. The coordinator uses that read and, if the window is still missing, allows up to one additional second of waiting. It verifies the move before continuing and retains the limit of one attempt per window. A window present on multiple desktops remains pending without additional waiting.
- 168 tests passed on the Mac Studio. In simulated reconnection the three originals returned in order, the external monitor's extra desktop was retained, and the late window was placed. With the only physical monitor, the display identity, geometry, and type checks were verified. The user confirmed restoration works on the MacBook with macOS 26.6.2. The ten-cycle series remains pending.
- The local signature, both architectures, and helper read from the 0.1.8 ZIP were verified. SHA-256 `447a7c79b4acb0d264105993651fb4be75cd4debb64f82bd399f4dba40e6fe69`. [MacTop 0.1.8 · Beta 1](https://github.com/CarlosCaceres86/MacTop/releases/tag/v0.1.8-beta.1)

To follow the change in the code, the [coordinator](../Sources/MacTopApp/LayoutCoordinator.swift) handles notifications and waiting, the [macOS adapter](../Sources/MacTopSystem/MacWindowSystem.swift) checks physical displays, and the [reconnection tests](../Tests/MacTopAppTests/LayoutCoordinatorTests.swift) reproduce both failures.

### Open menu updates in 0.1.7 (8)

- During detection, MacTop updates rows in the already open menu when coordinator state changes. The profile name, desktops, and Save button destination update together. A partial restoration with zero windows moved is omitted from both the visible state and the last-restoration reminder.
- With 0.1.6, the Mac Studio menu still said it was checking the configuration after 12 seconds. With 0.1.7 the state change was verified in the same menu window. An AppKit test with a simulated MacBook and monitor inventory showed both displays and the three external desktops, and enabled saving to the external profile.
- 163 tests passed. The contents and signature of the [0.1.7 universal ZIP](../dist/MacTop-0.1.7-universal.zip) were verified. SHA-256 `de3ca764c1b062e6e6ae8008b934c2c0de2dab94f4e2e3487952179b80e8d574`.

### Saving and icon in 0.1.6 (7)

- “Current status details…” and “Last result…” were removed. The header retains the status and a short summary. Save shows the pending count and retains the confirmation before replacing a profile.
- In one test, 201 windows were saved, 200 with pending assignments. The full profile was retained and a one-line summary published. The suite totals 161 tests.
- On the Mac Studio with macOS 27.0.1 the green icon was verified in MacTop's Settings row and in the extracted app's About dialog. Closing with Escape and Return was checked in two separate openings of the dialog. The appearance of the Accessibility entry on the MacBook with macOS 26.6.2 remains pending.
- The [0.1.6 ZIP](../dist/MacTop-0.1.6-universal.zip) contains the universal app and helper. The signature and declared icon resource were verified. SHA-256 `6d2d27352b2e39bcb5f80658423f9519b2e54a7319b68fb5c79e92633e95ba17`.

### Accessibility request in 0.1.5 (6)

- If permission is missing when MacTop starts, the app requests the native macOS prompt. On leaving System Settings or opening the menu, it checks permission again and starts monitoring displays. The action to open Accessibility is in the main menu while needed.
- 160 tests passed. The two new tests exercise startup with permission, a dismissed prompt, and detection of a simulated grant in the same session. On the Mac Studio, a copy with a test identity opened the real macOS prompt. It was verified to offer to open Settings, and the prompt was dismissed. Granting permission from Settings on the MacBook with 26.6.2 remains pending physical verification.
- The menu of the app extracted from the [0.1.5 ZIP](../dist/MacTop-0.1.5-universal.zip) was opened, and its signature, both architectures, and helper were verified. SHA-256 `4a5b300cc8df58c00f443cac8e74736a754e02f5c012bc467e9ecfc95124af87`.

### Overlay, icon, and menu in 0.1.4 (5)

- The MacBook user chose the green icon with the laptop and monitor, an overlay on both displays, and a menu that omits duration. The coordinator activates the overlay when a move starts and removes it when restoration finishes or is interrupted. The phase indicator appears once and favors the built-in display. The menu reuses the stable read to identify the save destination and show numbered desktops.
- 158 tests passed: 38 Core, 57 System, and 63 App. They cover saving with a different monitor from the one confirmed, retaining the last result, restoration without moves, and interruptions during placement or Mission Control closure.
- On the Mac Studio with macOS 27.0.1 and one monitor, a test window received a real click through the overlay. The indicator remained visible when Mission Control opened, and all three phases used the same panel. When finished, the overlay disappeared and the app with focus retained it. Coverage of both displays during the actual drag of the MacBook's three desktops on macOS 26.6.2 remains to be checked.
- The menu of the app extracted from the [0.1.4 ZIP](../dist/MacTop-0.1.4-universal.zip) was opened and its actions checked through Accessibility. Ad hoc signing, both architectures, the 26.4 minimum, the helper read, and all ten icon sizes were verified. SHA-256 `897a66b474ada48aa9df48d30662bbf235ff102302431afb4bd2d50983da0c2b`.

### Shared session in 0.1.3 (4)

- On the Mac Studio with macOS 27.0.1, the session opened Mission Control once, checked that the view remained available between three simulated moves, and closed it once at the end. Each move reached its position on the simulated external monitor. The order and active desktop on the physical monitor matched before and after.
- In a second test the native view was closed between gestures. MacTop detected its disappearance and stopped before the next simulated move. Automated tests also cover a view initially opened by the user, reopening after changing the active desktop, combined creation and movement, cancellations, and closure errors.
- The combined suite passed all 140 tests: 38 Core, 57 system adapter, and 45 coordinator. Duration and number of openings during a physical reconnection with the MacBook's three desktops remain to be measured. The local test used one monitor.
- The [0.1.3 ZIP](../dist/MacTop-0.1.3-universal.zip) was extracted and its ad hoc signature, both architectures, and included helper were verified. SHA-256 `3848c8c752a99db7b86a10924d420458b12ae5370415afffe30a76009cf505e4`.

### Performance in 0.1.2 (3)

During desktop recovery, MacTop reads the display structure and checks identity, order, and the active desktop. On reaching the window phase, it takes a full inventory and confirms the displays still match. A wait after Foundation observed helper termination was also removed. The three stability samples and timing of the native gesture that worked on the MacBook remain.

The combined suite passed **116 tests** on the Mac Studio: 38 Core, 38 system adapter, and 40 coordinator. Regression tests cover a display change between reading desktops and full capture, cancellation, profile protection during partial capture, and helper process exit, including when it must be terminated after the deadline.

Five layout runs per variant were measured with the same helper. The coordinator returned three identified desktops across two simulated displays and used the real pauses. Each read queried the Studio's real adapter, which at the time saw one monitor, three desktops, and 29 windows. The test excluded cable detection time, animations, and physical dragging in Mission Control. The scenario's windows were already in place.

| Variant | Median restoration time | Full window inventories per run |
| --- | ---: | ---: |
| 0.1.1 | 12.40 s | 25 |
| Separate desktop read | 9.87 s | 2 |
| 0.1.2 with helper wait corrected | 6.03 s | 2 |

In 0.1.2 there were also 24 desktop queries per run. Together the reads took a median of 1.87 s, versus 8.26 s in 0.1.1. Physical duration on the MacBook can be checked in the menu under **Last Restoration**.

### Local validation of 0.1.1 (2), November 24, 2026

- All 99 tests in the combined suite passed on the Mac Studio with macOS 27.0.1: 36 Core, 31 system adapter, and 32 coordinator. They cover reconnection with a single external desktop, the 0.1.0 profile requiring two destinations to be created, and returning three originals with a window opened after capture.
- In another planner check, 108 combinations of location, order, missing originals, and an extra external desktop returned identifiable originals to their positions. Applying the plan a second time required zero operations. Both displays in these tests are simulated.
- Independent review found two bugs. A numeric ID reappearing with a different UUID could move another desktop, and a wake notification could repeat an uncertain gesture. Tests reproduced both cases before the fix. The observed UUID must now match, and after an uncertain gesture the external profile requires an explicit retry while MacTop remains open. The laptop profile remains available.
- With one real monitor, Accessibility identified the display's Mission Control group, its three thumbnails, and the button to add a desktop. The layout helper read the active desktop and valid UUIDs for two of those three desktops. This check consisted of reading controls. Physical creation and dragging between displays and identity continuity after reconnect remain pending on the MacBook.
- Distribution ZIP: [MacTop-0.1.1-universal.zip](../dist/MacTop-0.1.1-universal.zip). It was extracted, and local signatures, the four licenses, and arm64 and x86_64 executables were verified, with a macOS 26.4 minimum for both. SHA-256 `50bd63d72d9e98a5f951608a966b1458c0fa7deec2423b5494bd79e95e456dcd`.

### Local evidence for 0.1.0, November 24, 2026

- On the Mac Studio with macOS 27.0.1 and SIP enabled, 40 tests passed: 16 core, 10 adapter, and 14 app coordinator.
- An AppKit test window created for this validation moved from the active desktop to another native desktop and back. MacTop's adapter verified the same process, window identifier, physical display, and exclusive membership at both ends. This was repeated with the distribution build objects and packaged component. Accessibility confirmed that the editor retained unsaved text before and after the round trip. The test used one monitor.
- The packaged app was opened through LaunchServices, and its menu's two save actions, manual restoration, automation, and Accessibility were checked. The test instance was closed afterward.
- The extracted ZIP passed signature verification with `codesign --verify --deep --strict`. The app and Spaces component include arm64 and x86_64, with a macOS 26.4 minimum on both architectures. SHA-256 of the delivered ZIP: `d3728a1503996338c05d905bcac80adbec8fb2bb6c1c341d52b4dba830241e3f`.
- The preceding case failed on the MacBook despite passing these checks on the Mac Studio. The [test guide](../README.md) includes the first round trip and ten acceptance cycles.

## 1. Check movement between displays

- [ ] On the MacBook with macOS 26.6.2, identify the window on each of the external monitor's three numbered desktops and inventory the built-in display's Spaces. Note what macOS retains or changes on disconnect and reconnect.
- [ ] Test `spacectl` v2.2.2 with SIP enabled. Move an identifiable window between the built-in and external displays and recover it after reconnecting. Repeat with a representative window for each mode used.
- [ ] Cross-check display and Space with a fresh read and Mission Control. Record whether the window and its contents are retained. Component self-detection and its test between two desktops on one display are only preliminary checks.

**Result required to continue.** A demonstrated mechanism for the real apps and modes. If desktops are missing or an app's mode must be reconstructed, describe the case and agree on the adjustment before building on it.

## 2. Save profiles from the menu bar

Depends on 1. Affects the menu, capture, and profile file.

- [ ] Capture “MacBook” and “MacBook + monitor” separately. Identify the monitor and retain the sequence of Spaces and their windows per display.
- [ ] Restart the utility and recover both profiles. Verify that saving one replaces only the selected one and that a failed write retains the valid copy.
- [x] Test local reads and writes and display matching with reversed enumeration order. Verified with real temporary files and a simulated inventory.

## 3. Restore on user action

Depends on 2. Affects profile comparison, the Spaces component, and the result shown in the menu.

- [ ] Restore the windows of both profiles and the modes demonstrated in 1. Verify the window, monitor, and Mission Control position for each destination. Preserve windows outside the profile.
- [x] Test an ambiguous window, one assigned to all desktops, a closed app, a missing destination, and a move failure. The coordinator retains the profile and displays diagnostics.
- [x] Repeat restoration on a correct profile. In the coordinator test the move count remains zero and saved profiles remain intact.

**Before automating.** Complete at least one manual round trip with the real windows. Include unsaved test content.

## 4. Activate the profile when the configuration changes

Depends on 3. Affects macOS notifications and restoration execution.

- [x] Test a simulated burst of notifications. Only the restoration corresponding to the final stable state acts.
- [ ] Disconnect while a move is in progress. Wait for its result, read the state again, and verify that pending moves from the previous profile are discarded.
- [ ] Test sleep and unlock, an unknown monitor, missing permissions, and a state that never stabilizes. Check that the app waits or explains the result and that profiles are retained.

## 5. Accept the MVP on the MacBook

Depends on 4. Affects validation and its record.

- [ ] Run the project build and tests. Record the MacTop and macOS versions, monitor, and apps used in the physical test.
- [ ] Complete ten full cycles. For each end, record expected and observed destinations, order, mode, window continuity, and any manual intervention. Include sleep and rapid reconnection.
- [ ] Confirm twenty correct layouts, zero closures or relaunches, and zero manual corrections. Document any failure and its sequence and reproduce it after fixing it. The final version must pass the full series.
