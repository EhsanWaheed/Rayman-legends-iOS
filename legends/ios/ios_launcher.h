// ios_launcher.h - the iOS launcher (ios_launcher.mm): finds, checks and imports the player's game before the
// game's own window exists.
#pragma once

#include <string>

// Shows the launcher and turns the run loop until the player presses Play; returns the folder of the checked game
// (Documents/game, or the copy bundled in the app). Quitting from the launcher ends the app. Main thread only.
std::string rl_ios_run_launcher(const std::string &documents, const std::string &bundled_game);

// The connected controller's family: 1 PlayStation, 2 any other, 0 none.
int rl_pad_family(void);
