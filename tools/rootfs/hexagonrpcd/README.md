# hexagonrpcd for gts7l

Build: linux-msm/hexagonrpc upstream `598b591`, plus these patches, in order:

- **0001-0007**, from the Galaxy Tab S8 Ultra (SM8450) port,
  [aaronsb/sm-x800-linux](https://github.com/aaronsb/sm-x800-linux)
  PR #37 (author Aaron Bockelie). Content-identical copies. 0001-0005 are
  upstream hexagonrpc PR #26 (write support for mapped directories and
  the registry's parent). 0006 adds Samsung's `sns_registry` FastRPC
  interface, and 0007 line-buffers stdout.
- **0008** (this project): the `sns_registry` property table with this
  device's values (`ro.revision` 7, SM-T875, gts7l).

hexagonrpc is GPL-3.0-or-later.

```
git clone https://github.com/linux-msm/hexagonrpc && cd hexagonrpc
git checkout 598b591 && git am /path/to/tools/rootfs/hexagonrpcd/*.patch
meson setup build --prefix=/usr --buildtype=release
ninja -C build && sudo ninja -C build install
```

Runtime setup (HexagonFS tree, service drop-in, udev rules) is in
`../slpi/` and docs/kernel-boot-debugging.md, "SLPI sensor hub, stage 2".
