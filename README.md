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

## Using a Mac's own trackpad

Touching a client's own trackpad, mouse or keyboard brings the shared cursor to that Mac, at the
spot where its cursor is. The mouse then carries on from there. Keys from a client's own keyboard
only count while the shared keyboard is attached to another Mac; Baton cannot tell two keyboards
on one Mac apart.

## The shared keyboard

With `keyboardAddress` (the keyboard's Bluetooth address) in the anchor's config, Baton tracks
which Mac the keyboard is attached to. Keys typed while the cursor is on a different Mac are
forwarded there, whichever Mac the keyboard is on.

With `keyboardFollows` on, the keyboard's Bluetooth connection itself moves to the Mac the cursor
has settled on, once typing pauses, so that Touch ID works there. `handoffStrategy` picks how:
`reconnect` (the old Mac disconnects, the new one connects) or `repair` (the old Mac forgets the
keyboard, the new one pairs with it).

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
mouse plugged into that Mac, and has its own **Reverse Mouse Wheel** switch in the menu bar item,
with **Vertical** and **Horizontal** under it. The choice is kept in `scroll.json` next to the
config.

Baton takes over from [Backspin](https://github.com/xinding33/backspin). Do not run the two on the
same Mac: two reversals cancel out.

## Displays

Each Mac's menu lists its external displays. Click one to turn it off while its cable stays
plugged in, and click it again to reconnect it. The anchor's menu also lists the other Macs'
displays and switches them over the link. This is [Wink](https://github.com/xinding33/wink)
built in, with Wink's rules:

- A display you turn off is remembered, and turned off again whenever it appears: after login,
  after sleep, after a cable change. Reconnecting it from the menu forgets it.
- The built-in screen and the last active screen stay on. Mirrored displays have to be
  un-mirrored first.
- A display is recorded in `~/Library/Application Support/Baton/displays/recovery.json` before
  it is turned off. A watchdog process reconnects the recorded displays if every remaining
  screen disappears, or if Baton stops and no new Baton has taken over 20 seconds later. It
  logs to `~/Library/Logs/Baton/display-watchdog.log`.

Where Baton differs from Wink is its own restart. Displays that are off stay off when Baton is
redeployed or restarted after a crash, so a deploy does not rearrange your windows. **Quit
Baton** reconnects them; they are turned off again when Baton next starts.

While Wink itself is running on a Mac, Baton leaves that Mac's displays alone, and its menu
says so. The first time Baton takes charge of a Mac's displays, it copies the ones Wink
remembered there.

A display that is off is not part of the cursor layout. If the cursor is on a display when it
is turned off, it moves to one that is left.

## Waking together

When one Mac's display wakes, Baton wakes the displays of the others. The wake travels over
Baton's own link: a client tells the anchor, which wakes its own display and tells the other
clients. A Mac woken this way does not pass the wake on again. **Wake All Macs** in the menu bar
item, or ⌃⌥⌘W on any Mac, does the same on request.

Only a Mac whose system is awake can be woken, since a sleeping Mac has no link. **Keep This Mac
Awake** holds off idle system sleep for that reason; the display still sleeps on schedule. With
**Only on Power Adapter** on, a MacBook on battery sleeps as usual and is out of reach until it
wakes by itself.

Each Mac has its own switches in the menu bar item: **Wake Others When This Mac Wakes**, **Keep
This Mac Awake** and **Only on Power Adapter**. They are kept in `wake.json` next to the config,
along with the hotkey (`"hotKey": null` for none; restart the agent after editing the file).

Baton takes over from [Ripple](https://github.com/xinding33/ripple), and a Mac's first run copies
the three switches from Ripple's settings on that Mac. While Ripple is running on a Mac, Baton
leaves waking, the hotkey and keeping awake to it there, and the menu says so; the anchor still
passes other Macs' wakes along. Quit Ripple and Baton takes over at once.
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
- **⌃⌥⌘W** wakes every Mac's display.
- The menu bar item (⇄) shows where the cursor is and can pause sharing.
- **Hide Menu Bar Icon…** removes the item on that Mac while Baton keeps running. Open Baton again
  (`open ~/Applications/Baton.app`), or run `Baton ctl icon show`, to bring it back.
- `Baton ctl status` prints the agent's state; `Baton ctl home|pause|resume` control it.
- `Baton ctl keyboard` shows where the keyboard is; `keyboard move <machine>` hands it over and
  `keyboard follow on|off` switches following.
- `Baton ctl scroll` shows whether this Mac reverses the wheel, and what the last scroll event was
  and what became of it; `scroll on|off`, `scroll vertical on|off` and `scroll horizontal on|off`
  change it.
- `Baton ctl wake` shows this Mac's wake settings, the Macs it can reach and what it last did;
  `wake all` wakes every Mac, and `wake others on|off`, `wake keep on|off` and
  `wake adapter-only on|off` change the settings.
- `Baton ctl arrange show` opens the arrangement window.
- `Baton ctl displays` prints each Mac's displays as the menu shows them; `displays off <name>`,
  `displays on <name>` and `displays on all` switch this Mac's, and with a machine's name first
  (`displays mini off <name>`) the anchor switches another Mac's.
- `Baton display-check` prints what display control sees on a Mac. It works without the agent
  and changes nothing.
- `Baton ctl clipboard` shows what the shared clipboard last did; `clipboard on|off` switches it.
- `Baton ctl sim move <dx> <dy>` (also `enter`, `click`, `key`, `scroll`) feeds synthetic input
  through the anchor, for testing without touching the mouse. On a client, `sim local` stands in
  for a touch of its trackpad and `sim sleep` goes through what it does before sleeping.

Logs are in `~/Library/Logs/Baton/baton.log`.

## Security

Machines authenticate with a shared secret (`secret.key`, created by the first deploy and copied
over SSH). Control traffic uses TLS with that secret as a pre-shared key; cursor positions travel
as datagrams sealed with a per-session ChaCha20-Poly1305 key handed out over the TLS link.
