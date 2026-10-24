// rayman_legends - ReXGlue Recompiled Project
//
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/platform.h>
#include <rex/logging.h>
#include <rex/rex_app.h>
#include <rex/ui/presenter.h>

#include "button_prompts.h"
#include "input_script.h"
#include "widescreen.h"

#if REX_PLATFORM_IOS
#include "ios_launcher.h"
#include "ios_overlay.h"
#endif

#if REX_PLATFORM_IOS
REXCVAR_DECLARE(std::string, log_file);
REXCVAR_DECLARE(std::string, gpu_backend);
REXCVAR_DECLARE(bool, metal4);
REXCVAR_DECLARE(int32_t, video_mode_width);
REXCVAR_DECLARE(int32_t, video_mode_height);
#endif
REXCVAR_DECLARE(bool, mnk_mode);
REXCVAR_DECLARE(bool, present_guest_output_aspect);
REXCVAR_DECLARE(bool, vulkan_allow_present_mode_immediate);
REXCVAR_DECLARE(bool, vulkan_allow_present_mode_mailbox);
REXCVAR_DECLARE(std::string, keybind_a);
REXCVAR_DECLARE(std::string, keybind_b);
REXCVAR_DECLARE(std::string, keybind_x);
REXCVAR_DECLARE(std::string, keybind_y);
REXCVAR_DECLARE(std::string, keybind_left_trigger);
REXCVAR_DECLARE(std::string, keybind_right_trigger);
REXCVAR_DECLARE(std::string, keybind_lstick_up);
REXCVAR_DECLARE(std::string, keybind_lstick_down);
REXCVAR_DECLARE(std::string, keybind_lstick_left);
REXCVAR_DECLARE(std::string, keybind_lstick_right);
REXCVAR_DECLARE(std::string, keybind_rstick_up);
REXCVAR_DECLARE(std::string, keybind_rstick_down);
REXCVAR_DECLARE(std::string, keybind_rstick_left);
REXCVAR_DECLARE(std::string, keybind_rstick_right);
REXCVAR_DECLARE(std::string, keybind_rstick_press);
REXCVAR_DECLARE(std::string, keybind_start);
REXCVAR_DECLARE(std::string, keybind_back);

class RaymanLegendsApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<RaymanLegendsApp>(new RaymanLegendsApp(ctx, "rayman_legends",
        PPCImageConfig));
  }

#if REX_PLATFORM_IOS
  // iOS keeps everything in the app's container (LiveContainer points HOME at
  // the guest app's own data folder): the game the launcher found or imported
  // (Documents/game, or a copy bundled inside the app: the owner's IPA); saves
  // in Documents/Saves, shader caches in Library/Caches.
  void OnConfigurePaths(rex::PathConfig& paths) override {
    const char* home_env = std::getenv("HOME");
    const std::filesystem::path home = home_env ? home_env : ".";
    const std::filesystem::path documents = home / "Documents";
    const std::filesystem::path bundled =
        rex::filesystem::GetExecutableFolder() / "game";
    if (paths.game_data_root.empty()) {
      // The launcher: finds, checks or imports the game, until the player presses Play.
      paths.game_data_root =
          rl_ios_run_launcher(documents.string(),
                              std::filesystem::exists(bundled / "default.xex") ? bundled.string() : "");
    }
    // The game renders at 1280x720 when the video mode is below 1280x720, at 1920x1080 otherwise
    // (sub_8267D070): a 16:9 mode under 720p gives the game's own 720p, less than half the pixels
    // (MetalFX scales it to the screen).
    // The game at the screen's own shape: more of each level, nothing stretched or cut off.
    // (In the game's 720p mode.)
    if (const double aspect = rl_ios_widescreen_aspect()) {
      const RlRenderSize size = RlRenderSizeForAspect(aspect);
      if (size.width) {
        RlSetRenderSize(size);
        REXCVAR_SET(present_guest_output_aspect, true);
      }
    }
    if (rl_ios_widescreen_aspect() || rl_ios_game_rows() == 720) {
      REXCVAR_SET(video_mode_width, 1024);
      REXCVAR_SET(video_mode_height, 576);
    }
    // Native Metal or Vulkan through MoltenVK, as chosen in the settings.
    REXCVAR_SET(gpu_backend, std::string(rl_ios_gpu_backend()));
    REXCVAR_SET(metal4, rl_ios_metal4());
    // PlayStation button prompts for a PlayStation controller (or as chosen in the settings).
    // The Help screen's controller: a DualSense when one is connected, else the Backbone One.
    if (rl_ios_playstation_prompts()) {
      const std::string help_pad = rl_ios_help_pad();
      rl_prompts::UsePlayStationPrompts(
          paths.game_data_root,
          rex::filesystem::GetExecutableFolder() / ("help_pad_" + help_pad + ".tga.ckd"),
          rl_prompts::HelpPadBones(help_pad));
    }
    // The settings panel (L3 + R3, a three-finger tap, Cmd+S), over the game's first frame.
    rl_ios_overlay_start();
    paths.user_data_root = documents / "Saves";
    paths.cache_root = home / "Library" / "Caches" / "rayman_legends";
    paths.config_path = documents / "rayman_legends.toml";
    // The log of the last run, where the Files app can reach it.
    if (REXCVAR_GET(log_file).empty()) {
      std::filesystem::create_directories(documents / "Logs");
      REXCVAR_SET(log_file, (documents / "Logs" / "rayman_legends.log").string());
    }
  }

  // No ImGui overlays on iOS (the Liquid Glass panel replaces them): a registered
  // ImGui dialog keeps the presenter repainting at the display's rate even
  // without a new game frame, for nothing but GPU time and heat.
  std::unique_ptr<rex::ui::AchievementNotificationDialog> CreateAchievementNotificationDialog()
      override {
    return nullptr;
  }
  std::unique_ptr<rex::ui::ImGuiDialog> CreateAchievementsOverlay() override { return nullptr; }
