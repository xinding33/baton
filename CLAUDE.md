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
- To run a build without touching the installed one, start a second instance with `BATON_HOME=<temp dir>` (own config, secret, log, control socket and launch agent) and a different `port` in its config. A second instance must not install an event tap or move the cursor on a Mac someone is using. `Baton update-check run` and `Baton display-check run` start one subsystem by itself for that reason.
- **Only the owner tags.** Pushing a `v*` tag publishes a release, and every Mac that runs a release build installs it within a day. To try the updater, publish a prerelease by hand (`gh release create --prerelease`, from a tag on a commit without the workflow) and point test copies at it with `Baton ctl update install <version>`; delete it afterwards.
- With an empty `BATON_HOME` the instance shows the setup window and starts nothing else until its Start button is pressed, so that window can be exercised safely: `Baton ctl settings ...` drives it, and `settings snapshot <png>` draws it. `settings apply` starts the agent, and a build run from a terminal inherits the terminal's Accessibility grant, so its event tap would be real: do not send it on a Mac someone is using. The tests in `SetupWindowTests.swift` cover what Start and Apply write.
- Ask before anything the owner would see or feel: moving the shared keyboard, turning a display off, sleeping a Mac, changing a system setting.
- `Baton ctl ...` talks to the running agent. From scripts, wrap it so a stuck agent cannot hang you: `perl -e 'alarm 6; exec @ARGV' ~/Applications/Baton.app/Contents/MacOS/Baton ctl status`.
- Logs: `~/Library/Logs/Baton/baton.log` on each Mac.

## Hazards already hit

- **The main thread must never block.** It carries the event tap, the heartbeat and the network callbacks; a stall drops the cursor back to the Studio after 800 ms and, if it lasts, freezes input sharing.
- **Any IOBluetooth call blocks until Bluetooth permission is decided.** Keep IOBluetooth on the `BluetoothThread` in `Sources/Baton/Keyboard.swift`, gated on `CBManager.authorization == .allowedAlways`.
- **Injected events must carry `Injector.marker`** so Baton's own taps ignore them. Anything new that posts events goes through `Injector`.
- **Turning a display off or on blocks** until the system has rearranged the screens, and then waits up to two seconds for the change to show. `DisplayController` and its files are only used on the queue in `Sources/Baton/DisplayToggle.swift`. An instance run with `BATON_HOME` never switches a display.
- **Timers that must keep firing use `repeatingTimer`** (`Net.swift`), not `Timer`: run-loop timers pause while a menu is open.
- **The pasteboard is read and written only on `ClipboardService`'s queue.** A read can wait on the app that made the copy, or on a privacy alert. Clipboard data never goes on the input link either: it has its own connection (`port` + 1), so megabytes cannot hold up the heartbeat.
- **The update link is frozen.** The input link refuses a Mac on another version, so a Mac that slept through an update learns which version to fetch on the update link (`port` + 2). Every release ever published must keep reading `hello`, `prepare`, `prepared` and `install` as `Sources/BatonCore/UpdateLink.swift` writes them, over the same TLS and framing. Add keys and message types; never rename, remove or reinterpret one, and keep versions dotted numbers. `UpdateLinkTests` pins the bytes.
- **An update restarts Baton by exiting with a failure**, and the launch agent's `KeepAlive` starts the new copy (`Relaunch` in `Sources/Baton/Updates.swift`). An agent that does not restart Baton after a failed exit would leave every Mac without Baton after an update.
- **`scripts/deploy.sh` signs with the releases' Developer ID**, so the signature does not tell a deployed build from a release. `BatonBuild` in `Info.plist` does: only `scripts/release.sh` stamps `release`, and nothing else ever replaces itself. Keep it that way, or a release would overwrite what was just deployed.
- **A new permission prompt on a client can strand it**, since nobody may be at that Mac to answer. Say so in your summary if a change needs one.
- **`config.json` has one writer on the anchor.** `Anchor` rewrites the whole file from its own copy, so a setting changes through `Anchor.updateConfig`, or it is lost at the next save. Settings read only at launch (name, role, pairing code, shared keyboard) are applied by restarting, with the updater's `Relaunch.now()`.
- **The launch agent is the app's to write** (`LoginItem.swift`, `BatonCore/LoginItem.swift`), and only a copy inside `Baton.app` may write the real one. It goes to `$BATON_LAUNCH_AGENTS`, or to `$BATON_HOME/LaunchAgents`, when either is set; a test must never write `~/Library/LaunchAgents`.

## The repo is public

`github.com/xinding33/baton`. Keep the owner's addresses, Bluetooth IDs, host names beyond those already in `scripts/deploy.sh`, and anything from their config or secret out of commits, logs pasted into docs, and PR text. Work on a branch, push it, and open a pull request against `main`; the main checkout merges and deploys.

## Conventions

- `swift build` and `swift test` must pass. Logic that can be tested without a Mac's hardware lives in `BatonCore` with tests.
- Put a feature in its own source file. In shared files (`main.swift`, `Messages.swift`, `Config.swift`, `Anchor.swift`, `ClientAgent.swift`) add as little as possible, so branches merge cleanly.
- New `Config` fields decode with `decodeIfPresent` and a default, so existing config files keep loading.
- New `Message` cases go at the end of the enum. The anchor and the clients are always deployed together.
- No third-party dependencies.
