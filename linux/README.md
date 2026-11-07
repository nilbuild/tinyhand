# TinyHand for KDE Plasma

A port of TinyHand to Linux. It runs on KDE Plasma 6 with Wayland and uses the same
36 hand images and tap sounds as the Mac app.

## What you need

TinyHand is a Python program. It needs these packages:

| Distribution | Command |
|---|---|
| Fedora | `sudo dnf install python3-pyside6 python3-numpy layer-shell-qt` |
| Debian, Ubuntu, KDE neon | `sudo apt install python3-pyside6.qtwidgets python3-pyside6.qtdbus python3-pyside6.qtmultimedia python3-numpy liblayershellqtinterface6` |
| Arch | `sudo pacman -S pyside6 python-numpy layer-shell-qt` |

`layer-shell-qt` is part of Plasma. It lets the hand sit above every window and the panel.

## Install

From the repository root:

```sh
sh linux/install.sh
```

The script copies TinyHand to `~/.local/share/tinyhand`, puts a `tinyhand` command into
`~/.local/bin`, and adds a launcher entry with an icon. Run `sh linux/install.sh --uninstall`
to remove it again. Your settings stay in `~/.config/tinyhand/tinyhand.ini`.

Start TinyHand from the launcher or with `tinyhand`. It shows a hand icon in the system tray.
Turn on "Open at login" in the settings if you want it to start with Plasma.

You can also run it from the checkout without an install: `python3 linux/run.py`.

## Use

| | |
|---|---|
| Click the tray icon, or **Ctrl+Alt+H** | Turn the pointer on or off |
| Right-click the tray icon | Menu and Settings |
| Click | Tap (nothing underneath gets clicked) |
| Hold and drag | Draw on the screen |
| Right-click | The hand steps aside for 3 seconds so that you can click the real thing |
| **Ctrl+Alt+X** | Clear the drawing |
| **Esc** | Clear everything and turn the pointer off |

While the pointer is on, a small toolbar at the bottom of the screen lets you pick one of
the pinned hands or the laser dot, change the ink colour, mute the tap sound, or exit.

The shortcuts are registered with KDE. Change them in System Settings > Keyboard >
Shortcuts under "TinyHand". The settings window has a button that opens that page.

The command line controls a running TinyHand, for example from a Stream Deck or a script:

```sh
tinyhand --toggle     # pointer on or off
tinyhand --on
tinyhand --off
tinyhand --clear      # clear the drawing
tinyhand --settings   # open the settings window
tinyhand --quit
```

The same commands exist on D-Bus as `app.tinyhand` at `/app/tinyhand`, interface
`app.tinyhand.TinyHand`, with the methods `Toggle`, `TurnOn`, `TurnOff`, `Clear`,
`Settings`, `Reload`, `Quit`, and `IsActive`.

## Your own hands

Put a PNG into `~/.local/share/tinyhand/hands/`. The image must have a transparent
background and show the hand on its stick with the fingertip at the top, like the files in
`assets/`. The file name becomes the name in the settings window. The ink colour comes from
the colour of the hand.

## Differences from the Mac app

Wayland does not let one app read the mouse position or pass clicks to another window. The
port works within that:

- The hand is drawn on a transparent layer that covers each screen. While the pointer is on,
  the layer takes the mouse, so clicks tap and drags draw, like on the Mac.
- There is no "hold a key to click for real". Instead, a right-click (or middle-click, see the
  settings) hides the hand and lets clicks through for a few seconds.
- Keyboard input keeps going to your apps while the pointer is on. Esc works through a global
  shortcut that is active only while the pointer is on.
- Global shortcuts come from KDE's KGlobalAccel, so they work on Wayland and X11, but only on
  Plasma. On other desktops the tray icon and the command line still work.
- Multiple screens: the hand follows the mouse to whichever screen it is on.
- There is no automatic update. Pull the repository and run the install script again.

X11 sessions run with a plain always-on-top window. That path has had less testing than
Wayland.

## How the code is laid out

```
linux/
  run.py                  entry point for a checkout or an install directory
  install.sh              user or system install, with --uninstall
  tinyhand/
    __main__.py           command line, forwards to the running app over D-Bus
    app.py                tray icon, D-Bus service, global shortcuts, pointer controller
    overlay.py            one transparent layer-shell window per screen
    arm.py                hand pose and painting (a port of ArmView.swift)
    ink.py                strokes and fading (a port of Ink.swift)
    toolbar.py            the bottom toolbar, ink tray and first-run hint
    styles.py             the style table and the hand image measuring (PointerStyle.swift)
    prefs.py              QSettings-backed preferences
    shortcuts.py          KGlobalAccel over D-Bus
    sound.py              tap sounds with QSoundEffect
    layershell.py         ctypes bridge to LayerShellQt
    settings_ui.py        the settings window (runs as its own process)
  data/                   desktop file and icons
```

Set `TINYHAND_DEBUG=1` to print per-second paint and event counts while the pointer is on.
