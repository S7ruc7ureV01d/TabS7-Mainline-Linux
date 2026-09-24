# Phase 4: microSD slot (done 2026-09-23)

## Wiring (stock r07 overlay, `fragment@58` on `sdhc_2`)

- `vdd-supply` = `pm8150a_l9` (L9C), 2.95-2.96 V: card supply (vmmc).
- `vdd-io-supply` = `pm8150a_l6` (L6C), 1.8-2.96 V: I/O supply (vqmmc),
  switchable to 1.8 V for UHS-I.
- `cd-gpios` = TLMM gpio77, active-low.
- Max clock 201.5 MHz (SDR104).

This is the same wiring as Qualcomm's RB5 (`qrb5165-rb5.dts`), so the
mainline node is a straight copy: `&sdhc_2` with those supplies, card
detect, 4-bit bus, `no-sdio`/`no-mmc`, RB5's SDC2 pin states (clk 16 mA,
cmd/data 10 mA pull-up). Two new PM8150L LDOs in our regulator block (L6C,
L9C). `MMC_SDHCI_MSM` was already `=y`; added `EXFAT_FS=y`.

## Result

- Probes with ADMA 64-bit; card detect works; udisks2 automounts in KDE.
- Test card (owner's Kingston 16 GB, reports `SA16G`, OEM `TM`, 06/2011,
  SDHC, speed class 4, no UHS grade): SD High-Speed, 50 MHz, 3.3 V, 4-bit.
- 512 MB direct-I/O test: **write 4.2 MB/s, read 17.4 MB/s**, md5 verified,
  no MMC errors. Both match the card (class 4, non-UHS).
- UHS-I (1.8 V signalling, SDR50/SDR104) is untested: this card doesn't
  support it.
- Userspace: `dosfstools`, `exfatprogs` installed for fsck/mkfs.

Nothing here needs stock.
