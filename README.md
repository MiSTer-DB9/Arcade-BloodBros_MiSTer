# Arcade-BloodBros_MiSTer

FPGA core for **Blood Bros** (TAD Corporation, 1990) targeting the
[MiSTer FPGA](https://github.com/MiSTer-devel) platform (Terasic DE10-Nano).

Blood Bros is a **shooting gallery** game (Cabal-style) running on
**Seibu hardware** (D-Con board family).

## Status

**Current version: 1.1** (June 2026).

The core runs the full game with audio and inputs.

**Features**
- M68000 main CPU @ 10 MHz (FX68K cycle-accurate)
- Z80 sound CPU @ 3.579545 MHz (T80s)
- YM3812 OPL2 FM (jtopl2) + OKI M6295 ADPCM (jt6295) with MAME-accurate mixer
- 256×224 active video area
- BG / FG tilemaps (16×16, 4bpp, 32×16 tilemap, shared ROM)
- Text layer (8×8, 4bpp, 32×32 tilemap)
- 16×16 sprites with priority callback (Seibu SEI0210)
- Seibu CRTC registers (scroll, layer enable, flip screen)
- **Hardware-accurate DIP switches**: Coin Mode, Coinage, Starting Coin, Lives,
  Bonus Life, Difficulty, Allow Continue, Demo Sounds
- **Analog VGA H-Shift / V-Shift** OSD options for fine alignment on 15 kHz CRTs
- MiSTer OSD with audio mixer (FM/OKI volume), per-layer debug toggles
- Pause overlay with logo + supporters scroll

**ROM sets supported**
- Blood Bros (`bloodbro`, World)
- Blood Bros (`bloodbroj`, Japan rev A)
- Blood Bros (`bloodbroja`, Japan)
- Blood Bros (`bloodbrou`, US — Fabtek license)
- Blood Bros (`bloodbrok`, Korea)

## Screenshots

| | |
|---|---|
| ![Title](docs/title.png) | ![TAD Corporation](docs/tad_corporation.png) |
| Title screen | TAD Corporation / Fabtek |
| ![Stage select](docs/stage_select.png) | ![High scores](docs/high_scores.png) |
| Stage select | High scores |
| ![Gameplay river](docs/gameplay_river.png) | ![Gameplay town](docs/gameplay_town.png) |
| Gameplay — river stage | Gameplay — town stage |

## Hardware emulated

| Component        | Spec                                                |
|------------------|-----------------------------------------------------|
| Master clock     | 20 MHz crystal (main) + 14.31818 MHz (sound)        |
| Main CPU         | M68000 @ 10 MHz                                     |
| Sound CPU        | Z80 @ 3.579545 MHz                                  |
| Sound chip 1     | Yamaha YM3812 OPL2 (jtopl2)                         |
| Sound chip 2     | OKI M6295 (jt6295) ADPCM, pin7=LOW, 1.32 MHz        |
| Video resolution | 256×224 active                                      |
| Refresh rate     | ~59.4 Hz                                            |
| BG layer         | 16×16 4bpp, 32×16 tilemap, scroll X/Y               |
| FG layer         | 16×16 4bpp, 32×16 tilemap, scroll X/Y               |
| Text layer       | 8×8 4bpp, 32×32 tilemap                             |
| Sprites          | 16×16 4bpp, priority (Seibu SEI0210, 512 entries)   |
| Palette          | xBGR_555, 2048 entries                              |
| Custom video CRTC| Seibu CRTC                                          |
| Sprite chip      | Seibu SEI0210                                       |

## Hardware requirements

- Terasic DE10-Nano
- MiSTer I/O board (recommended)
- Works on HDMI displays and on 15 kHz CRTs via the analog video output

## Building from source

Requires Quartus Prime 17.0 (free Lite Edition).

```
Open BloodBros.qpf in Quartus → Processing → Start Compilation
```

Output bitstream is generated in `output_files/BloodBros.rbf` (~3.5 MB).

## Running on MiSTer

The [releases/](releases/) folder contains the parent MRA and a
prebuilt RBF; regional clone MRAs are in
[releases/alternatives/](releases/alternatives/):

- `Blood Bros (World).mra` — parent MRA
- `BloodBros_YYYYMMDD.rbf` — prebuilt bitstream
- `alternatives/Blood Bros (Japan rev A).mra` / `(Japan).mra` / `(US).mra` / `(Korea).mra` — regional clones

Steps:

1. Copy the `.rbf` to `_Arcade/cores/` on the MiSTer SD card (rename to
   `BloodBros.rbf` or keep the dated name and update the MRA accordingly).
2. Copy the `.mra` file(s) to `_Arcade/` on the MiSTer SD card.
3. Provide your legally-owned `bloodbro.zip` (or regional variant) where
   the MRA expects it (usually in `games/mame/`).

**ROMs are NOT included in this repository.** You must provide them yourself.

## Repository layout

```
Arcade-BloodBros_MiSTer/
├── rtl/
│   ├── BloodBros/    Blood Bros-specific core RTL
│   ├── pll/          Clock PLL
│   ├── sound/        Sound chip cores (jtopl, jt6295, t80)
│   ├── fx68k/        FX68K M68000 cycle-accurate core
│   ├── jtframe/      JTFRAME framework modules
│   └── sdram.sv      SDRAM controller (Sorgelig)
├── sys/              MiSTer framework (Sorgelig / MiSTer-devel)
├── logo/             Pause overlay assets (font, logo, supporter list)
├── docs/             In-game screenshots
├── releases/         Parent MRA + regional clones + prebuilt RBF
├── BloodBros.qpf     Quartus project
├── BloodBros.qsf     Quartus assignments
├── BloodBros.sv      Top-level wrapper
├── Template.sdc      Timing constraints
├── files.qip         HDL file list
├── build_id.v        Build version stamp
└── README.md         This file
```

## Acknowledgements

- **Jose Tejada** ([@jotego](https://github.com/jotego)) for JTOPL (YM3812),
  JT6295 (OKI M6295) and the JTFRAME framework.
- **Daniel Wallner** and **MikeJ** for the T80 (Z80) core.
- **Jorge Cwik** ([ijor](https://github.com/ijor)) for the **FX68K** cycle-accurate
  M68000 core.
- **Sorgelig** and the **MiSTer-devel team** for the framework, SDRAM
  controller and Template.

## Support this project

If you enjoy this core and want to support its development:

- [Ko-fi](https://ko-fi.com/ibecerivideoludici) — one-time support
- [Patreon](https://www.patreon.com/IBeceriVideoludici) — monthly support
- [PayPal](https://www.paypal.me/IBeceriVideoludici) — one-time donation

## Follow

- [GitHub](https://github.com/rmonic79)
- [Twitch](https://twitch.tv/ibecerivideoludici) — live streams
- [YouTube](https://www.youtube.com/c/IBeceriVideoludici) — playlists and videos
- [X / Twitter](https://x.com/rmonic79)

## License

The RTL source code in this repository is provided as-is for educational
and preservation purposes under **GNU GPL v3 or later**. Original ROM data
is not included; users must provide their own legally obtained copies.

Original *Blood Bros* arcade hardware © TAD Corporation, 1990.
