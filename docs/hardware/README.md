# Hardware inventory

One place that answers "what do I actually own, and what can it do". Hand-maintained;
specs were collected over SSH (`lscpu`, `free`, `lsblk`, `nvidia-smi`, `dmidecode`) on
2026-08-21 and updated 2026-09-08, so re-check before buying parts. Gaps are marked **?**.

**Two management domains.** Hardware splits between this repo and the `bump` repo. A
machine listed here does not imply this repo configures it (`jason-nuc` is bump's, and so
are the Android runners on `nas`). Don't "fix" a host's absence from an inventory group
without checking whether bump already manages it.

## Managed Linux hosts

| Host | Model / board | CPU | RAM | GPU (VRAM) | OS |
|---|---|---|---|---|---|
| `nas` | UGREEN DXP8800 Plus (RP0R0160) | i5-1235U, 12 threads | 96 GB DDR5 (2× 48 GB SODIMM; 94 GiB usable) | Iris Xe (iGPU) | Debian 12, kernel 6.12 |
| `ubuntu-beast` | Gigabyte X570 AORUS ELITE | Ryzen 9 5900X, 24 threads | 128 GB = 4× 32 GB DDR4-3200 | RTX 5080 **16 GB** + RTX 3080 **10 GB** (moved from cube) | Ubuntu, dual-boot Windows |
| `ubuntu-cube` | JINGSHA B75-HM PLUS | i7-3770, 8 threads | 32 GB = 4× 8 GB DDR3-1333 | none (3080 moved to beast) | Ubuntu 24.04, kernel 6.8 |
| `ubuntu-silverstone` | Gigabyte H110M-S2H | i5-7500, 4 threads | 32 GB = 2× 16 GB DDR4-2400 | Intel HD 630 | Ubuntu 24.04, kernel 6.8 |
| `ubuntu-work-laptop` | Lenovo ThinkPad P16s Gen 1 (21BT0049US) | i7-1260P, 16 threads | 32 GB = 2× 16 GB DDR4-3200, both slots full | Iris Xe + NVIDIA T550 **4 GB** | Ubuntu 24.04, kernel 7.0 |
| `jasons-macbook-air` | MacBook Air (Mac16,12) | Apple M4, 10 cores (4P+6E) | 16 GB | integrated | macOS |
| `jason-nuc` | Intel NUC | **?** | **?** | **?** | bump repo, separate tailnet |
| `ubuntu-asus-laptop` | ASUS G46V (Ivy Bridge, DDR3) | — | — | — | **unprovisioned** — was an Omarchy/NixOS playground |
| `ubuntu-toshiba-laptop` | Toshiba L755 (DDR3) | — | — | — | **unprovisioned** — ex-airgapped RightMesh wallet; **full-disk erase before reinstall** (may hold key material) |
| `ubuntu-toshiba-mini-laptop` | Toshiba NB305 netbook | — | — | — | **unprovisioned** — died mid-write on battery failure; **check SMART** before trusting the disk |

**VRAM summary:** beast 16 + 10 GB (two cards, not pooled — a single model needs to fit in
one), work laptop 4 GB, everything else iGPU only. On the X570 AORUS ELITE the second x16
slot is x4 from the chipset — fine for inference, slower model loads for whichever card
sits there.

### Storage

