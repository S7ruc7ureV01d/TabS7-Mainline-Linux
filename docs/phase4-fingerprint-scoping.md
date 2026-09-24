# Phase 4: fingerprint reader scoping (2026-09-24)

**Result: not feasible on mainline Linux; parked.**

## Hardware

- Goodix **GW36T1** (GW3x family) in the power button, on SPI (stock DT
  `gfspi@0` / `gfspi-spi@0`, compatible `goodix,fingerprint`; a
  `goodix,fingerprint_factory` variant for factory builds). Reset, IRQ and
  power are GPIOs (the r07 overlay).
- The sensor's SPI pins (TLMM gpio20-23) are owned by the secure world:
  our DT keeps them in `gpio-reserved-ranges`, as the Samsung common dtsi
  does.

## Why it doesn't work from Linux

- Samsung's kernel builds `drivers/fingerprint/gw3x_*` with
  `-DENABLE_SENSORS_FPRINT_SECURE` for every non-factory build (top-level
  Makefile, `KBUILD_FP_SENSOR_CFLAGS`). In that mode the driver only
  handles power, reset and the interrupt; the SPI transfers
  (`gw3x_spidev.c`) are compiled out. Images are read and matched by a
  trusted application in the secure world, driven by Samsung's Android
  biometrics stack.
- Only factory builds (`SEC_FACTORY_BUILD`) talk to the sensor from Linux,
  with pins the production firmware doesn't hand to the normal world.
- libfprint has no driver for this sensor, and a secure-world matcher
  can't be driven from mainline (no Samsung/Goodix trusted-app interface).

## Conclusion

No path without Samsung's secure-world software; not pursued. Nothing to
capture in the stock boot either.
