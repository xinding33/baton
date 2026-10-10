# Baton

Shares one mouse and keyboard across several Macs on the same network. The cursor moves off the
edge of one Mac's screen onto the next Mac's, and typing follows it.

One Mac, the **anchor**, has the mouse and keyboard attached. It decides which machine the cursor
is on and forwards input to the others (**clients**), which replay it.

## Install

Requires macOS 14 or later. Releases are universal (Apple silicon and Intel), signed with a
Developer ID and notarized by Apple.

```sh
brew install --cask xinding33/tap/baton
```

Or download `Baton-x.y.z.zip` from the
[latest release](https://github.com/xinding33/baton/releases/latest), unzip it, and move
`Baton.app` to Applications.

Do this on each Mac, then open Baton there. After that Baton keeps itself up to date on all of
them together (see [Updates](#updates)), so `brew upgrade` leaves it alone.

To uninstall, switch **Open at Login** off and quit Baton from its menu, then run
`brew uninstall --cask baton` (or delete `Baton.app`). `brew uninstall --zap --cask baton` also
removes its settings and logs.

## Setting up

Open Baton on each Mac. A Mac that has not been set up shows a window that asks for:

- **a name** for this Mac, one word such as `studio` or `laptop`. It is offered from the Mac's
  own name and has to be different on every Mac;
- **whether this Mac has the mouse and keyboard** (the anchor) or is controlled from another Mac
  (a client);
- **the pairing code.** Press Generate on the first Mac, then type the code into the others, or
  carry it over with Copy. A mistyped code is caught as you type it;
- **the permissions** Baton still needs on this Mac, each with its state and a button that opens
  the right pane of System Settings › Privacy & Security.

| Mac | Permissions |
|---|---|
| anchor | Accessibility, Bluetooth |
| clients | Accessibility, Local Network, Bluetooth |

Bluetooth is only used with a shared Bluetooth keyboard. macOS does not let an app read its Local
Network setting, so a client shows it as allowed once it has found the anchor, and as off when
the network refuses it.

**Start Baton** writes the settings and begins sharing; nothing runs before that. The window
stays open as **Settings…**, which is in the menu bar item afterwards, and which opening Baton
again also brings up. The form is its **General** pane from then on. It shows how sharing is
going and what is in its way: a pairing code that does not match the other Mac's, Local Network
access that is off, a Mac that has the anchor's name. Changing the name, the role or the code
there restarts Baton on that Mac.

A Mac that connects to the anchor for the first time has no place next to the others yet, and
the cursor cannot reach it. The anchor's menu says so, and opens **Arrange** in its Settings,
which shows the Mac at the right, ready to be dragged to where it sits.

**Open at Login**, ticked in the setup window and under General afterwards, starts Baton when you
log in and again if it ever crashes. It is a launch agent,
`~/Library/LaunchAgents/com.xinding.baton.plist`, which Baton writes and removes itself, and
points at its new place if the app is moved. Switching it off takes effect at the next login.

Settings are kept in `~/Library/Application Support/Baton`: `config.json`, and `secret.key` with
`pairing.code`, the code it came from.

## The menu and Settings

The menu bar item (⇄) holds what is done in a hurry: on the anchor, which Macs
are connected, **Pause Sharing**, **Bring Cursor Home**, where the shared keyboard is and a
submenu to move it, **Wake All Macs**, **Settings…** and **Quit Baton**. A client has its
connection, **Wake All Macs**, **Settings…** and **Quit Baton**. Two kinds of line come and
go above and between those:

- what needs attention on that Mac, at the top, each opening the pane that puts it right: a
  missing permission, a Mac with no place yet, copies that are not getting through;
- what the updater is doing while it installs a release, or which Mac is on another version.

**Pause Sharing** leaves each Mac to itself until **Resume Sharing**. The cursor comes back to
the anchor and stays there, the shared keyboard stops following it, a copy stays on the Mac it
was made on, a display that wakes does not wake the others, and a Mac in use does not keep the
others awake. The switches in Settings stay as they are, and Sleep & Wake and the clipboard's
rows say that they are paused. What is copied during a pause is not sent afterwards either. What you
ask for by hand still happens: **Wake All Macs**, moving the keyboard from the menu, turning a
display off or on. Updates carry on too. A pause lasts until it is resumed or Baton restarts.

Everything that is set once and left alone is in **Settings…**, a pane for each part of Baton:

| Pane | What is there | Applies to |
|---|---|---|
| General | Name, role, pairing code, permissions, **Open at Login**, **Show in the menu bar** | this Mac |
| Mouse | Reversing the mouse wheel | this Mac |
| Keyboard | The shared keyboard, whether its Bluetooth connection follows the cursor and how it moves, and sharing the clipboard (anchor only) | all Macs |
| Displays | Turning external displays off and on; the anchor also lists the other Macs' | each Mac's own |
| Arrange | Where each Mac sits (anchor only) | all Macs |
| Sleep & Wake | Waking together and staying awake | this Mac |
| Clipboard | Sharing the clipboard (clients only; on the anchor it is under Keyboard) | all Macs |
| Updates | The version, **Check for Updates…**, installing automatically | all Macs |

A switch takes effect when it is flipped. Only the name, the role, the pairing code and the choice
of shared keyboard need **Apply and Restart**.

## Layout

Each machine is placed relative to another in the anchor's
`~/Library/Application Support/Baton/config.json`:

```json
{
  "name": "studio",
  "role": "anchor",
  "placements": [
    { "machine": "mini", "side": "left", "of": "studio", "align": "end" },
    { "machine": "mbp", "side": "right", "of": "studio", "align": "end" }
  ],
  "timeoutMs": { "mbp": 1500 }
}
```

- `side`: `left`, `right`, `above`, `below`
- `align`: `start` (tops or left edges line up), `center`, `end` (bottoms or right edges line up)
- `offset`: extra shift along the shared edge, in points
- `scale`: stretches a machine's edge so displays of different heights map onto each other fully
- `timeoutMs`: how long a client may go silent before the cursor returns to the anchor

The easier way to change the layout is **Arrange** in the anchor's Settings: drag a Mac to where
it sits on your desk and drop it. It snaps against its neighbours and applies at
once. Macs that are away stay in the picture, dimmed, and keep their place.

If you edit the file by hand, restart the agent afterwards:
`launchctl kickstart -k gui/$(id -u)/com.xinding.baton`.

## Using a Mac's own trackpad

Touching a client's own trackpad, mouse or keyboard brings the shared cursor to that Mac, at the
spot where its cursor is. The mouse then carries on from there. The shared mouse and keyboard come
first: nothing happens if either was used in the last two seconds. Keys from a client's own keyboard
only count while the shared keyboard is attached to another Mac; Baton cannot tell two keyboards
on one Mac apart.

## The shared keyboard

Choose the keyboard under **Keyboard** in the anchor's Settings, which lists the Bluetooth
keyboards paired with that Mac; **Apply and Restart** there makes it the shared one. It is kept
as `keyboardAddress`, the keyboard's Bluetooth address, in the anchor's config. Baton then tracks
which Mac the keyboard is attached to, and the menu says which and can move it. Keys typed while
the cursor is on a different Mac are forwarded there, whichever Mac the keyboard is on.

**Bluetooth connection** (`keyboardFollows`) says what happens to the keyboard's own connection
as the cursor moves:

- **Stays on one Mac** (`false`, the default). The keyboard stays connected to the Mac it is on,
  and its keys get to the others over the network. Touch ID only works on the Mac the keyboard is
  connected to. The menu still moves it to another Mac when asked.
- **Follows the cursor** (`true`). The connection moves to the Mac the cursor has settled on, once
  typing pauses, so that Touch ID works there. A move takes about two seconds, during which the
  keyboard types nowhere.

**To move it** (`handoffStrategy`) picks how the keyboard changes Macs: **Reconnect** (`reconnect`:
the old Mac disconnects, the new one connects) or **Forget and pair again** (`repair`: the old Mac
forgets the keyboard, the new one pairs with it).

A Mac that goes to sleep while it has the keyboard forgets it first, and the anchor has the Mac
with the cursor pair with it (the anchor itself when `keyboardFollows` is off). The same happens,
ten seconds later, when the Mac that had the keyboard drops off the network. While a connected
Mac still holds the keyboard's pairing, a keyboard that disappears is taken to be switched off,
and is left alone until it comes back. If no connected Mac holds its pairing, it cannot come back
by itself, so a Mac pairs with it afresh.

## The mouse wheel

With macOS "Natural scrolling" on, Baton reverses notched mouse wheels and leaves trackpads alone,
so trackpads scroll naturally and wheels scroll the traditional way. It tells the two apart by
event, not by device: trackpads and the Magic Mouse send continuous scroll events, wheels send
discrete ones.

Known limitation: a mouse that sends continuous events, such as a Logitech set to smooth scrolling
in Logi Options+, is treated as a trackpad and not reversed. Backspin has the same limit. It does
not bite while Logi Options+ is not running. A fix for the shared mouse would be a switch on the
anchor that reverses every scroll made there, continuous or not, which is right as long as no
trackpad or Magic Mouse is attached to the anchor. It is not built.

Each Mac reverses the scrolls that land on it, whether they come from the shared mouse or from a
mouse plugged into that Mac, and has its own **Reverse the mouse wheel** switch under **Mouse** in
Settings, with **Vertical** and **Horizontal** under it. The choice is kept in `scroll.json` next
to the config.

Baton takes over from [Backspin](https://github.com/xinding33/backspin). Do not run the two on the
same Mac: two reversals cancel out.

## Displays

**Displays** in each Mac's Settings lists its external displays. Untick one to turn it off while
its cable stays plugged in, and tick it again to reconnect it. The anchor's pane also lists the
other Macs' displays and switches them over the link. This is
[Wink](https://github.com/xinding33/wink) built in, with Wink's rules:

- A display you turn off is remembered, and turned off again whenever it appears: after login,
  after sleep, after a cable change. Reconnecting it forgets it.
- The built-in screen and the last active screen stay on. Mirrored displays have to be
  un-mirrored first.
- A display is recorded in `~/Library/Application Support/Baton/displays/recovery.json` before
  it is turned off. A watchdog process reconnects the recorded displays if every remaining
  screen disappears, or if Baton stops and no new Baton has taken over 20 seconds later. It
  logs to `~/Library/Logs/Baton/display-watchdog.log`.

Where Baton differs from Wink is its own restart. Displays that are off stay off when Baton is
redeployed or restarted after a crash, so a deploy does not rearrange your windows. **Quit
Baton** reconnects them; they are turned off again when Baton next starts.

While Wink itself is running on a Mac, Baton leaves that Mac's displays alone, and its Displays
pane says so. The first time Baton takes charge of a Mac's displays, it copies the ones Wink
remembered there.

A display that is off is not part of the cursor layout. If the cursor is on a display when it
is turned off, it moves to one that is left.

## Waking together

When one Mac's display wakes, Baton wakes the displays of the others. The wake travels over
Baton's own link: a client tells the anchor, which wakes its own display and tells the other
clients. A Mac woken this way does not pass the wake on again. **Wake All Macs** in the menu bar
item, or ⌃⌥⌘W on any Mac, does the same on request, also while sharing is paused.

Only a Mac whose system is awake can be woken, since a sleeping Mac has no link. **Keep this Mac
awake** holds off idle system sleep for that reason; the display still sleeps on schedule. With
**Only on power adapter** on, a MacBook on battery sleeps as usual and is out of reach until it
wakes by itself.

While one Mac is in use, the displays of the others stay on. A Mac whose own mouse, trackpad or
keyboard is being used says so every ten seconds, and each of the others counts that as activity
of its own, so its display sleep time runs from your last input at any of them. On the anchor
that covers the shared mouse and keyboard wherever the cursor is. **Stay awake while another Mac
is in use** switches this off for one Mac, and **Only on power adapter** applies to it too. It
keeps a display on and never turns one on: a display that is asleep stays asleep, and so does a
Mac at its lock screen.

Each Mac has its own switches under **Sleep & Wake** in Settings: **Wake the other Macs when this
Mac wakes**, **Keep this Mac awake**, **Stay awake while another Mac is in use** and **Only on
power adapter**. They are kept in `wake.json` next to the config, along with the hotkey (`"hotKey": null` for none;
restart the agent after editing the file).

Baton takes over from [Ripple](https://github.com/xinding33/ripple), and a Mac's first run copies
the three switches from Ripple's settings on that Mac. Do not run the two on the same Mac: every
wake would be sent twice.

## The shared clipboard

What is copied on one Mac can be pasted on the others: text, rich text, links and images. A copy
is sent to the other Macs the moment it is made, so it is already there when the cursor arrives.
**Share the clipboard between your Macs** switches it for all of them, from any Mac: it is under
**Keyboard** in the anchor's Settings, and under **Clipboard** on a client, which has no Keyboard
pane.

Not shared:

- files copied in Finder, and anything else that refers to a file;
- anything its app marks as a password or as temporary (password managers do);
- another app's private formats: a Keynote slide arrives as its picture and text;
- a copy larger than `clipboardMaxMB` in the anchor's config (32 by default). The other Macs then
  keep what they had, and `Baton ctl clipboard` says why.

The newest copy made on any Mac wins everywhere. A Mac that was away gets it when it connects,
unless something was copied on that Mac since.

With **Handoff** on, Universal Clipboard offers each copy to the other Macs as well. Baton never
reads or passes on a clipboard that arrived that way, and keeps what it writes out of Handoff, so
the two cannot loop; but macOS may still put its own, slower copy in place of the one Baton
delivered.

Baton therefore watches the Handoff setting on every Mac. While Universal Clipboard is on on two
or more of them, the anchor's Keyboard pane has a button for each client to turn it off
on, each of those clients has one in its Clipboard pane, and the menus point there. Pressing one opens
the setting on that Mac: System Settings → General → AirDrop & Continuity → "Allow Handoff
between this Mac and your iCloud devices". The buttons go away within a few seconds of switching
it off. The anchor may keep
Handoff, so an iPhone's clipboard still reaches the anchor; Baton does not pass it on to the
clients. `Baton ctl clipboard` shows what each Mac found, including when a Handoff clipboard
last arrived there.

The clipboard has its own connection to the anchor, one port above `port`, so an image of many
megabytes never delays the heartbeat on the input link.

macOS 27.0 lets Baton read the pasteboard without asking. If a later version asks, it asks once,
on the Mac where something was just copied; set Baton to always allow under Privacy & Security →
Paste from Other Apps on each Mac. Until then that Mac still receives the others' copies, and
its menu and the clipboard's rows in its Settings say that copies made there are not shared.

## Updates

A release build updates itself from Baton's
[releases](https://github.com/xinding33/baton/releases).

Macs on different versions cannot share input, so they never update one by one. The anchor
leads, and all of them move together:

- Once a day the anchor checks GitHub. It downloads a new release, and so does every client that
  is connected. Each Mac checks that its download is that release and is signed by the same
  developer as the copy it replaces.
- Nothing changes until every connected Mac has the release ready. If one of them cannot get it,
  none is updated, and the anchor tries again an hour later.
- Then the anchor waits until the mouse and keyboard have been left alone for a minute, and never
  restarts during a keyboard handoff or while a key or mouse button is down. If they are in use
  for four hours on end, a pause in typing has to do. Every Mac swaps the
  new copy in for the one it is running, wherever that is, and restarts. The cursor comes home to
  the anchor first, and sharing is back a second or two later.
- A Mac that was asleep or away catches up by itself: when it next reaches the anchor it is told
  which version to fetch, and restarts into it.
- A Mac that is ahead of the anchor, say because it was updated by hand while the anchor was
  out of reach, pulls the anchor and the others up to its release. Versions only ever go up.

**Check for Updates…**, under **Updates** in Settings, looks now, on any Mac, and offers to
install what it finds on all of them; then a pause in typing is enough for the restart. **Install
updates automatically** is on by default. It is the anchor's switch and counts for every Mac; a client
changes it on the anchor. With it off, a new release waits for **Check for Updates…**, but Macs
on different versions are still brought to the newest one among them.

The Macs settle this on a connection of its own, two ports above `port`. It stays readable
across versions, so a Mac on an old release is not shut out the way it is from the input link.
While versions differ, each menu and each Updates pane says which Mac has which.

A development build never updates itself: `scripts/deploy.sh` installs those, and its Macs run
exactly what was deployed until the next deploy. `Baton update-check` says which kind a copy is.

## Build and deploy

```sh
swift test
scripts/deploy.sh            # build, sign, install and restart on every machine
scripts/deploy.sh mini       # only some machines
bash scripts/build.sh        # just build dist/Baton.app, ad-hoc signed
```

`scripts/deploy.sh` lists the machines and their SSH hosts, and installs a development build on
them. To put them on a release instead, which then keeps itself up to date, unzip the release
and run `BATON_APP=path/to/Baton.app scripts/deploy.sh`.

It gives every Mac the same key, and sets a Mac up without the setup window if that Mac has no
config yet. Open at Login is left as each Mac has it: where it was switched off, the new build is
started without a launch agent, and `BATON_LOGIN=on scripts/deploy.sh` switches it back on.

### Release

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, signs with the hardened
runtime, notarizes and staples the app, and publishes `Baton-x.y.z.zip` to a GitHub Release.
From then on every Mac that runs a release build installs it within a day. The workflow needs
these secrets in a `release` environment restricted to `v*` tags: `DEVELOPER_ID_P12` and
`DEVELOPER_ID_P12_PASSWORD` (the base64-encoded Developer ID Application certificate and its
password), `NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` (a base64-encoded App Store
Connect API key), and `TAP_DEPLOY_KEY` (a deploy key with write access to
[xinding33/homebrew-tap](https://github.com/xinding33/homebrew-tap)).

The workflow then writes the `baton` cask for that release to the tap, with
`scripts/update-cask.sh`. `PUBLISH_CASK` at the top of the workflow switches that step: set it to
`"false"` to publish a release without touching the tap.

To produce the same notarized ZIP locally, save notary credentials once with
`xcrun notarytool store-credentials wink-notary`, then run `bash scripts/release.sh`.

## Controls

- **⌃⌥⌘⎋** brings the cursor back to the anchor.
- **⌃⌥⌘W** wakes every Mac's display.
- The menu bar item (⇄) shows where the cursor is and can pause sharing: the cursor, the keyboard
  following it, the clipboard, and waking and staying awake together. What needs attention on
  that Mac, such as a missing permission, is at the top of its menu. See The menu and Settings.
- **Settings…** opens the window with a pane for each part of Baton.
- Unticking **Show in the menu bar**, under General, removes the item on that Mac while Baton
  keeps running. Open Baton again, or run `Baton ctl icon show`, to bring it back.
- `Baton ctl menu` prints the menu as it stands.
- `Baton ctl status` prints the agent's state; `Baton ctl home|pause|resume` control it.
- `Baton ctl keyboard` shows where the keyboard is; `keyboard move <machine>` hands it over and
  `keyboard follow on|off` switches following.
- `Baton ctl scroll` shows whether this Mac reverses the wheel, and what the last scroll event was
  and what became of it; `scroll on|off`, `scroll vertical on|off` and `scroll horizontal on|off`
  change it.
- `Baton ctl wake` shows this Mac's wake settings, the Macs it can reach, what it last did, and
  when it last told the others it is in use or heard that one of them is; `wake all` wakes every
  Mac, and `wake others on|off`, `wake keep on|off`, `wake in-use on|off` and
  `wake adapter-only on|off` change the settings.
- `Baton ctl arrange show` opens Settings on the Arrange pane.
- `Baton ctl displays` prints each Mac's displays as Settings shows them; `displays off <name>`,
  `displays on <name>` and `displays on all` switch this Mac's, and with a machine's name first
  (`displays mini off <name>`) the anchor switches another Mac's.
- `Baton display-check` prints what display control sees on a Mac. It works without the agent
  and changes nothing.
- `Baton ctl clipboard` shows what the shared clipboard last did; `clipboard on|off` switches it.
- `Baton ctl update` shows this Mac's version, what the updater is doing and, on the anchor, each
  Mac's version; `update check` looks for a release now, `update install <version>` moves every
  Mac to that release, and `update auto on|off` switches automatic updates.
- `Baton update-check` prints what kind of copy this is, how it is signed, whether it updates
  itself and the latest release. It works without the agent and changes nothing.
- `Baton ctl settings` prints what the General pane shows, without the code. `settings show
  [pane]` opens the window, `settings snapshot <png path> [pane]` draws a pane to a file and
  `settings pane <pane>` prints one. The panes are `general`, `arrange`, `keyboard`, `mouse`,
  `displays`, `wake`, `clipboard` and `updates`. `settings name|role|code|generate|login|icon ...`
  fill in General and `settings apply` presses its button; `settings press <pane> <title>` flips a
  switch or presses a button in any pane, and `settings choose <pane> <title> = <option>` picks
  from a list, which is how the shared keyboard is chosen without the mouse.
- `Baton login` says whether Open at Login is on, and `login on|off` switches it. It works
  without the agent.
- `Baton ctl sim move <dx> <dy>` (also `enter`, `click`, `key`, `scroll`) feeds synthetic input
  through the anchor, for testing without touching the mouse. On a client, `sim local` stands in
  for a touch of its trackpad and `sim sleep` goes through what it does before sleeping.

Logs are in `~/Library/Logs/Baton/baton.log`.

## Security

Machines authenticate with a shared secret, `secret.key`: 32 bytes that every Mac derives from
the pairing code (HKDF-SHA256), or that `scripts/deploy.sh` creates and copies over SSH. Control
traffic uses TLS with that secret as a pre-shared key; cursor positions travel as datagrams sealed
with a per-session ChaCha20-Poly1305 key handed out over the TLS link.

A pairing code is 25 letters and digits. 24 of them are random, which is 120 bits, and the last
one catches typing mistakes. It is that long because the key is all that protects the link: what
you type on one Mac for another, passwords included, travels under it. The handshake has no key
exchange of its own, so someone who records it can test guesses against the recording for as long
as they like, and a code found later would open what was recorded earlier. No limit on attempts
can stop that; only a code too large to search can, and 120 bits is. Anyone who has the code, or
can read `secret.key`, can control every paired Mac, so the folder is readable by its user alone.

An update is fetched from GitHub over HTTPS, by each Mac for itself; the Macs only tell each
other which version. It is installed only if it is the release build it claims to be and its
signature satisfies the designated requirement of the copy it replaces, which names the bundle
identifier and the developer's team.

## Development

Baton's implementation, tests, and documentation were developed with AI assistance.

## License

Copyright 2026 Xin Ding. Licensed under the [Apache License, Version 2.0](LICENSE).
