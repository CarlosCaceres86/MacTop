# Mission Control reference

Source: [Spaceballs](https://github.com/moltenbits/spaceballs/tree/bca247846e1fd7d0c916ca43a8f3398a5e9abf55), commit `bca247846e1fd7d0c916ca43a8f3398a5e9abf55`, MIT license ©2026 MoltenBits.

In `Sources/MacTopSystem/MissionControlDesktopDrag.swift`, MacTop adapts the interpretation of thumbnail positions (Dock origin through macOS 26 and WindowManager center from 27), the wait for the bar to expand and stabilize, and the native drag sequence: grab, pull down, approach the destination bar, and hold the drag before releasing. References: `Sources/SpaceballsCore/MissionControlAX.swift`, `SpaceMovePlanner.swift`, and `SpaceManager.swift` (Space movement).

MacTop's integration resolves thumbnails by display and index against a verified inventory, without English desktop names. It validates ID and UUID, retains a desktop on the source display, does not create siblings or delete desktops, guarantees `mouseUp`, and observes the result. It permits one order correction after confirming arrival on the correct monitor. The full Spaceballs code and executable are not included as a dependency.

Retain `LICENSE` when distributing the adaptations. Physical compatibility of the automation must be checked on the target machine and macOS version.
