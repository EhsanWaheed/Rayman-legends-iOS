// button_prompts.h - the game's button prompts in PlayStation glyphs, for a PlayStation controller.
//
// The Xbox 360 game data carries the PS3 version's button art too (UbiArt bundles are shared between
// platforms): ui/trc/buttonsps3/textures/ps3buttons.tga.ckd beside ui/trc/buttons360/textures/
// x360buttons.tga.ckd, the same 512x512 atlas laid out the same way (the two button templates differ
// only in the texture's path). Each bundle (.ipk) that has both gets its file table's entry for the
// Xbox atlas pointed at the PS3 one's data, as the game reads it (the files on disk stay as they are):
// every prompt, in menus, in levels and in text, then shows cross / circle / square / triangle.
#pragma once

#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <rex/filesystem/devices/host_path_file.h>
#include <rex/logging.h>

namespace rl_prompts {

// <Xbox entry, PlayStation entry>, as paths' endings in the bundles' file tables.
inline const std::pair<const char*, const char*> kSwaps[] = {
    {"ui/trc/buttons360/textures/x360buttons.tga.ckd", "ui/trc/buttonsps3/textures/ps3buttons.tga.ckd"},
    // The animated button prompts ("Hold LB or RB" bubbles).
    {"ui/buttons/animation/buttons_pack_xbox_001_0.tga.ckd",
     "ui/buttons/animation/buttons_pack_ps3_001_0.tga.ckd"},
    {"ui/buttons/animation/buttons_pack_xbox_001.pbk.ckd", "ui/buttons/animation/buttons_pack_ps3_001.pbk.ckd"},
};

// The pause menu's Help screen (controllerguidexbox) paints the Xbox 360 pad from this atlas, cut by the Xbox
// layout: replaced with ours (tools/make_pad_art.py: the same pieces in the same places, a Backbone One or a
// DualSense), or without ours, the PS3 painting (whose left stick is elsewhere: the Help screen misses it).
inline const char kHelpPadAtlas[] = "ui/classicpadtutoxbox/animation/classicpadtutoxbox_a1.tga.ckd";
inline const char kHelpPadAtlasPs3[] = "ui/classicpadtutops3/animation/classicpadtutops3_a1.tga.ckd";
// Its skeleton (stored uncompressed): bones of 0x28 bytes from 0x282, each starting with its position.
inline const char kHelpPadSkeleton[] = "ui/controllerguidexbox/animation/controllerguidexbox_squeleton.skl.ckd";
constexpr uint64_t kSkeletonBones = 0x282;
constexpr uint64_t kSkeletonBoneStride = 0x28;
// A change to a bone's record: delta added to the float at byte offset field.
struct BoneMove {
  uint32_t bone;
  int32_t field;
  float delta;
};

// Besides those, every Xbox actor with a PS3 twin (the tutorials' prompts: "amrotatewheel_xbox.act" and
// "amrotatewheel_ps3.act", the animated controller "classicpadtutoxbox" and "classicpadtutops3"): the twin's
// path is the Xbox one with these replaced.
// The Help screen's bones for a pad's art (tools/make_pad_art.py), the rest as on the Xbox pad. Bone 2 is the
// left stick, 16 the Move line (from the stick to its label); fields 0 and 4 their position (0 up, 139 atlas
// pixels per unit; 4 right, 50.6 per unit), 8 the angle, 16 the length.
inline std::vector<BoneMove> HelpPadBones(const std::string& pad) {
  if (pad == "dualsense") {
    // The DualSense's left stick at (136, 155) of the atlas, the Xbox pad's at (80, 113); the Move line from
    // there back to its label: 17.8 degrees steeper, 1.83 times as long.
    const float up = -42.5f / 139.0f, right = 56.2f / 50.6f;
    return {{2, 0, up}, {2, 4, right}, {16, 0, up}, {16, 4, right}, {16, 8, -0.311f}, {16, 16, 0.824f}};
  }
  return {};
}

inline std::string PlayStationTwin(const std::string& path) {
  std::string twin = path;
  auto replace_all = [&](const char* from, const char* to) {
    for (size_t at = twin.find(from); at != std::string::npos; at = twin.find(from, at + std::strlen(to))) {
      twin.replace(at, std::strlen(from), to);
    }
  };
  replace_all("classicpadtutoxbox", "classicpadtutops3");
  replace_all("_xbox", "_ps3");
  return twin;
}

struct Entry {
  std::string path;
  uint64_t record;  // file offset of the entry's size field
  uint8_t fields[24];  // size, compressed size, timestamp, offset (big endian), as stored
};

inline uint32_t be32(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}

inline void put_be(uint8_t* p, uint64_t value, int bytes) {
  for (int i = bytes - 1; i >= 0; --i, value >>= 8) {
    p[i] = uint8_t(value);
  }
}

inline std::vector<uint8_t> ReadWholeFile(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

// The file table of a UbiArt bundle (version 5, big endian): a 0x30-byte header (magic 0x50EC12BA,
// file count at 0x10), then per file: the number of offsets, size, compressed size, timestamp, the
// offsets (64-bit), the directory and the name (each a 32-bit length and the characters), a checksum
// and flags.
inline std::vector<Entry> ReadTable(const std::filesystem::path& ipk) {
  std::vector<Entry> entries;
  std::ifstream in(ipk, std::ios::binary);
  uint8_t header[0x30];
  if (!in.read(reinterpret_cast<char*>(header), sizeof(header)) || be32(header) != 0x50EC12BA) {
    return entries;
  }
  const uint32_t count = be32(header + 0x10);
  std::vector<uint8_t> table(std::min<uint64_t>(be32(header + 0x0C), 64u << 20));
  in.seekg(0);
  in.read(reinterpret_cast<char*>(table.data()), table.size());
  table.resize(size_t(in.gcount()));
  size_t o = 0x30;
  auto need = [&](size_t n) { return o + n <= table.size(); };
  for (uint32_t i = 0; i < count; ++i) {
    if (!need(4)) break;
    const uint32_t offsets = be32(&table[o]);
    if (offsets != 1 || !need(4 + 24 + 4)) break;  // one copy of each file in these bundles
    Entry e;
    e.record = o + 4;
    std::memcpy(e.fields, &table[o + 4], sizeof(e.fields));
    o += 4 + sizeof(e.fields);
    for (int part = 0; part < 2; ++part) {
      if (!need(4)) return {};
      const uint32_t length = be32(&table[o]);
      o += 4;
      if (!need(length)) return {};
      e.path.append(reinterpret_cast<const char*>(&table[o]), length);
      o += length;
    }
    o += 8;  // checksum, flags
    entries.push_back(std::move(e));
  }
  return entries;
}

inline bool EndsWith(const std::string& s, const char* suffix) {
  const size_t n = std::strlen(suffix);
  return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

// Points the Xbox button art at the PlayStation one in every bundle of the game that has both. help_pad: our
// Help screen controller (a .tga.ckd at the atlas's size and format), or empty.
inline void UsePlayStationPrompts(const std::filesystem::path& game_root,
                                  const std::filesystem::path& help_pad = {},
                                  const std::vector<BoneMove>& bone_moves = {}) {
  // Shared by every bundle that has the atlas (each level's does).
  std::shared_ptr<const std::vector<uint8_t>> help_pad_data;
  if (!help_pad.empty()) {
    auto data = std::make_shared<std::vector<uint8_t>>(ReadWholeFile(help_pad));
    if (data->size() >= 0x68 && std::memcmp(data->data() + 4, "TEX", 3) == 0) {
      help_pad_data = std::move(data);
    } else {
      REXLOG_WARN("Button prompts: no Help screen controller at {}", help_pad.string());
    }
  }
  int help_pad_bundles = 0;
  int patched = 0;
  std::error_code ec;
  for (const auto& file : std::filesystem::directory_iterator(game_root, ec)) {
    if (file.path().extension() != ".ipk") continue;
    const std::vector<Entry> table = ReadTable(file.path());
    std::unordered_map<std::string, const Entry*> by_path;
    for (const Entry& e : table) {
      by_path.emplace(e.path, &e);
    }
    auto swap = [&](const Entry& from, const Entry& to) {
      rex::filesystem::AddHostFileReadPatch(
          file.path(), from.record, std::vector<uint8_t>(to.fields, to.fields + sizeof(to.fields)));
      ++patched;
    };
    // New data for an entry: past the end of the bundle (as read patches extend it), uncompressed.
    std::error_code size_error;
    uint64_t append_at = (std::filesystem::file_size(file.path(), size_error) + 0xFFF) & ~uint64_t(0xFFF);
    uint64_t data_base = 0;
    {
      std::ifstream in(file.path(), std::ios::binary);
      uint8_t header[0x10] = {};
      in.read(reinterpret_cast<char*>(header), sizeof(header));
      data_base = be32(header + 0x0C);
    }
    auto replace = [&](const Entry& entry, const std::shared_ptr<const std::vector<uint8_t>>& data) {
      if (size_error || append_at < data_base) {
        return false;
      }
      rex::filesystem::AddHostFileReadPatch(file.path(), append_at, data);
      std::vector<uint8_t> fields(entry.fields, entry.fields + sizeof(entry.fields));
      put_be(&fields[0], data->size(), 4);      // size
      put_be(&fields[4], 0, 4);                 // compressed size: stored
      put_be(&fields[16], append_at - data_base, 8);  // offset
      rex::filesystem::AddHostFileReadPatch(file.path(), entry.record, std::move(fields));
      append_at = (append_at + data->size() + 0xFFF) & ~uint64_t(0xFFF);
      ++patched;
      return true;
    };
    // The Help screen's bones moved (offsets in the skeleton's units), for a pad whose controls are elsewhere.
    for (const Entry& e : table) {
      if (bone_moves.empty() || !EndsWith(e.path, kHelpPadSkeleton) || be32(e.fields + 4) != 0) continue;
      const uint64_t data = data_base + ((uint64_t(be32(e.fields + 16)) << 32) | be32(e.fields + 20));
      std::ifstream in(file.path(), std::ios::binary);
      for (const BoneMove& move : bone_moves) {
        const uint64_t at = data + kSkeletonBones + uint64_t(move.bone) * kSkeletonBoneStride + move.field;
        uint8_t raw[4];
        in.seekg(std::streamoff(at));
        if (!in.read(reinterpret_cast<char*>(raw), sizeof(raw))) break;
        uint32_t bits = be32(raw);
        float value;
        std::memcpy(&value, &bits, 4);
        value += move.delta;
        std::memcpy(&bits, &value, 4);
        std::vector<uint8_t> changed(4);
        put_be(changed.data(), bits, 4);
        rex::filesystem::AddHostFileReadPatch(file.path(), at, std::move(changed));
        ++patched;
      }
    }
    for (const Entry& e : table) {
      if (!EndsWith(e.path, kHelpPadAtlas)) continue;
      if (help_pad_data && replace(e, help_pad_data)) {
        ++help_pad_bundles;
        continue;
      }
      for (const Entry& ps3 : table) {
        if (EndsWith(ps3.path, kHelpPadAtlasPs3)) swap(e, ps3);
      }
    }
    for (const auto& [xbox, playstation] : kSwaps) {
      const Entry* from = nullptr;
      const Entry* to = nullptr;
      for (const Entry& e : table) {
        if (EndsWith(e.path, xbox)) from = &e;
        if (EndsWith(e.path, playstation)) to = &e;
      }
      if (from && to) swap(*from, *to);
    }
    for (const Entry& e : table) {
      if (!EndsWith(e.path, ".act.ckd") || e.path.find("xbox") == std::string::npos) continue;
      auto twin = by_path.find(PlayStationTwin(e.path));
      if (twin != by_path.end() && twin->second != &e) swap(e, *twin->second);
    }
  }
  REXLOG_INFO("Button prompts: PlayStation ({} bundle entries); Help screen controller {} ({} bundles)",
              patched, help_pad_data ? help_pad.filename().string() : "PS3", help_pad_bundles);
}

}  // namespace rl_prompts
