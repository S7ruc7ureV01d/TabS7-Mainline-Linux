# Phase 4: LTE modem scoping (2026-09-24)

Stage 1 done (SBL runs on the X55); stage 2 in progress (Sahara session starts, SBL waits at TRDATA). SIM is in the tablet.

## What the modem is

SM8250 has **no integrated modem**. The SM-T875 uses an external
**Qualcomm SDX55 (X55)**, stock DT `mdm0: qcom,mdm0 { compatible =
"qcom,ext-sdx55m"; }` (`kona.dtsi`), attached over **PCIe2** and driven by
MHI (`kona-mhi.dtsi`: `&pcie2_rp`, `mhi,name = "esoc0"`, 111 channels,
channel 2/3 = SAHARA). It is **flashless**: the host powers it, pushes its
first-stage loader over PCIe, then serves every other image with the
Sahara protocol. (M.2 X55 modules, which mainline supports, boot from
their own flash instead.)

### Wiring (stock DT, gts7l r07 overlay)

| Signal | Where |
|---|---|
| PCIe | PCIe2 (`pcie@1c10000`): PERST gpio85, CLKREQ gpio86, WAKE gpio87; PHY supplies L9A 1.2 V, L5A 0.88 V |
| MDM2AP errfatal / status | TLMM gpio1 / gpio3 (interrupts) |
| AP2MDM errfatal / status | TLMM gpio57 / gpio56 |
| AP2MDM errfatal2 (Samsung) | PM8150L gpio7 |
| Soft reset GPIO | none on this board (`qcom,ap2mdm-soft-reset-gpio = [00]`) |
| Modem power/reset | the X55's own PMIC **PMX55 ("pmxprairie") on the SoC's SPMI bus, SID 8**, PON at 0x800 with `qcom,modem-reset` |

Stock power-on (`drivers/esoc/esoc-mdm-pon.c`, `sdx55m_toggle_soft_reset()`
-> `qpnp_pon_modem_pwr_off(PON_POWER_OFF_WARM_RESET)`): write PMX55 PON
0x863 = 0, 0x862 = reset type (warm), 0x863 = 0x80 (RESET_EN), 0x864 =
0xA5 (GO); wait 150 ms; AP2MDM_STATUS (gpio56) = 1. The X55 PBL then
brings up PCIe (device 17cb:0306). No PBLRDY GPIO: the esoc driver asks
userspace (`mdm_helper`) to confirm the link.

State on mainline today: MDM2AP status/errfatal low (X55 off), PCIe2
unused, and the PMX55 is not in our DT (mainline sees SPMI SIDs 0/1/4/5/
0xa/0xb only).

### Firmware and storage (all on the tablet already)

