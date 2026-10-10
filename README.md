# Baton

Shares one mouse and keyboard across several Macs on the same network. The cursor moves off the
edge of one Mac's screen onto the next Mac's, and typing follows it.

One Mac, the **anchor**, has the mouse and keyboard attached. It decides which machine the cursor
is on and forwards input to the others (**clients**), which replay it.

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

The easier way to change the layout is **Arrange Macs…** in the anchor's menu bar item: drag a
Mac to where it sits on your desk and drop it. It snaps against its neighbours and applies at
once. Macs that are away stay in the picture, dimmed, and keep their place.

If you edit the file by hand, restart the agent afterwards:
`launchctl kickstart -k gui/$(id -u)/com.xinding.baton`.

## The shared keyboard

With `keyboardAddress` (the keyboard's Bluetooth address) in the anchor's config, Baton tracks
which Mac the keyboard is attached to. Keys typed while the cursor is on a different Mac are
forwarded there, whichever Mac the keyboard is on.

With `keyboardFollows` on, the keyboard's Bluetooth connection itself moves to the Mac the cursor
has settled on, once typing pauses, so that Touch ID works there. `handoffStrategy` picks how:
`reconnect` (the old Mac disconnects, the new one connects) or `repair` (the old Mac forgets the
keyboard, the new one pairs with it).

## The mouse wheel

With macOS "Natural scrolling" on, Baton reverses notched mouse wheels and leaves trackpads alone,
so trackpads scroll naturally and wheels scroll the traditional way. It tells the two apart by
event, not by device: trackpads and the Magic Mouse send continuous scroll events, wheels send
discrete ones. A mouse that sends continuous events, such as a Logitech set to smooth scrolling in
Logi Options+, is treated as a trackpad.

Each Mac reverses the scrolls that land on it, whether they come from the shared mouse or from a
mouse plugged into that Mac, and has its own **Reverse Mouse Wheel** switch in the menu bar item,
with **Vertical** and **Horizontal** under it. The choice is kept in `scroll.json` next to the
config.

Baton takes over from [Backspin](https://github.com/xinding33/backspin). While Backspin or
ScrollFlip is running on a Mac, Baton does not reverse there, since two reversals cancel out, and
the menu says so. Quit the other app and Baton starts reversing at once.

## Build and install

```sh
swift test
scripts/deploy.sh            # build, sign, install and restart on every machine
scripts/deploy.sh mini       # only some machines
```

`scripts/deploy.sh` lists the machines and their SSH hosts. Each Mac needs these granted once in
System Settings → Privacy & Security:

| Mac | Permissions |
|---|---|
| anchor | Accessibility, Bluetooth |
| clients | Accessibility, Local Network, Bluetooth |

## Controls

- **⌃⌥⌘⎋** brings the cursor back to the anchor.
- The menu bar item (⇄) shows where the cursor is and can pause sharing.
- `Baton ctl status` prints the agent's state; `Baton ctl home|pause|resume` control it.
- `Baton ctl keyboard` shows where the keyboard is; `keyboard move <machine>` hands it over and
  `keyboard follow on|off` switches following.
- `Baton ctl scroll` shows whether this Mac reverses the wheel, and what the last scroll event was
  and what became of it; `scroll on|off`, `scroll vertical on|off` and `scroll horizontal on|off`
  change it.
- `Baton ctl arrange show` opens the arrangement window.
- `Baton ctl sim move <dx> <dy>` (also `enter`, `click`, `key`, `scroll`) feeds synthetic input
  through the anchor, for testing without touching the mouse.

Logs are in `~/Library/Logs/Baton/baton.log`.

## Security

Machines authenticate with a shared secret (`secret.key`, created by the first deploy and copied
over SSH). Control traffic uses TLS with that secret as a pre-shared key; cursor positions travel
as datagrams sealed with a per-session ChaCha20-Poly1305 key handed out over the TLS link.