#endif

#if !REX_PLATFORM_IOS
  // Development: RL_PS_PROMPTS=1 shows the PlayStation button prompts (RL_HELP_PAD=dualsense for the
  // DualSense Help screen controller, the Backbone One's otherwise); RL_ASPECT=<w/h> renders the game at
  // that shape (with --video_mode_width=1024 --video_mode_height=576, its 720p mode).
  void OnConfigurePaths(rex::PathConfig& paths) override {
    if (const char* aspect = std::getenv("RL_ASPECT")) {
      const RlRenderSize size = RlRenderSizeForAspect(std::atof(aspect));
      RlSetRenderSize(size);
      REXCVAR_SET(present_guest_output_aspect, true);
    }
    // Presents in step with the display: the Mac's default modes paint far faster than the game draws.
    REXCVAR_SET(vulkan_allow_present_mode_immediate, false);
    REXCVAR_SET(vulkan_allow_present_mode_mailbox, false);
    if (std::getenv("RL_PS_PROMPTS") && !paths.game_data_root.empty()) {
      const char* help_pad_env = std::getenv("RL_HELP_PAD");
      const std::string help_pad = help_pad_env ? help_pad_env : "backbone";
      rl_prompts::UsePlayStationPrompts(
          paths.game_data_root,
          rex::filesystem::GetExecutableFolder() / ("help_pad_" + help_pad + ".tga.ckd"),
          rl_prompts::HelpPadBones(help_pad));
    }
  }
#endif

  // The Xbox 360 GPU (Xenos) emulation, unless --gpu_plugin names another.
  void OnPreSetup(rex::RuntimeConfig& config) override {
    if (config.gpu_plugin.empty()) {
      config.gpu_plugin = "xenos";
    }
    // The game's screen-space passes (post effects, D3D clears) draw unclipped with D3D9's 8192
    // scissor: without running their vertex shaders on the CPU, every one of them is assumed to
    // cover the EDRAM to the end, and render target ownership transfers copy all of it around
    // (twice as many transfers, a 48 -> 60 fps difference on an M3 in a level). The cvar lives in
    // the GPU plugin, loaded later: its environment variable is read when it registers.
    setenv("REX_EXECUTE_UNCLIPPED_DRAW_VS_ON_CPU", "true", 0);
    // A frame drawn while a new effect's shaders are still compiling is shown (the effect missing for a frame or
    // two), not dropped: a dropped frame holds the previous one on screen, a visible hitch.
    setenv("REX_VULKAN_ASYNC_SKIP_INCOMPLETE_FRAMES", "false", 0);
    // A keyboard (a Mac's, an iPad's Magic Keyboard) plays as a controller, laid
    // out for a platformer: WASD or the arrows move, Space jumps, J attacks, E runs.
    REXCVAR_SET(mnk_mode, true);
    REXCVAR_SET(keybind_a, std::string("Space,K"));
    REXCVAR_SET(keybind_x, std::string("J"));
    REXCVAR_SET(keybind_b, std::string("L,Backspace"));
    REXCVAR_SET(keybind_y, std::string("I"));
    REXCVAR_SET(keybind_right_trigger, std::string("E,U"));
    REXCVAR_SET(keybind_left_trigger, std::string("Q"));
    REXCVAR_SET(keybind_lstick_up, std::string("W,Up"));
    REXCVAR_SET(keybind_lstick_down, std::string("S,Down"));
    REXCVAR_SET(keybind_lstick_left, std::string("A,Left"));
    REXCVAR_SET(keybind_lstick_right, std::string("D,Right"));
    for (std::string* unused : {&REXCVAR_GET(keybind_rstick_up), &REXCVAR_GET(keybind_rstick_down),
                                &REXCVAR_GET(keybind_rstick_left), &REXCVAR_GET(keybind_rstick_right),
                                &REXCVAR_GET(keybind_rstick_press)}) {
      unused->clear();  // the arrows move Rayman instead
    }
    REXCVAR_SET(keybind_start, std::string("Return"));
    REXCVAR_SET(keybind_back, std::string("Tab"));
#if !REX_PLATFORM_IOS
    // The game's frame rate in the log every 5 s (iOS: the overlay does this).
    rex::ui::SetGuestOutputFrameObserver([] {
      using clock = std::chrono::steady_clock;
      static clock::time_point window_start = clock::now();
      static uint32_t frames = 0;
      static uint64_t presented_start = rex::ui::GetPresentedFrameCount();
      ++frames;
      const double seconds = std::chrono::duration<double>(clock::now() - window_start).count();
      if (seconds >= 5.0) {
        const uint64_t presented = rex::ui::GetPresentedFrameCount();
        REXLOG_INFO("[perf] {:.1f} fps shown ({:.1f} by the game)",
                    (presented - presented_start) / seconds, frames / seconds);
        frames = 0;
        presented_start = presented;
        window_start = clock::now();
      }
    });
#endif
  }

  // Development: scripted key presses (RL_INPUT_SCRIPT), once the game runs.
  void OnPostSetup() override { RlStartInputScript(); }

  // Override virtual hooks for customization:
  // void OnPostInitLogging() override {}
  // void OnLoadXexImage(std::string& xex_image) override {}
  // void OnPostLoadXexImage() override {}
  // void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {}
  // void OnShutdown() override {}
};
