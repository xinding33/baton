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

## The shared clipboard

What is copied on one Mac can be pasted on the others: text, rich text, links and images. A copy
is sent to the other Macs the moment it is made, so it is already there when the cursor arrives.
**Share clipboard** in the menu bar item, on any Mac, switches it for all of them.

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
delivered. Turning Handoff off on the clients (System Settings → General → AirDrop & Handoff)
rules that out. With it left on at the anchor, an iPhone's clipboard still reaches the anchor;
Baton does not pass it on to the clients.

The clipboard has its own connection to the anchor, one port above `port`, so an image of many
megabytes never delays the heartbeat on the input link.

macOS 27.0 lets Baton read the pasteboard without asking. If a later version asks, it asks once,
on the Mac where something was just copied; set Baton to always allow under Privacy & Security →
Paste from Other Apps on each Mac. Until then that Mac still receives the others' copies, and
its menu says that copies made there are not shared.

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
- `Baton ctl arrange show` opens the arrangement window.
- `Baton ctl clipboard` shows what the shared clipboard last did; `clipboard on|off` switches it.
- `Baton ctl sim move <dx> <dy>` (also `enter`, `click`, `key`, `scroll`) feeds synthetic input
  through the anchor, for testing without touching the mouse.

Logs are in `~/Library/Logs/Baton/baton.log`.

## Security

Machines authenticate with a shared secret (`secret.key`, created by the first deploy and copied
over SSH). Control traffic uses TLS with that secret as a pre-shared key; cursor positions travel
as datagrams sealed with a per-session ChaCha20-Poly1305 key handed out over the TLS link.
