# Rayman Legends iOS

*Rayman Legends* (Xbox 360, 2013) running natively on iPhone and iPad as statically recompiled ARM64 code. No
emulator and no JIT, so it plays under LiveContainer or SideStore.

The game's PowerPC code is translated ahead of time with the [**ReXGlue SDK**](https://github.com/rexglue/rexglue-sdk)
(Xenia-based Xbox 360 recompilation). This repository is the iOS port on top of it: the app, the launcher and
settings, the controller support, and a native **Metal 4** GPU backend for the SDK (the SDK's Vulkan path through
MoltenVK stays as a fallback).

**[Download the latest release](https://github.com/EhsanWaheed/rayman-legends-ios/releases/latest)**
(`RaymanLegendsIOS-NGF.ipa`, version 0.19). The IPA contains **no game files**: you add your own copy of the game.

Fan project, not affiliated with or endorsed by Ubisoft or Microsoft.

## Features

- **Native, no JIT.** The whole game runs as statically recompiled ARM64 code.
- **Native Metal renderer.** The Xbox 360 GPU (Xenos) emulated on Metal 4 (argument tables, residency sets,
  explicit barriers), Metal 3 where Metal 4 isn't available. 60 fps through levels on an iPhone 17 Pro Max at a
  nominal thermal state. Metal 4, Metal 3 or Vulkan (MoltenVK) can be picked in the settings.
- **Widescreen.** The game drawn at the screen's own shape (more of each level, the HUD in its corners), or 16:9
  fitted, filled or stretched.
- **MetalFX upscaling** from the game's 720p to the screen.
- **Low power mode** for phones without a vapor chamber: lighter output settings to keep the phone cool.
- **Controllers.** Backbone One (PlayStation Edition too), DualSense, DualShock 4, Xbox and other MFi
  controllers, hot-plugged. With a PlayStation-style pad the game shows PlayStation button prompts everywhere,
  and the pause menu's **Help** screen shows the controller you hold: a Backbone One, or a DualSense when one is
  connected.
- **Liquid Glass launcher** with your box art: Play, import the game from a folder, a ZIP or the disc image
  (checked before it is used), export and import saves.
- **Settings panel** over the game: **L3 + R3**, a three-finger tap, or **Cmd+S**. Display, renderer, upscaler,
  low power, controller and prompts. The game pauses while it is open.

## What you need

- An iPhone or iPad on **iOS 17 or later** (Metal 4 needs iOS 26 and an A14 or later), with
  [LiveContainer](https://github.com/LiveContainer/LiveContainer) or SideStore.
- **Your own dump of the Xbox 360 game** (Redump: *Rayman Legends (USA, Europe)*): the disc image (`.iso`), or its
  files (the folder with `default.xex` and the `.ipk` bundles).

## Install

1. Install `RaymanLegendsIOS-NGF.ipa` from
   [Releases](https://github.com/EhsanWaheed/rayman-legends-ios/releases/latest) with LiveContainer or SideStore,
   and open it once so its Documents folder exists.
2. Open the app and import the game from the launcher: pick the game's folder, a ZIP of it, or the `.iso`. Or copy the game's files
   into a folder named **`game`** in the app's **Documents** folder yourself (Files app, or Finder with the device
   plugged in).
3. The launcher checks the game once and shows **Ready to play**.

## Building

The game's recompiled code is generated from your own `default.xex`, so it isn't in this repository.

```bash
git clone --recursive https://github.com/EhsanWaheed/rayman-legends-ios.git
cd rayman-legends-ios
git -C rexglue-sdk apply ../patches/rexglue-sdk-ios.patch
git -C rexglue-sdk/thirdparty/moltenvk apply ../../../patches/moltenvk-ios.patch
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

The app is signed ad hoc; LiveContainer or SideStore re-sign it. Optional, kept out of git: `legends/ios/LauncherArt.png`
(your box art, also made into the app icon) and the Help screen's controllers in `legends/art`
(`tools/make_pad_art.py` paints them over the game's own atlas, `tools/x360tex.py` encodes them).

`docs/metal-backend.md` describes the Metal backend.

## Credits

- [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk) and [Xenia](https://github.com/xenia-project/xenia), whose
  GPU emulation the Metal backend follows.
- [metal-cpp](https://developer.apple.com/metal/cpp/), [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross),
  [MoltenVK](https://github.com/KhronosGroup/MoltenVK).
