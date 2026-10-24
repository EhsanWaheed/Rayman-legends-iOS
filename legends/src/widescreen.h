// widescreen.h - the game's render size at the screen's own shape (widescreen.cpp).
//
// The 360 game renders 16:9 (1280x720 or 1920x1080) and lays out its menus and HUD in a 1280x720 space.
// Given another size, it renders that instead and its UI space takes the same shape (anchored to the real
// edges): on a 19.5:9 phone more of each level at the sides, on a 4:3 iPad more above and below, nothing
// stretched or cut off. Before the game starts.
//
// The size has to suit the game's post effects, which work at a third of it in whole EDRAM tiles (80 pixels
// wide): widths in multiples of 240, or those buffers have unfilled strips (garbage at the edge of the picture,
// a band through the pause menu's blurred background).
#pragma once

#include <cstdint>

struct RlRenderSize {
  uint32_t width = 0, height = 0;  // 0: the game's own 16:9
  uint32_t visible_width = 0;      // the UI's reference width (the render width)
};

// The size for a screen of this aspect ratio (width / height): 720 rows (the UI's own height: at any other its
// menus come apart), the width the screen's shape rounded down to the post effects' granularity (never wider
// than the screen, so the HUD at the edges is never cut off).
RlRenderSize RlRenderSizeForAspect(double aspect);

void RlSetRenderSize(RlRenderSize size);
