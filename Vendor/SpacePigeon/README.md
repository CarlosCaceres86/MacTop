# Vendored spacectl

Source: [SpacePigeon v2.2.2](https://github.com/louivers/spacepigeon/tree/e61c5f24e2d7cb8a235a6bf0ff8d7ff80a056871), commit `e61c5f24e2d7cb8a235a6bf0ff8d7ff80a056871`, file `helper/spacectl.m` (helper 1.3.0).

MacTop retains only `check`, `spaces`, `windows`, `move`, and `version`. It removes gestures, Space focus, the self-test that moves windows, and class exploration. It retains AppKit and the normal bridged SkyLight operation with SIP enabled. It does not change SIP, TCC, or preferences, or relaunch apps.

The `spaces` output adds a `uuid` per desktop: a non-null canonical UUID from the private dictionary, or `null` if missing or invalid; it never converts the session ID into a UUID.

Modifications: it retains small windows and unknown membership so the adapter can report them; it requires an ordinary desktop, exclusive membership, and PID/launch time before moving; and verifies exclusive membership afterward. The Swift adapter also verifies topology, AX identity, and physical position. Internal usage: `spacectl move WINDOW SPACE TIMEOUT_MS PID LAUNCH_EPOCH`.

Included licenses: SpacePigeon (`LICENSE`, MIT ©2025 louivers), yabai (`LICENSE.yabai`, MIT ©2019 Åsmund Vikane), and ferry (`LICENSE.ferry`, MIT ©2019 Åsmund Vikane, ©2026 softmaxe), according to the original file's attributions. The historical ferry license was obtained from [affaf2b2c21ae37aadcaafcf4d5421b016b3ad0e](https://github.com/softmaxe/ferry/blob/affaf2b2c21ae37aadcaafcf4d5421b016b3ad0e/LICENSE); ferry's later change to AGPL is not incorporated. Copy these three licenses when distributing the executable.

`scripts/build-helper.sh [output-path]` builds offline for arm64 and x86_64 with a macOS 26.4 minimum and ad hoc signing by default. Private APIs can change: `check` only confirms the operation is present; physical acceptance on the MacBook requires the documented cross-display movement test.
