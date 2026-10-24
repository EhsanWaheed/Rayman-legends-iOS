// input_script.h - development: key presses at set times, for driving the game without hands (benchmarks,
// screenshots in the iOS Simulator). RL_INPUT_SCRIPT="5:Space,8:Return,9.5:Down" presses each key for 0.12 s at
// that many seconds after the game started, through the same SDL key events a keyboard sends (the keyboard
// controller driver turns them into pad input). "hold" steps keep a key down: "12:Right:4" holds Right for 4 s.
#pragma once

#include <chrono>
#include <cstdlib>
#include <sstream>
#include <string>
#include <thread>

#include <SDL3/SDL.h>

inline void RlStartInputScript() {
  const char* script = std::getenv("RL_INPUT_SCRIPT");
  if (!script || !*script) {
    return;
  }
  std::thread([text = std::string(script)] {
    const auto start = std::chrono::steady_clock::now();
    std::stringstream steps(text);
    std::string step;
    while (std::getline(steps, step, ',')) {
      const size_t colon = step.find(':');
      if (colon == std::string::npos) {
        continue;
      }
      const double at = std::atof(step.substr(0, colon).c_str());
      std::string key = step.substr(colon + 1);
      double hold = 0.12;
      if (const size_t colon2 = key.find(':'); colon2 != std::string::npos) {
        hold = std::atof(key.substr(colon2 + 1).c_str());
        key = key.substr(0, colon2);
      }
      std::this_thread::sleep_until(start + std::chrono::duration<double>(at));
      const SDL_Scancode scancode = SDL_GetScancodeFromName(key.c_str());
      int count = 0;
      SDL_Window** windows = SDL_GetWindows(&count);
      const SDL_WindowID window_id = windows && count ? SDL_GetWindowID(windows[0]) : 0;
      SDL_free(windows);
      SDL_Event event{};
      event.key.windowID = window_id;
      event.key.scancode = scancode;
      event.key.down = true;
      event.type = SDL_EVENT_KEY_DOWN;
      SDL_PushEvent(&event);
      std::this_thread::sleep_for(std::chrono::duration<double>(hold));
      event.key.down = false;
      event.type = SDL_EVENT_KEY_UP;
      SDL_PushEvent(&event);
    }
  }).detach();
}
