// ios_overlay.h - the iOS settings panel over the game, the controller bubble and the frame-rate pill
// (ios_overlay.mm).
#pragma once

// Starts watching the game's frames: the first one installs the panel over the game's window; while the panel is
// open the game is held at its next frame (paused). Call once, before the game starts.
void rl_ios_overlay_start(void);

// The resolution the game renders at this launch, from the settings (720 or 1080): the game picks 720p when the
// video mode is below 1280x720, 1080p otherwise. Call once, before the game starts.
int rl_ios_game_rows(void);

// The Help screen's controller art: "dualsense" with a DualSense connected, "backbone" otherwise.
const char *rl_ios_help_pad(void);

// Metal 4 command queues where supported, or Metal 3 only, from the settings.
bool rl_ios_metal4(void);

// The screen's aspect ratio (long side / short side) when the game is to be drawn at the screen's own shape
// (Native widescreen in the settings), 0 for the game's 16:9.
double rl_ios_widescreen_aspect(void);

// The controller bubble ("DualSense · Connected") shows over this window from now on (the launcher's, then the
// game's).
void rl_bubble_attach(void *uiwindow);
