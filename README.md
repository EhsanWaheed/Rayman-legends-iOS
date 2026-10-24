# Rayman Legends iOS

*Rayman Legends* (Xbox 360, 2013) running natively on iPhone and iPad as statically recompiled ARM64 code. No
emulator and no JIT, so it plays under LiveContainer or SideStore.

The game's PowerPC code is translated ahead of time with the [**ReXGlue SDK**](https://github.com/rexglue/rexglue-sdk)
(Xenia-based Xbox 360 recompilation). This repository is the iOS port on top of it: the app, the launcher and
settings, the controller support, and a native **Metal 4** GPU backend for the SDK (Metal 3 where Metal 4 isn't
available). No Vulkan or MoltenVK.

**[Download the latest release](https://github.com/EhsanWaheed/Rayman-legends-iOS/releases/latest)**
(`RaymanLegendsIOS-NGF.ipa`, version 0.20). The IPA contains **no game files**: you add your own copy of the game.

Fan project, not affiliated with or endorsed by Ubisoft or Microsoft.

## Features

- **Native, no JIT.** The whole game runs as statically recompiled ARM64 code.
- **Native Metal renderer.** The Xbox 360 GPU (Xenos) emulated on Metal 4 (argument tables, residency sets,
  explicit barriers), Metal 3 where Metal 4 isn't available (or picked in the settings). 60 fps through levels on
  an iPhone 17 Pro Max at a nominal thermal state.
- **Widescreen.** The game drawn at the screen's own shape (more of each level, the HUD in its corners), or 16:9
  fitted, filled or stretched.
- **MetalFX upscaling** from the game's 720p to the screen.
- **Low power mode** for phones without a vapor chamber: the game at 16:9 (1280x720) instead of the screen's
  shape, shown at 720p without MetalFX, to keep the phone cool.
- **Controllers.** Backbone One (PlayStation Edition too), DualSense, DualShock 4, Xbox and other MFi
  controllers, hot-plugged. The game shows PlayStation button prompts everywhere, and the pause menu's **Help**
  screen shows a Backbone One, or a DualSense when one is connected.
- **Liquid Glass launcher** with your box art: Play, import the game from a folder, a ZIP or the disc image
  (checked before it is used), export and import saves.
- **Settings panel** over the game: **L3 + R3**, a three-finger tap, or **Cmd+S**. Display, renderer, upscaler,
  low power, controller and prompts. The game pauses while it is open.

## What you need

- An iPhone or iPad on **iOS 17 or later** (Metal 4 needs iOS 26 and an A14 or later), with
  [LiveContainer](https://github.com/LiveContainer/LiveContainer) or SideStore.
- **Your own dump of the Xbox 360 game**, the Redump release *Rayman Legends (USA, Europe)*. The app checks its
  `default.xex` and turns away other versions.

From the disc, you need **all** of its files (about 6.4 GB):

| Copy this | |
|---|---|
| `default.xex` | the game itself |
| every `.ipk` file (`Bundle_X360.ipk`, `fullLogic_X360.ipk`, the levels' bundles…) | the game's data |
| `EngineData`, `UplayMedia` and the other files beside them | the rest of the disc |

Have the disc image (`.iso`) instead? The app can import that directly (see below), or extract it on a computer
with `tools/extract_xiso.py`.

## Install

1. Install `RaymanLegendsIOS-NGF.ipa` from
   [Releases](https://github.com/EhsanWaheed/Rayman-legends-iOS/releases/latest) with LiveContainer or SideStore,
   and open it once so its Documents folder exists.
2. Put the disc's files in a folder named exactly **`game`**, so you have `game/default.xex`,
   `game/Bundle_X360.ipk` and so on.
3. Copy that **`game`** folder into the app's **Documents** folder (Files app, or Finder with the device plugged in):
   - **LiveContainer**: Files → On My iPhone → **LiveContainer** → `Data` → `Application` → the app's data folder
     (its name is shown in LiveContainer's settings for the app) → **`Documents`** → put `game` there.
   - **SideStore** (installed as a normal app): Files → On My iPhone → **Rayman Legends** → put `game` there.
4. Open the app: the launcher checks the game once (a few seconds) and shows **Ready to play**.

Prefer not to copy files by hand? Open the app without a `game` folder and use **Import game folder…**,
**Import game ZIP…** or **Import disc image (.iso)…**: pick it wherever it is (Files, iCloud Drive) and the
launcher copies the game into `Documents/game`.

Updating: install the new IPA over the old one; your game and saves stay. Saves can also be exported and imported
from the launcher.

## Building

The game's recompiled code is generated from your own `default.xex`, so it isn't in this repository.

```bash
git clone --recursive https://github.com/EhsanWaheed/Rayman-legends-iOS.git
cd Rayman-legends-iOS
git -C rexglue-sdk apply ../patches/rexglue-sdk-ios.patch
```

1. Extract the game next to the project: `python3 tools/extract_xiso.py <game.iso> game`.
2. Build and install the SDK for the Mac (`cmake --preset mac-arm64` in `rexglue-sdk`, then install it to
   `sdk-mac`): the iOS build runs its `rexglue` tool.
3. Generate the recompiled code: `sdk-mac/bin/rexglue codegen rayman_legends_manifest.toml` in `legends`.
4. Configure and build the app (it builds the SDK for iOS from `rexglue-sdk`):

```bash
cmake -S legends -B legends/out/build/ios -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release
cmake --build legends/out/build/ios
```

The app is signed ad hoc; LiveContainer or SideStore re-sign it. `legends/ios/LauncherArt.png` is the launcher's
cover (also made into the app icon). The pause menu Help screen's controllers are in `legends/art`:
`tools/make_pad_art.py` paints them (the Backbone One from `art/backbone_one_source.webp`, the DualSense drawn)
over the game's own atlas, and `tools/x360tex.py` encodes them.

`docs/metal-backend.md` describes the Metal backend.

## Credits

- [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk) and [Xenia](https://github.com/xenia-project/xenia), whose
  GPU emulation the Metal backend follows.
- [metal-cpp](https://developer.apple.com/metal/cpp/), [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)
  (fetched at configure time), [glslang](https://github.com/KhronosGroup/glslang).
