# On-screen keyboards

Three keyboards are installed; switch in **System Settings -> Keyboard ->
Virtual Keyboard**.

| Package | What it is |
|---|---|
| `plasma-keyboard-floating` | Default. Movable, resizable fork of KDE's Plasma Keyboard ([CC834/plasma-keyboard-floating](https://github.com/CC834/plasma-keyboard-floating)); pops up on text fields, arrows/Tab/Ctrl/Alt/Meta/Esc/F-keys. "Show Floating Keyboard" opens it where it doesn't pop up (XWayland apps). |
| `vboard` | Full PC layout, floating or docked ([keefeere/vboard](https://github.com/keefeere/vboard)); types through `/dev/uinput`, so it works in every app including terminals and XWayland. Start "Vboard" from the menu, or pick "Vboard Plasma Keyboard". Needs `python-uinput` and `CONFIG_INPUT_UINPUT`. |
| `plasma-keyboard` | KDE's stock keyboard (docked at the bottom). |

`gts7l-keyboards` sets the floating keyboard as the default and ships the
window rules for both (`/etc/xdg/kwinrc`, `/etc/xdg/kwinrulesrc`). vboard is
patched not to write a per-user rule list when its rule is already
system-wide (that list would hide the floating keyboard's rule).

Build order: `python-uinput`, `vboard`, `plasma-keyboard-floating`,
`gts7l-keyboards` (`makepkg` in each directory).
