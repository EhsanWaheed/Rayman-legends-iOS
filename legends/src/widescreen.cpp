// widescreen.cpp - the game's render size at the screen's own shape (widescreen.h).

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

#include <rex/hook.h>

#include "generated/default/rayman_legends_pch.h"
#include "widescreen.h"

extern "C" void __imp__sub_82807EB0(PPCContext& __restrict ctx, uint8_t* base);

namespace {
RlRenderSize g_size;
// The UI's reference size: two floats (1280, 720) that the UI scale functions (sub_82810F68, sub_82811030)
// compare with the render size; UI anchored right or centred is placed in it.
constexpr uint32_t kUiReferenceSize = 0x82E53370;
}  // namespace

RlRenderSize RlRenderSizeForAspect(double aspect) {
  // Within 1% of 16:9 the game's own size serves.
  if (std::fabs(aspect - 16.0 / 9.0) < 16.0 / 9.0 * 0.01) {
    return {};
  }
  // The widest the post effects take that isn't wider than the screen: the HUD sits at the picture's edges, so a
  // wider picture would have it cropped (the Lums counter at the top right). A few percent of the screen is
  // left at the sides (under the rounded corners and the island) or filled by the chosen picture mode.
  const double ideal = 720.0 * aspect;
  const uint32_t width = std::max(uint32_t(ideal / 240.0 + 1e-6) * 240, 240u);
  return {width, 720, width};
}

void RlSetRenderSize(RlRenderSize size) {
  g_size = size;
}

// The game's resolution setter (r4 width, r5 height), called by its display setup (sub_8267D070) with
// 1280x720 for a video mode under 720p: replaced by the chosen size, with the UI's reference size the same (at
// the same height its scale stays 1; menus centred, the HUD at the edges).
REX_HOOK_RAW(sub_82807EB0) {
  if (g_size.width && ctx.r5.u32 == 720) {
    ctx.r4.u64 = g_size.width;
    ctx.r5.u64 = g_size.height;
    const float reference[2] = {float(g_size.visible_width), 720.0f};
    for (int i = 0; i < 2; ++i) {
      uint32_t bits;
      std::memcpy(&bits, &reference[i], 4);
      REX_STORE_U32(kUiReferenceSize + 4 * i, bits);
    }
  }
  __imp__sub_82807EB0(ctx, base);
}