| Host | Disks | Free |
|---|---|---|
| `nas` | 4× 20 TB Seagate ST20000NM004E + 2× 22 TB ST22000NM000C (~124 TB raw) · NVMe: 931 GB GIGABYTE, 931 GB WD WDS100T1X0E, 119 GB YSO128GTLCW | `/volume1` (bcache) 91 T, 25 T free · `/overlay` 107 G system partition, ~24 G free (see #544) |
| `ubuntu-beast` | `nvme0n1` 4 TB XG7000 (Linux, ext4 `/`) · `nvme1n1` 4 TB XG7000 (Windows) · `sda` 18 TB WUH721816ALE6L4 · `sdb` 1 TB WD1002FAEX | root 3.7 T, 2.8 T free. **The 18 TB and 1 TB HDDs are installed but unpartitioned and unmounted** |
| `ubuntu-cube` | 3.7 TB SPCC NVMe (root) · 931 GB WDC SSD · 4× 931 GB WDC HDD | root 3.7 T, 3.4 T free |
| `ubuntu-silverstone` | 954 GB SPCC SSD · 112 GB Corsair SSD | root 938 G, 851 G free |
| `ubuntu-work-laptop` | 954 GB SK Hynix NVMe | root 937 G, 609 G free |
| `jasons-macbook-air` | 228 GB internal | 87 GB free |

### Memory detail

- **beast:** all four slots full, XMP applied (running at rated 3200). Two different kits —
  2× Corsair `CMK64GX4M2E3200C16` and 2× `MR[ABC]4U320GJJM32G`. Works at full speed, but
  mixed kits on a 4-DIMM AM4 board get fussy above 3200; remember before adding/replacing.
- **silverstone:** one Corsair `CMK32GX4M2Z2400C16` kit, one module per channel. DMI advertises
  two more slots but the H110M-S2H commonly has only two physical — confirm with
  `sudo dmidecode -t 16` before buying; expansion likely means replacing the pair.
- **cube:** 4× 8 GB DDR3-1333 (part `994055`, JEDEC id `8394`). Ivy Bridge supports 1600,
  so either the modules' rating or a conservative board. Slow RAM + PCIe 2.0 made it a poor
  GPU host for anything that spilled out of VRAM, which is why the 3080 moved to beast.
- **work laptop:** already a mixed pair (`M471A2G44BM0-CWE` + `M471A2G43BB2-CWE`), so it has
  been upgraded at least once.

### `ubuntu-beast` power

PSU: Corsair **HX1000** (2017, CP-9020139-NA), 1000 W 80+ Platinum, fully modular Type-4,
bought 2021-05-11 (warranty to May 2031). Dual-GPU budget:

| Part | Sustained W | Transient W |
|---|---|---|
| RTX 5080 (360 W TGP) | 360 | ~500+ |
| RTX 3080 | 340 | ~600 |
| 5900X (142 W PPT) | 150 | 200 |
| X570 + 128 GB + 2× NVMe | 60 | |
| 18 TB + 1 TB HDDs | 15 | ~40 spinup |
| Fans, USB (phones, webcam) | 40 | |
| **Total** | **~965** | **~1400** |

Decision: keep the HX1000. Realistic loads (LLM inference ~600–700 W, gaming ~600 W) leave
~300 W headroom; only sustained dual-GPU saturation approaches the rating. Checklist: rear
switch on **single rail**; Corsair 600 W 12VHPWR cable (CP-8920284) for the 5080, two
separate PCIe cables for the 3080, no pigtails. Hard resets to black under dual-GPU load =
OPP trip → HX1200i. 1500 W buys nothing here.

### Cloud (terraform-managed)

All DigitalOcean; sizes are authoritative in `terraform/*.tf`.

| Droplet | Size | Region | Role |
|---|---|---|---|
| `www` (droplet `mail.jasonernst.com`) | `s-1vcpu-2gb` | sfo2 | website **and** mail; joins the tailnet as `www` |
| `projects` | `s-2vcpu-4gb` | sfo3 | rustd.xyz JVM app + postgres; **disk resize is one-way** |
| `hermes` | `s-1vcpu-2gb` | sfo3 | agent host (kai) |

## Power & remote management

- CyberPower **CP1500PFCLCD** UPS (**1000 W output**) powering `nas`, `ubuntu-beast`, and the
  router. USB to `nas`, which broadcasts shutdown over the network so beast shuts down safely.
  Beast at full dual-GPU load is ~1050–1100 W at the wall on its own, plus nas (~120 W with six
  spinning drives) — a sustained heavy run overloads the UPS regardless of PSU. Either split
  nas+router onto a second UPS or accept that heavy runs on beast aren't protected.
- 2× **JetKVM**, attached to `ubuntu-cube` and `ubuntu-silverstone` for remote power-button presses.

## Network

10GbE 8-port unmanaged switch · 1GbE 8-port unmanaged switch · TP-Link Archer router · several
other WiFi routers. Both switches are unmanaged, so IoT segmentation has to come from the
Archer's guest SSID, not VLANs.

## Smart home / IoT

Home Assistant runs on `nas` (`ansible/roles/home_assistant`), and Zigbee goes through it:

- **SONOFF ZBDongle-E** (EFR32MG24) Zigbee coordinator, USB on `nas`, passed into the HA
  container by `/dev/serial/by-id` as `/dev/ttyUSB0` for **ZHA**.
- **AirCube Pro** ([stuckatprototype.com](https://stuckatprototype.com/products/aircube)) —
  ESP32-H2 Zigbee air-quality sensor, USB-C powered, in the **dining room**. Sensors: SCD41
  NDIR CO₂, ENS210 temp/humidity, ENS16x VOC, VCNL4040 ambient light. Exposed in HA as
  AirCube Humidity / Temperature, CO2, Illuminance, and the LED brightness control.

| Qty | Device | Notes |
|---|---|---|
| 1 | AirCube Pro | Zigbee via ZHA, dining room (above) |
| 3 | Mysa smart baseboard thermostat | controls actual heating; also reports temp/humidity into HA |
| 1 | Mysa AC thermostat | |
| 2 | Roku | |
| 1 | Google Chromecast | |
| 1 | Google Chromecast Ultra | |
| 2 | Google Home speaker | always-listening |
| 1 | WiZ smart bulb | |

Eleven cloud-dependent closed-firmware devices on the LAN. Record which SSID each is on;
"we should segment IoT" is not the same as "these are on the guest network". The Mysas are
load-bearing (a failure is a cold house) — worth knowing whether they hold a local schedule
when the WAN is down, in a month that isn't January.

## DePIN / crypto appliances

- **Hivemapper dashcam**
- **Bobcat Helium miner** (LoRaWAN hotspot)

For each: is it powered and on the LAN, which segment, is the wallet still live? An idle
miner on vendor firmware is exactly the device that gets forgotten and becomes the way in.

## SBCs / dev boards

Orange Pi · Rubik Pi 3 · RPi 2B · RPi 3B · RPi Zero · NVIDIA Jetson P3450 (Nano dev kit) ·
MYD-YT113X · TI LaunchPad · assorted Arduinos (count **?**) · RPi PoE HAT

**Android TV boxes:** TX3 Pro · T95 · MXQ Pro 4K 5G · X88 Pro 10. Amlogic/Rockchip-class;
cheapest ARM compute in the house and Armbian/CoreELEC targets, but stock firmware is stale
and often ships with vendor spyware — treat any still-stock box as untrusted on the network.

## Radio / vision / sensors

Flipper Zero · 2× HackRF One · RTL2832U SDR · OAK-D Lite · Intel RealSense D435 · Logitech C920
HD Pro Webcam (046d:0892, on beast) · Logi Bolt receiver (046d:c548) · 2× XY-3606 DC-DC converters

## AV / home

Valve Index · Lovesac surround system · LG TV · Samsung TV

## Spare parts — laptop SODIMMs

72 GB across 6 modules (identified from photos, 2026-08-21):

| Qty | Size | Type | Part | Fits |
|---|---|---|---|---|
| 1 | 32 GB | DDR4-2400 CL17 | OLOy Cardinal `MD4S322417MZSC` | work laptop only (replaces a 16 GB → 48 GB, but the whole machine drops to 2400); origin unknown |
| 1 | 16 GB | DDR4-2666 2Rx8 | Samsung `M471A2K43CB1-CTD` | work laptop (no gain — slots full at 16 GB each) |
| 1 | 8 GB | DDR4-2666 1Rx8 | SK hynix `HMA81GS6JJR8N-VK` | " |
| 1 | 8 GB | DDR5-4800 1Rx16 | Samsung `M425R1GB4BB0-CQK0L` | almost certainly the NAS's original stick — keep as a NAS diagnostic module |
| 2 | 4 GB | DDR3-1600 2Rx8 | hynix `HMT351S6CFR8C-PB` (matched pair) | Toshiba L755 or ASUS G46V rebuilds (only an upgrade if what's in them is smaller); not cube (full) |

## Phones

### iPhones

Collect with `ideviceinfo` (`libimobiledevice-utils`) after unlocking and accepting Trust.

| UDID | Model | iOS | Model no. | Region | Notes |
|---|---|---|---|---|---|
| `00008140-0006646C0EE3001C` | iPhone 16 Pro (`iPhone17,1`) | 26.6 | MYMQ3 | `LL/A` USA | Jason's personal phone |
| `dbba359f3fb7841d9d5f2aa7057dfeb213ca01c1` | iPhone 7 (`iPhone9,3`) | 13.6.1 | MN952 | `VC/A` Canada | only older-iOS target; could go to 15.8 but 13 is more useful |

`ProductType` runs a generation ahead of the marketing name (`iPhone17,1` = iPhone **16** Pro).
The `RegionInfo` suffix is fixed at manufacture, so unlike Samsung CSC it *is* reliable
sourcing evidence.

### Android

Collect as each one is plugged in:

```bash
for s in $(adb devices | awk 'NR>1 && $2=="device"{print $1}'); do
  adb -s "$s" shell 'getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk' \
    | tr -d '\r' | paste -sd' | ' - | sed "s|^|$s \| |"
done
# sourcing
adb -s "$s" shell 'getprop ro.product.locale; getprop ro.csc.country_code; getprop ro.csc.countryiso_code; getprop ro.carrier; getprop gsm.sim.operator.iso-country; getprop ro.boot.hardware.sku' | tr -d '\r'
```

"Attached to" = permanently wired into that host. **Floating** = bench pile. `ubuntu-cube` and
`ubuntu-silverstone` run adb on **port 5038** (`adb -P 5038`); everywhere else plain `adb`.

| Serial | Make / model | Android | SDK | Sourced | Attached to |
|---|---|---|---|---|---|
| `ONROHI45DFM5FY` | Google Pixel 7 (`panther`, `GQML3`) | 17 | 37 | USA (default) | **jason-nuc** (bump) — top of the API range |
| `39111JEHN16292` | Google Pixel 7a (`lynx`, `GWKK3`) | 16 | 36 | USA (default) | **jason-nuc** (bump) |
| `29161FDH3001RL` | Google Pixel 7 Pro | 14 | 34 | USA | **nas** (bump runner) — runs FHD+ on a QHD panel; physical ≠ stable size is normal |
| `09231JECB04544` | Google Pixel 4a (5G) | 13 | 33 | USA | **nas** (bump runner) |
| `R83Y50MPEHJ` | Samsung SM-A065M (Galaxy A06) | 14 | 34 | USA; LATAM firmware | **ubuntu-cube** (SAIR, 5038) — AU candidate, probe CSC |
| `RFGYA0MVESY` | Samsung SM-A165M (Galaxy A16) | 16 | 36 | USA; LATAM firmware | **ubuntu-cube** (SAIR, 5038) — AU candidate, probe CSC |
| `4301c743b007a000` | Samsung SM-G3502 (Galaxy Core Plus) | 4.2.2 | 17 | CSC `CN`; purchase **?** | **ubuntu-silverstone** (5038) — isolated smoke-test device, **not** SAIR |
| `17091JECB11203` | Google Pixel 5a | 13 | 33 | USA | floating — ex-nuc, healthy, candidate runner |
| `17161JECB05989` | Google Pixel 5a | 13 | 33 | USA | floating — ex-nuc, **faulty panel/digitizer** (see below), runner after repair |
| unknown | Google Pixel 5a (5G) | ? | ? | USA | **broken USB port, out of rotation** — parts donor for the above |
| `9A301FFAZ00BKF` | Google Pixel 4 | 11 | 30 | USA | floating (EOL for security updates) |
| `0A081FDD4003V1` | Google Pixel 5 | 12 | 31 | USA | floating (EOL) |
| `RXCYA033GAM` | Samsung SM-A176B (Galaxy A17 5G) | 16 | 36 | **Brazil** 🏷️ | floating |
| `R9XYC01X76F` | Samsung SM-A075M (Galaxy A07) | 16 | 36 | **Brazil** 🏷️ | floating |
| `ZF525FCBWW` | Motorola moto g15 | 15 | 35 | **Brazil** 🏷️ | floating — pairs with `ZY32L8D47K` |
| `ZY32L8D47K` | Motorola moto g15 | 15 | 35 | USA | floating — same model, different region: the cleanest regional A/B in the fleet |
| `gqqwgqr8f6tc5h95` | Xiaomi 24117RN76L (Redmi 14C) | 15 | 35 | **Brazil** 🏷️ | floating |
| `5HAMRK79PZKJPJCU` | Xiaomi 25078RA3EA | 15 | 35 | USA | floating — needed the udev fix below |
| `NOTE560000000004791` | DOOGEE Note 56 | 16 | 36 | USA | floating |
| `R58RA3WBX1H` | Samsung SM-A127M (Galaxy A12 Nacho) | 13 | 33 | USA; LATAM firmware | floating |
| `R58TC03CHPW` | Samsung SM-A135F (Galaxy A13) | 12 | 31 | **Australia** ✅ verified | floating |
| `320424269195` | ZTE Blade L9 | 11 | 30 | USA | floating |
| `0123456789ABCDEF` ⚠️ | XGODY V40 | 10 | 29 | USA | floating — **placeholder serial** |
| `20220415A0100368` | XGODY V40 | 10 | 29 | USA | floating — real serial; pairs with the above |
| `4301b494b6098000` | Samsung SM-G3502 (Galaxy Core Plus) | 4.2.2 | 17 | USA | floating — pairs with the silverstone unit |
| `MPIFC28N1H01362` | YUSUN LA2-SN | 4.4.4 | 19 | USA | floating — legacy |

Coverage: API 17, 19, then 29–37 contiguous, across Google, Samsung, Motorola, Xiaomi. The
low-end Brazilian handsets matter as much as the flagships — small RAM surfaces bugs a Pixel
7 Pro never will.

**Sourcing is provisional.** Brazil purchases are **physically taped** — that tape outranks
every inference (model suffix, CSC, locale). Everything marked "USA" is a default; a couple
came from Australia (Samsungs — the two cube units are the remaining candidates) and one or
two from Bangladesh (likely the CN-firmware SM-G3502s or the YUSUN, but that's a hunch).
Samsung suffixes: `U` US, `M` LATAM, `F`/`B` global. On multi-CSC LATAM firmware the active
CSC follows the last network registered (the cube phones report `GT`/`PY` from travel), so
record purchase country, firmware channel, and CSC as three separate facts — only the
channel is stable and it's what governs behaviour under test.

**Pairs** (identical hardware, useful for holding the device constant): 2× moto g15 (Brazil vs
USA — isolates region), 2× XGODY V40, 2× SM-G3502, 2× Pixel 5a (both on the bench).

**Known faults**

- `17161JECB05989` (Pixel 5a): panel + touch controller fail to probe together at boot, ~2 in 3
  boots. Marginal display flex, not software. Fully documented in bump (`reference_phone_panel_touch_probe_failure`,
  PRs #5028/#5239) with probes and a reboot cron. Repair is a prerequisite for it returning to
  service; the broken-USB 5a is the donor (its panel is presumably fine).
- Broken-USB Pixel 5a: check whether it still charges. No wireless charging on barbet, so a
  fully dead port is unrecoverable; if it charges, Android 11+ wireless debugging could bring
  it back as a cable-less device.
- `0123456789ABCDEF` is a factory placeholder, not an identity. Never attach two placeholder-serial
  devices to one host; anything keyed on serial mis-attributes. Use `adb -s usb:<path>` if it
  ever joins a runner.
- SM-G3502 (API 17) and YUSUN (API 19) predate ISRG Root X1 and (for 4.2) TLS 1.2 by default,
  so they fail against essentially any modern HTTPS endpoint. Rule out transport before
  chasing an "app bug" there.

### Host-side gotcha: adb udev rules

Symptom: phone in `lsusb` and `adb devices` but `no permissions (missing udev rules?)`. On beast
the cause was a hand-written `/etc/udev/rules.d/51-android.rules` with a single `18d1` (Google)
line **shadowing** the packaged `/lib/udev/rules.d/51-android.rules` (132 vendors) — same
filename, `/etc` wins. Fix (applied on beast 2026-08-21):

```bash
sudo mv /etc/udev/rules.d/51-android.rules /etc/udev/rules.d/51-android.rules.disabled
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Pixels keep working (via `uaccess`/logind ACLs). Caveat before repeating on headless runners
(`nas`, cube, silverstone): the packaged rules use `MODE="0660"` + group `plugdev` and `uaccess`
does nothing without a local seat — verify the service account is in `plugdev` first.

### Host-side gotcha: two adb servers race for a phone

Running `adb -P 5038 ...` on a non-SAIR host starts a second adb server and leaves it running.
It can't steal devices 5037 already holds, but it **wins any phone plugged in afterwards**.
Tell: present in `lsusb` with correct permissions, absent from `adb devices` — not even
`unauthorized`. `adb kill-server` makes it worse.

```bash
ss -lntp | grep -E '503[0-9]'   # find stray servers
adb -P 5038 kill-server
adb start-server
```

Only cube and silverstone legitimately run on 5038.
