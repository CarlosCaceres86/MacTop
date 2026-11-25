# MacTop · MVP plan

**Goal.** When the user connects or disconnects their usual monitor, they recover the MacBook desktops and the same open windows in the order saved for that configuration. The first version will be validated on their MacBook with **macOS 26.6.2**, its built-in display, and one external monitor in extended mode. The user confirms that the external monitor has three numbered desktops. The goal there is to return each window to the first, second, or third desktop on that monitor, according to the saved sequence.

## Starting point

The project starts without code. Today macOS maintains each display's Spaces and decides where windows go when the configuration changes. Apps retain the contents of their windows. MacTop would save only the desired layout and inspect the actual layout before and after acting. Apple documents both display change notifications and the distinction between an ordinary desktop and a full-screen app's own Space. [Display changes](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification) · [macOS Spaces](https://support.apple.com/en-us/guide/mac-help/mh14112/mac)

## First technical decision

I recommend a local menu bar utility in Swift and AppKit. For the first test I would use SpacePigeon's `spacectl` **v2.2.2** directly. It builds as a standalone executable, enumerates windows and Spaces, and checks whether a window reached its destination. Its author documents movement with SIP enabled from macOS 26.4. Actual compatibility with 26.6.2 and the user's apps will be measured on the laptop. If the code is incorporated, its revision will be pinned and the MIT license and original attributions retained. [Component](https://github.com/louivers/spacepigeon/blob/v2.2.2/helper/spacectl.m) · [Build](https://github.com/louivers/spacepigeon/blob/v2.2.2/scripts/build_helper.sh) · [License](https://github.com/louivers/spacepigeon/blob/v2.2.2/LICENSE)

Reusing the full SpacePigeon flow would save interface work, but its editor re-enables relaunching an app if a move fails. Automating Mission Control through Accessibility allows full-screen Spaces to be reordered, at the cost of visible transitions and dependence on the macOS interface. I would reserve this second path for operations the laptop proves necessary. The proposal keeps SIP enabled and requests Accessibility when the operation requires it. [Relaunch setting](https://github.com/louivers/spacepigeon/blob/v2.2.2/swift/ConfigUI.swift#L573-L580) · [Mission Control reordering](https://github.com/louivers/spacepigeon/blob/v2.2.2/lua/mcdrag.lua)

## What the app saves and how it restores

- **Two explicit profiles.** The user arranges their session once for each configuration and chooses “Save this layout”. Each profile is stored in an atomically written local file. Only this action replaces a saved layout. A disconnection, sleep, or partial restoration never becomes the new reference.
- **Display and desktop.** The destination identifies the built-in display or recognized external monitor, and the position and kind of the Space in that display's Mission Control sequence. Current identifiers are resolved when applying the profile. Changing the main display must not reverse destinations.
- **Same window.** During the session, the app instance and window identity are checked. After a process restart, a new window can only be matched when there is one candidate for the app's one remaining entry. Two indistinguishable windows, a closed app, or a window on all desktops remain pending with a reason. The app preserves open work and acts only on identified profile windows.
- **Observable result.** Once the configuration is stable, the app compares the profile with the current state, moves only what is needed, and reads the display, physical position, and Space membership again. An ordinary window counts as restored when it belongs exclusively to the intended desktop on the intended display. If already there, it is not moved. The menu shows the result and allows a retry.

## Deliverables and decisions

| Deliverable | What it demonstrates |
| --- | --- |
| 1. Feasibility test on the MacBook | Record the type and order of Spaces in both configurations, the real apps, and the state of “Displays have separate Spaces” and automatic rearrangement based on use. Observe what macOS retains through a cycle. Move a test window, then representative windows, between displays and return them to their destinations after reconnecting. Verify with a subsequent read and in Mission Control. |
| 2. Capture the two profiles | Save each configuration's layout from the menu, restart MacTop, and recover both. Capture also retains empty desktops relevant to the order. |
| 3. Manual restoration | Restore both profiles using “Restore Now”. First test a correct destination, then an incorrect one, and finally an ambiguous window. Applying the correct profile a second time must produce zero moves. |
| 4. Restoration on display changes | Connecting or disconnecting triggers the same manual restoration after consistent display and Space readings are obtained, subject to a timeout. On wake or unlock, check again whether the configuration changed or a restoration remains pending. Execute one move at a time. If the configuration changes during one, observe how it ends, discard pending steps, and recalculate. |
| 5. Physical acceptance | Complete ten disconnect and reconnect cycles on 26.6.2. Verify both ends of each cycle, including at least one after sleep. Keep the observed result for each cycle and failures separately. |

### Decision after the reconnection test

On the MacBook, macOS moved the external monitor's three desktops to the built-in display on disconnect. On reconnect, the external monitor showed a single desktop. The user chose to return each identifiable original desktop with all its windows, including those opened after the profile was saved.

In 0.1.1 manual and automatic restoration share the same order. MacTop locates the originals, returns them to their positions through Mission Control, creates any destinations still missing, and finally checks the saved windows. After each gesture it reads both displays again. A return it cannot verify stops that restoration. A 0.1.0 profile retains the number of destinations, but only a new explicit capture records the identity of originals already present.

If macOS gives the external monitor a new desktop and all three originals survive, all four are retained. The three in the profile come first, in order, and the menu reports the extra one. This decision protects windows open on the new desktop. Acceptance must distinguish this case from one in which the desktop already shown on the external monitor is one of the three originals.

### One Mission Control session per reconnection

The user observed that 0.1.2 was faster and asked to move their three desktops in a single opening. In 0.1.3 desktop recovery shares Mission Control from the first gesture until completion. The app distinguishes whether it opened the view or it was already open, and respects that state at the end. Each drag still checks the current thumbnails and verifies the desktop, monitor, and arrival order. The three stability readings remain because they already worked on the MacBook.

If a desktop to be moved is active, MacTop activates another desktop on that display. The user accepted that the app may reopen Mission Control if it left the view during that change and can confirm it. If the view disappears between two ordinary gestures, the batch stops and the user decides when to retry.

The external monitor's three numbered desktops allow us to start by moving ordinary windows to existing destinations. The built-in display still needs to be inventoried. Only if it contains a full-screen app or Split View pair that forms part of the requested layout will restoration of its mode and position be tested. That result would inform agreement on an extension before implementation.

## Acceptance criteria

**Ten cycles and twenty correct layouts** on the target MacBook. At each end, the saved order, the external monitor's three apps when applicable, and the laptop windows must match. The same session windows retain their contents, including an unsaved test change. No app is closed or relaunched. Interruption and ambiguity tests are recorded separately and must leave work accessible and explain any partial result.

The available Mac Studio can build and run logic tests. Physical acceptance depends on the MacBook, its monitor, and its apps. Compatibility is measured against macOS 26.6.2. A macOS change requires repeating the movement test before declaring another version compatible.

Tasks and their checks are in the [implementation list](todo.md).
