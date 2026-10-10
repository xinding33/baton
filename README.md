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

Restart the agent after editing: `launchctl kickstart -k gui/$(id -u)/com.xinding.baton`.

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
| anchor | Accessibility, Input Monitoring |
| clients | Accessibility, Local Network |

## Controls

- **⌃⌥⌘⎋** brings the cursor back to the anchor.
- The menu bar item (⇄) shows where the cursor is and can pause sharing.
- `Baton ctl status` prints the agent's state; `Baton ctl home|pause|resume` control it.
- `Baton ctl sim move <dx> <dy>` (also `enter`, `click`, `key`, `scroll`) feeds synthetic input
  through the anchor, for testing without touching the mouse.

Logs are in `~/Library/Logs/Baton/baton.log`.

## Security

Machines authenticate with a shared secret (`secret.key`, created by the first deploy and copied
over SSH). Control traffic uses TLS with that secret as a pre-shared key; cursor positions travel
as datagrams sealed with a per-session ChaCha20-Poly1305 key handed out over the TLS link.
