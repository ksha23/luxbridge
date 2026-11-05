# LuxBridge

LuxBridge is a macOS menu bar app that sets an external monitor's brightness from the light in
the room. It controls the monitor's real backlight over DDC/CI, the same channel as the
monitor's own buttons, and reads room light from a Home Assistant sensor, the Mac's built-in
light sensor, or both.

It suits a Mac that runs with its lid closed, where macOS's own auto-brightness can't help, and
anyone with a light sensor in Home Assistant who wants the monitor to follow it.

## What it does

- **Each display gets its own list of light sources**, tried in order. The first source with a
  fresh reading drives the display. A source can be one of these.
  - A **Home Assistant** entity that reports lux (any `illuminance` sensor), or one that reports a
    percentage, which is used as the brightness directly (handy for a template helper).
  - The **Mac's built-in light sensor**, used only while the lid is open.
- **One curve per display** maps lux to brightness. Between points it is linear in log(lux), so
  it behaves the same in a dim room and a bright one.
- **Each source has a gain** that multiplies its lux, so sensors in different places can share
  the curve. A sensor on a window sill next to the lamp sees far more light than a laptop bezel
  facing away from it. **Match** sets the gain from the other source's current reading.
- **Wobble is ignored.** Sensors flicker with shadows, clouds and their own rounding (the Aqara
  FP2 steps by 4 lux, a MacBook's sensor by 1), so a change in the light has to last before the
  brightness follows, and the bigger the change, the shorter the wait. At the default
  **Sensitivity** (Normal), changes under 30% are ignored, 30% waits a minute, 50% about 20
  seconds, and a lamp switching on or off (the light doubling or halving) about 3 seconds. High
  starts at 15% and Low at 50%. Replaying two days of readings from an FP2, following every
  reading changed the brightness about 300 times a day. Normal changes it about 45 times.
- **Changes fade.** An automatic change fades over 1.5 to 5 seconds depending on its size, eased
  in and out, one percent at a time (the smallest step a monitor takes). A brightness you pick
  yourself is applied at once.
- **The menu bar shows the light and the brightness**, such as `37 lx · 11%`, updated live, for
  the first connected display. The lux is after the source's gain, the value the curve uses. It
  can be turned off in Settings, General.
- **Manual control always wins.** There is a brightness slider for each display in the menu.
  Changing the brightness there, with the monitor's own buttons, or with another app, turns
  **Auto** off for that display, and it stays off (across reconnects and restarts) until you turn
  it back on. Turned back on, it fades to the curve's value for the light right then.
- **Calibrating is done by eye.** After a manual change the menu offers **Remember N% for L lux**,
  which adds that one point to the curve, and **Make the whole curve N% dimmer** (or brighter),
  which scales every point so the curve gives your choice at the current light. Either one turns
  Auto back on.
- **The curve editor** in Settings is a chart with a table of its points below it. Each point on
  the chart is labelled with its lux and brightness. Drag points, double-click to add one, select
  one and press Delete to remove it, or type exact values and use **Add Point** in the table.
  **Dimmer** and **Brighter** scale the whole curve by 10%. Changes show next to the saved curve
  and take effect when you click **Apply**, and **Reset** discards them.

## Robustness

- **No display, no traffic.** LuxBridge only polls Home Assistant while a display it controls is
  connected. Away from your desk it sends nothing, so your token does not leave the Mac on other
  networks.
- **No reading, no change.** If every source goes quiet (Home Assistant unreachable, the lid
  closed with only the Mac sensor set up), the display keeps its current brightness. A Home
  Assistant reading counts for 60 seconds, a Mac sensor reading for 10. A source that is known to
  be gone (lid closed, entity `unavailable`) hands over to the next one at once.
- **Network changes** reset the HTTP connections and poll again within a second. Failed polls
  back off from 2 to 30 seconds. Up to two Home Assistant addresses are tried in order, for
  example the local one and a Nabu Casa or Tailscale one.
- **Reconnects, sleep and wake** trigger a fresh scan and a fresh read of the display's
  brightness. A monitor that powers on at its own brightness is not mistaken for a manual change.
- **Displays are matched by EDID vendor, model and serial number**, so the settings follow the
  monitor across ports, docks and reboots.

## Requirements

- A Mac with Apple Silicon, macOS 14 or later.
- A monitor that supports DDC/CI. Most do, but some docks, adapters and HDMI switches do not pass
  it through. HDMI dummy plugs show up as displays but never answer, which is expected.
- For the Home Assistant source, a long-lived access token (in Home Assistant: your profile,
  then Security, then Long-lived access tokens).

Apple displays and the built-in screen are not controlled, since macOS already handles those.

## Install

There is no prebuilt download, so build it from source. This needs Xcode 15.3 or later (or its
Command Line Tools).

```
git clone https://github.com/ksha23/luxbridge.git
cd luxbridge
scripts/build-app.sh
ditto build/LuxBridge.app /Applications/LuxBridge.app
```

The script signs the app ad hoc, which is enough to run it on the Mac that built it.

## Setup

1. Open LuxBridge. A sun appears in the menu bar.
2. Settings, Home Assistant: enter the address (for example `http://homeassistant.local:8123`)
   and paste the token. **Save and Test** should report the location name and version. macOS
   asks once for local network access. Allow it.
3. Settings, Displays: click **+**, pick the monitor, then set up its sources. Choose the Home
   Assistant sensor from the list, put the sources in the order you prefer, and use **Match** to
   line up the second source's gain with the first.
4. Live with it for a day. When the brightness feels wrong, set it from the menu bar, then click
   **Remember …** to fix that one light level, or **Make the whole curve … dimmer** if it is off
   everywhere.
5. Settings, General: turn on **Open at login**.

The token is stored in the login Keychain. Settings are in the app's defaults
(`io.github.ksha23.LuxBridge`).

## Command line

The app binary doubles as a small diagnostic tool:

```
LuxBridge.app/Contents/MacOS/LuxBridge list             # external displays and their DDC status
LuxBridge.app/Contents/MacOS/LuxBridge get 1            # display 1's brightness
LuxBridge.app/Contents/MacOS/LuxBridge set 1 40         # set display 1 to 40%
LuxBridge.app/Contents/MacOS/LuxBridge config           # settings as JSON (no token)
LuxBridge.app/Contents/MacOS/LuxBridge config import    # replace settings from stdin
LuxBridge.app/Contents/MacOS/LuxBridge token            # store a token read from stdin
```

Quit the app before importing settings, or it will overwrite them on its next change.

## Building

```
swift test                     # unit tests for the curve, filter, engine, parsing and DDC packets
LUXBRIDGE_REPLAY=history.json swift test --filter ReplayTests   # replay a recording at each sensitivity
scripts/build-app.sh           # build/LuxBridge.app, signed ad hoc
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=… scripts/build-app.sh
```

With `SIGN_IDENTITY` and `NOTARY_PROFILE` (a `notarytool store-credentials` profile) the script
also notarizes and staples the app and leaves a shareable `build/LuxBridge.zip`.

## How it is built

| Module | Role |
|---|---|
| `LuxBridgeCore` | The curve, the lux filter, the per-display engine, settings and the Home Assistant client. Pure Swift with no I/O in the engine, so it is unit tested. |
| `DDCKit` | Finds external displays, pairs each with its `DCPAVServiceProxy`, and reads and writes VCP codes over I2C. |
| `SystemSensors` | The built-in ambient light sensor (IOHID) and the lid state. |
| `LuxBridge` | The menu bar app: an AppKit status item and panel, and a Settings window, around SwiftUI views. A 0.2 second tick drives the display scan, sensor polling and DDC writes. |

DDC and the light sensor use private Apple APIs (`IOAVService`, `IOHIDEventSystemClient`,
`CoreDisplay_DisplayCreateInfoDictionary`). They are looked up at run time, so a future macOS
that removes one disables that feature instead of crashing.

## Credits

The DDC approach on Apple Silicon follows [m1ddc](https://github.com/waydabber/m1ddc) and
[MonitorControl](https://github.com/MonitorControl/MonitorControl), and reading the light sensor
follows [Lunar](https://github.com/alin23/Lunar).

## License

MIT
