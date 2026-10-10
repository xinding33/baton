# Working on Baton

Baton shares one mouse and keyboard across three Macs. `README.md` covers what it does, the layout, and how it is built and installed. This file covers what is easy to get wrong.

## The Macs are live

The installed Baton is the owner's working mouse and keyboard, all day.

| Layout name | Role | SSH host |
| --- | --- | --- |
| `studio` | anchor (the mouse is plugged in here, and work happens here) | local |
| `mini` | client | `mac-mini` |
| `mbp` | client, Wi-Fi only | `macbook` |

- **Only the main checkout (`~/code/baton`, branch `main`) deploys.** From a worktree or feature branch, do not run `scripts/deploy.sh` or `scripts/install-agent.sh`, do not touch `~/Applications/Baton.app`, and do not `launchctl` the `com.xinding.baton` agent on any Mac. Two branches deploying in turn would swap the build under the owner's hands.
- To run a build without touching the installed one, start a second instance with `BATON_HOME=<temp dir>` (own config, secret, log and control socket) and a different `port` in its config. A second instance must not install an event tap or move the cursor on a Mac someone is using.
- Ask before anything the owner would see or feel: moving the shared keyboard, turning a display off, sleeping a Mac, changing a system setting.
- `Baton ctl ...` talks to the running agent. From scripts, wrap it so a stuck agent cannot hang you: `perl -e 'alarm 6; exec @ARGV' ~/Applications/Baton.app/Contents/MacOS/Baton ctl status`.
- Logs: `~/Library/Logs/Baton/baton.log` on each Mac.

## Hazards already hit

- **The main thread must never block.** It carries the event tap, the heartbeat and the network callbacks; a stall drops the cursor back to the Studio after 800 ms and, if it lasts, freezes input sharing.
- **Any IOBluetooth call blocks until Bluetooth permission is decided.** Keep IOBluetooth on the `BluetoothThread` in `Sources/Baton/Keyboard.swift`, gated on `CBManager.authorization == .allowedAlways`.
- **Injected events must carry `Injector.marker`** so Baton's own taps ignore them. Anything new that posts events goes through `Injector`.
- **Turning a display off or on blocks** until the system has rearranged the screens, and then waits up to two seconds for the change to show. `DisplayController` and its files are only used on the queue in `Sources/Baton/DisplayToggle.swift`. An instance run with `BATON_HOME` never switches a display.
- **Timers that must keep firing use `repeatingTimer`** (`Net.swift`), not `Timer`: run-loop timers pause while a menu is open.
- **A new permission prompt on a client can strand it**, since nobody may be at that Mac to answer. Say so in your summary if a change needs one.

## Conventions

- `swift build` and `swift test` must pass. Logic that can be tested without a Mac's hardware lives in `BatonCore` with tests.
- Put a feature in its own source file. In shared files (`main.swift`, `Messages.swift`, `Config.swift`, `Anchor.swift`, `ClientAgent.swift`) add as little as possible, so branches merge cleanly.
- New `Config` fields decode with `decodeIfPresent` and a default, so existing config files keep loading.
- New `Message` cases go at the end of the enum. The anchor and the clients are always deployed together.
- No third-party dependencies.
