// ios_game.h - the player's game on iOS: finding and checking it, importing it
// from a folder, a ZIP or the disc image (.iso), and the saves beside it
// (ios_game.mm). No UI: the launcher (ios_launcher.mm) runs these and shows the
// outcome.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>

namespace rl {

enum class State { NotFound, WrongVersion, Incomplete, Ready };

struct GameStatus {
    State state = State::NotFound;
    std::string root;     // the folder checked
    std::string missing;  // Incomplete: the files the game needs that are not there
};

struct Progress {
    uint64_t files_done = 0, files_total = 0, bytes_done = 0, bytes_total = 0;
    std::string current;  // the file being copied, or "Checking default.xex"
};
using ProgressFn = std::function<void(const Progress &)>;

enum class ImportResult { Ok, Cancelled, NoGame, WrongVersion, Incomplete, NoSpace, Failed };

// The game in `dir` (default.xex and the files beside it). Hashes default.xex
// the first time; later checks of the same file reuse the cached digest.
GameStatus check_game(const std::string &dir, const ProgressFn &progress = nullptr);

// Copies the game's files from a folder, a ZIP or an Xbox 360 disc image into
// `dest`, checks them, and only then replaces what `dest` held. Blocking: run
// it off the main thread.
enum class Source { Folder, Zip, Iso };
ImportResult import_game(const std::string &source, Source kind, const std::string &dest,
                         const std::atomic<bool> &cancel, const ProgressFn &progress, GameStatus *status,
                         std::string *error);

bool export_saves(const std::string &saves_dir, const std::string &zip_path, std::string *error);
bool import_saves(const std::string &zip_path, const std::string &saves_dir, std::string *error);

std::string human_bytes(uint64_t bytes);

// The release this app is translated from.
inline constexpr const char *kReleaseName = "Xbox 360 (USA, Europe)";

}  // namespace rl