- **`modem` partition** (sda20, vfat, 204 MB) `image/sdx55m/`: `sbl1.mbn`,
  `aop.mbn`, `tz.mbn`, `hyp.mbn`, `devcfg.mbn`, `xbl_cfg.elf`, `apdp.mbn`,
  `sec.elf`, `multi_image_qti.mbn`, `apps.mbn` (the X55's own Linux),
  `qdsp6sw.mbn` (84 MB, modem DSP), `acdb.mbn`, `mdmddr.mbn`, `modemr.jsn`,
  512-byte `efs1/2/3.bin` placeholders; `image/modem_pr/mcfg` (carrier
  configs); `image/sdx55/qdsp6m.qdb`. Build IDs in `verinfo/`
  (e.g. `BOOT.SBL.4.1-00138-SDX55MAAAAANAZB-2`).
- **EFS (per-device NV: IMEI, RF calibration):** `mdm1m9kefs1/2/3` (2 MB
  each), `mdm1m9kefsc` (32 KB); `mdmddr` (DDR training, 1 MB). The
  modem stack **writes back** to these at runtime (EFS sync).
- **Backups (2026-09-24):** `work/backup-modem-2026-09-24/` on the PC:
  the four `mdm1m9kefs*`, `mdmddr`, `modemst1/2`, `fsg`, `fsc`, `efs`,
  `sec_efs`, sha256 in `SHA256SUMS`, verified against the device. **Not in
  git** (IMEI/calibration). Never write these partitions without a fresh
  backup.

## Boot chain (downstream Android)

1. esoc driver: PMX55 warm reset, AP2MDM_STATUS = 1.
2. PCIe link up, 17cb:0306; MHI BHI/BHIe pushes `sdx55m/sbl1.mbn`.
3. SBL pulls the rest via **Sahara** over MHI channels 2/3; on Android
   served by userspace `ks` through `/dev/mhi_0306_02.01.00_pipe_2`.
   Image IDs (from the Mi 10T port's kernel client): 6 apps, 23 aop,
   16/17/20 efs1/2/3, 34 multi_image, 25 tz, 29 acdb, 33 hyp, 40 apdp,
   41 devcfg, 42 sec.elf, else qdsp6sw.
4. `mdm_helper`: esoc ioctl handshake, BOOT_DONE.
5. Runtime: EFS sync back to `mdm1m9kefs*` via Sahara memory-debug mode on
   MHI channel 10 (`ks -m -p ..._pipe_10 ... -g mdm1`), an RFS/TFTP server
   over QRTR (instance 3), QMI over QRTR (IPCR channel), data on MHI
   IP_HW0.

## Mainline status (7.3-rc4)

- `pci_generic` knows 17cb:0306 as `qcom/sdx55m/sbl1.mbn` + EDL, for M.2
  modules: SBL only, no Sahara client for modems, no esoc/GPIO/PMIC
  sequencing, no flashless channel map.
- In-tree Sahara: only `drivers/accel/qaic/sahara.c` (AIC100). Qualcomm's
  "Sahara protocol enhancements" series (v6, 2026-07) moves it to
  `drivers/bus/mhi/host/clients` on the generic SAHARA channel, no SDX55
  table, not merged. Foxconn SAHARA channel declarations (676f19e7) are
  for ramdumps only.
- No upstream DT for any SM8250 device's embedded modem.
- Data path pieces are mainline: `MHI_NET`, `MHI_WWAN_CTRL`, `QRTR_MHI`,
  `RMNET`.

## Prior art: Xiaomi Mi 10T "apollo" (royka1, postmarketOS, kernel 7.1)

Same SoC and modem; **registers on LTE/5G, voice both ways, SMS, data**.
- Kernel: gitlab.postmarketos.org/royka1/linux, branch `apollo-7.1`
  (tag `apollo-7.1.0-r12`). Large imports: `deb1e9af` (MHI SDX55: Sahara
  v2 client on channels 2/3 with `request_firmware("sdx55m/...")`, a
  `qcom-sdx55m-fusion` pci_generic variant with the downstream channel map,
  BL logger, keepalive, MHI satellite for ADSP voice), `9b6d2e0e` (esoc
  framework import, ~5k lines), `fb67694f` (IPA MHI proxy, for the offload
  path), plus PCIe relink/L23, QRTR-over-MHI, sysmon/PDR as `esoc0`,
  q6voice over MHI.
- Userspace (github.com/royka1/Xiaomi-Apollo-pmOS-packages):
  `mdm_helper_native`, `pm_service_native` (Peripheral Manager QMI, needed
  before the modem touches secure NV), `mhi_efs_sync`, `tqftpserv-sdx55`
  (QRTR instance 3, retry on EAGAIN, else ERRFATAL), EFS extraction,
  ModemManager patches (qcom-soc plugin accepting `mhi_net`; WDS bind to
  the PCIe endpoint) and `--test-multiplex-requested` (raw IP wedges
  after ~10 MB).
- Quirks: without real NV the modem ERRFATALs ~15 s into mission mode;
  AUDIO_VOICE_0 start ERRFATALs; runtime PM/M3 must stay off; don't let
  MM probe the EFS port with AT (ERRFATAL).
- OnePlus 8T "kebab" reuses it: Sahara boot, mission mode and SIM work,
  stuck at MCFG apply (no radio).

## Stage 1 results (2026-09-24): SBL runs

- **The X55 is already powered at boot:** the bootloader leaves it in PBL.
  PCIe2 links up at 0.8 s (Gen3 x2), device `17cb:0306`, subsystem
  `17cb:010c`. MHI reads its serial number and OEM PK hash (PBL). The
  PMX55 answers on SPMI SID 8 (PON type 0x01, subtype 0x04); the
  sysfs power-on (`qcom-sdx55-ctrl`) was not needed.
- **Wrong profile:** `pci_generic` matched `foxconn-sdx55` (Foxconn's M.2
  cards share the Qualcomm reference subsystem ID and boot from their own
  flash, so no firmware). Now the board DT marks the modem
  `qcom,flashless` and `pci_generic` uses `qcom-sdx55m`
  (`qcom/sdx55m/sbl1.mbn`, copied from the `modem` partition).
- **The probe is too early** (0.8 s, no rootfs: firmware load -2).
  Rebinding `mhi-pci-generic` after boot loads SBL. To solve properly in
  stage 2 (firmware in the initramfs, or a deferred load).
- **Result:** the MHI registers (BAR0 at 0x64300000, BHI at 0x100) show
  **EXECENV = SBL**, MHISTATUS 0x201 (M0, READY), no error code. SBL now
  waits for Sahara.
- **Open:** two SMMU faults right after the SBL load: writes (SID 0x1d01)
  to 0x64100000, the MSI target (dwc uses `cfg0_base`, terminated by
  iMSI-RX). They are probably the SBL-entry notification; the host never
  logged the SBL EE change. The Mi 10T kernel uses the same MSI scheme.
  Look at this with the Sahara client in stage 2.
- The Mi 10T kernel source (apollo-7.1.0-r12) is in
  `references/apollo-linux/` (`drivers/bus/mhi/host/sahara.c`,
  `mhi_bl.c`, `satellite.c`, `mhi_chan_keepalive.c`, their `pci_generic`).

## Stage 2 (in progress, 2026-09-24): Sahara session starts, SBL waits

Work in progress, not in the patch series: `kernel/patches-wip/lte-stage2-wip.patch`
(MHI core, pci_generic, Sahara client, SBL log reader) and
`tools/rootfs/modem/` (boot helper, not enabled).

What was needed so far, in order:

1. **Flashless profile** (`qcom-sdx55m-flashless` in pci_generic): the
   downstream channel map as trimmed by the Mi 10T port - SAHARA 2/3 and
   BL 25 in SBL; DIAG, EFS, QMI/QMI1, IP_CTRL, IPCR, IP_SW0, IP_HW0 in
   mission mode. No DSP offload channels.
2. **Firmware at runtime:** `tools/rootfs/modem/sdx55-boot.sh` bind-mounts
   the `modem` partition's `image/sdx55m` read-only as
   `/lib/firmware/qcom/sdx55m`, puts read-only RAM copies of
   `mdm1m9kefs1/2/3` at `qcom/sdx55m-efs/efsN.bin` (the partition only has
   512-byte placeholders; nothing writes the real partitions), and
   rebinds `mhi-pci-generic` (the probe at 0.8 s is before the rootfs).
3. **Events are polled:** the X55's MSIs never reach the CPU (SMMU faults
   at the MSI target, the host bridge's `cfg0_base`; the SMMU sits in front
   of the DWC iMSI-RX). Identity-mapping that page (Mi 10T approach) made
   the tablet hang ~20 s later - dropped. Instead `mhi_poll_events()`
   (MHI core) runs every 2 ms from a pci_generic timer, only for this
   profile.
4. **30-bit DMA:** the firmware only reaches IOVAs up to `0x3fffffff`
   (downstream DT pool 0x20000000 + 0x1fffffff). With 32 bits the IOMMU
   put the rings near the top of the 4 GB range and SBL never wrote an
   event. `dma_data_width = 30` bounds the DMA mask and the advertised
   `iova_stop`.
5. **SBL entry from the register:** SBL sends no EE event; after READY the
   core now reads the EE register and queues the SBL transition itself
   (`sbl_ee_from_reg`, as the Mi 10T port does). This creates the SAHARA
   and BL channel devices.
6. **Polled rings:** handled event elements are zeroed (`ev_polled`) so a
   stale element can't be reprocessed on the next lap. The device does
   skip one element early on (a real all-zero element, logged "Unhandled
   event type: 0"); **don't** stop at zero elements - that lost the
   channel-start command completion.
7. **SBL boot log** (`mhi_bl_logger` on channel 25, from the Mi 10T port):
   SBL prints its log there (~3.3 KB, `\r\n` lines).

Current state:

- Sahara HELLO (v2, compatible 1, max 0x400, mode 0 = image transfer)
  arrives; our HELLO_RESP is delivered (TX completion, 48 bytes). One run
  got BAD_TRE (completion code 0x11) for the same reply, so descriptor
  delivery is not fully reliable yet.
- SBL log ends at **`TRDATA Image Load, Start`** and SBL sends no
  READ_DATA; BHI shows SBL, no error code. SBL image
  `BOOT.SBL.4.1-00157`, boot interface PCIe.
- Experiment in the tree right now: `&pcie2` without `dma-coherent`
  (testing whether the intermittent BAD_TRE is a coherency effect). The
  committed DTS keeps it coherent. No difference seen yet.

Next: find what SBL expects for "TRDATA" (probably DDR training data -
related to `mdmddr`/`mdmddr.mbn`) and whether a step is missing before its
first READ_DATA; compare with the Mi 10T port's userspace and the
downstream kickstart flow.

## Plan (stages, each testable)

1. **Power and link:** PMX55 PON node (SID 8) or a minimal reset helper,
   AP2MDM/MDM2AP GPIOs, PCIe2 + PHY enabled. Goal: 17cb:0306 enumerates
   and mainline pci_generic loads `sbl1.mbn` (SBL then waits for Sahara:
   harmless).
2. **Sahara:** port apollo's Sahara client and fusion channel map, images
   from the `modem` partition (`/lib/firmware/qcom/sdx55m` or a mount).
   Goal: X55 reaches mission mode (AMSS).
3. **Control:** QRTR over MHI, pd-mapper/sysmon, `tqftpserv` (instance 3),
   `pm_service`, EFS served **read-only first** (from the backups), then
   decide on write-back. Goal: stable mission mode, QMI answers, SIM seen.
4. **Data:** `mhi_net` on IP_HW0, rmnet/QMAP, ModemManager with apollo's
   patches. Goal: LTE data.
5. **Later:** SMS, voice (ADSP/q6voice over MHI), GPS; power management.

## Risks and open questions

- EFS/NV: IMEI and calibration live there. Keep write-back off until the
  stack is stable; backups exist.
- Samsung differences from the Xiaomi build: Samsung firmware image set is
  the same Qualcomm layout (no `multi_image.mbn`, only
  `multi_image_qti.mbn`: check Sahara ID 34), Samsung may add its own QMI
  services or NV checks (secure NV via `pm_service`?).
- The esoc framework import is large; a smaller dedicated power/boot
  driver may be enough for our needs.
- No stock-boot capture needed so far. Nice to have in the stock pass:
  logcat of `mdm_helper`/`ks`/`pm-service` and the esoc/mhi kernel log, as
  a reference sequence for this exact firmware.
