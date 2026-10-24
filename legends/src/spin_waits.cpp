// spin_waits.cpp - the game's busy-waits on the GPU, made to sleep between checks.

#include <chrono>
#include <thread>

#include <rex/hook.h>

#include "generated/default/rayman_legends_pch.h"

extern "C" void __imp__sub_82A52A50(PPCContext& __restrict ctx, uint8_t* base);

// D3D's wait for the GPU to reach a fence or free ring buffer space: one check (after a few dozen
// db16cyc, the Xenon's "low priority" spin hint), returning 1 while still waiting; the callers
// loop on it. On the 360 that spin shares a core; here it holds a host core at 100% for the
// several milliseconds per frame the command processor needs - heat on a phone for nothing.
REX_HOOK_RAW(sub_82A52A50) {
  __imp__sub_82A52A50(ctx, base);
  if (ctx.r3.u32 != 0) {
    std::this_thread::sleep_for(std::chrono::microseconds(20));
  }
}
