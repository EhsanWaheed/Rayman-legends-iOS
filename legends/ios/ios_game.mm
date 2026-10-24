// ios_game.mm - see ios_game.h.
#include "ios_game.h"

#include "miniz.h"

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstring>
#include <memory>
#include <sys/stat.h>
#include <vector>

namespace rl {
namespace {

// default.xex of the Redump "Rayman Legends (USA, Europe)" disc (16,068,608 bytes): the program this app is
// translated from. Any other build would not match the recompiled code.
constexpr const char *kXexSha256 = "c9cd0b680c2d273450a31e3b067cafc63eee740b89312877e52214757766ece0";

// The files the game reads, relative to the game folder. The disc's Uplay browser, its dashboard art and the
// console's system update are left out.
const char *const kGameFiles[] = {
    "default.xex", "secure_fat.gf", "MapList.metapreload", "persistentLoading.preres",
    "EngineData/Localisation/localisation.loc8", "Bundle_X360.ipk", "persistentLoading_X360.ipk",
    "fullLogic_X360.ipk", "video/cine_gameintro.wmv", "video/cine_gameintro_fr.wmv",
    "video/ubilogo_lums_framework_720p.wmv",
};

NSFileManager *fm() { return NSFileManager.defaultManager; }

NSString *ns(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

bool ends_with_ci(const std::string &s, const char *suffix) {
    const size_t n = std::strlen(suffix);
    return s.size() >= n && strcasecmp(s.c_str() + s.size() - n, suffix) == 0;
}

std::string base_name(const std::string &path) {
    const size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string lower(std::string s) {
    for (char &c : s)
        c = (char)std::tolower((unsigned char)c);
    return s;
}

// Whether the game needs a file at `rel` (its path inside the game folder): the fixed list above, and every
// level package (*.ipk) at the top.
bool wanted(const std::string &rel) {
    for (const char *f : kGameFiles)
        if (strcasecmp(rel.c_str(), f) == 0)
            return true;
    return rel.find('/') == std::string::npos && ends_with_ci(rel, ".ipk");
}

// The folder holding default.xex: `dir` itself, or a folder one level down (a ZIP unpacked in Files usually has
// the game in a folder of its own).
std::string find_game_root(const std::string &dir, int depth = 1) {
    if ([fm() fileExistsAtPath:ns(dir + "/default.xex")])
        return dir;
    if (depth > 0)
        for (NSString *n in [[fm() contentsOfDirectoryAtPath:ns(dir) error:nil]
                 sortedArrayUsingSelector:@selector(compare:)]) {
            BOOL is_dir = NO;
            const std::string sub = dir + "/" + n.UTF8String;
            if (![n hasPrefix:@"."] && [fm() fileExistsAtPath:ns(sub) isDirectory:&is_dir] && is_dir) {
                const std::string r = find_game_root(sub, depth - 1);
                if (!r.empty())
                    return r;
            }
        }
    return "";
}

// SHA-256 of a file, reusing the digest cached for the same size and mtime.
std::string sha256_file(const std::string &path, const ProgressFn &progress) {
    struct stat st{};
    if (stat(path.c_str(), &st) != 0)
        return "";
    // Keyed by name, size and time, not the path: the app's own folder moves with every install.
    NSString *key = [NSString stringWithFormat:@"%s|%lld|%ld", base_name(path).c_str(), (long long)st.st_size,
                                               (long)st.st_mtimespec.tv_sec];
    NSDictionary *cache = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"ios.gameDigests"];
    if (NSString *hit = cache[key])
        return hit.UTF8String;
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f)
        return "";
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    std::vector<unsigned char> buf(4 << 20);
    Progress p;
    p.files_total = 1;
    p.bytes_total = (uint64_t)st.st_size;
    p.current = "Checking " + base_name(path);
    size_t n;
    while ((n = std::fread(buf.data(), 1, buf.size(), f)) > 0) {
        CC_SHA256_Update(&ctx, buf.data(), (CC_LONG)n);
        p.bytes_done += n;
        if (progress)
            progress(p);
    }
    std::fclose(f);
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(md, &ctx);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        std::snprintf(hex + 2 * i, 3, "%02x", md[i]);
    NSMutableDictionary *next = [NSMutableDictionary dictionaryWithDictionary:cache ?: @{}];
    if (next.count >= 8)
        [next removeAllObjects];  // a handful of copies at most; older digests are only a cache
    next[key] = @(hex);
    [NSUserDefaults.standardUserDefaults setObject:next forKey:@"ios.gameDigests"];
    return hex;
}

bool make_parent(const std::string &path) {
    return [fm() createDirectoryAtPath:[ns(path) stringByDeletingLastPathComponent]
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
}

bool copy_range(FILE *in, uint64_t size, const std::string &to, const std::atomic<bool> &cancel, Progress &p,
                const ProgressFn &progress, std::string *error) {
    make_parent(to);
    FILE *out = std::fopen(to.c_str(), "wb");
    if (!out) {
        *error = "cannot write " + base_name(to);
        return false;
    }
    std::vector<unsigned char> buf(4 << 20);
    bool ok = true;
    while (size && ok) {
        const size_t want = (size_t)std::min<uint64_t>(size, buf.size());
        const size_t n = std::fread(buf.data(), 1, want, in);
        if (cancel || n != want || std::fwrite(buf.data(), 1, n, out) != n)
            ok = false;
        size -= n;
        p.bytes_done += n;
        if (progress)
            progress(p);
    }
    if (std::fclose(out) != 0)
        ok = false;
    if (!ok && !cancel)
        *error = "could not copy " + base_name(to) + " (is there enough free space?)";
    return ok;
}

bool copy_file(const std::string &from, const std::string &to, const std::atomic<bool> &cancel, Progress &p,
               const ProgressFn &progress, std::string *error) {
    struct stat s{};
    FILE *in = stat(from.c_str(), &s) == 0 ? std::fopen(from.c_str(), "rb") : nullptr;
    if (!in) {
        *error = "cannot read " + base_name(from);
        return false;
    }
    const bool ok = copy_range(in, (uint64_t)s.st_size, to, cancel, p, progress, error);
    std::fclose(in);
    return ok;
}

uint64_t free_space(const std::string &dir) {
    NSDictionary *a = [fm() attributesOfFileSystemForPath:ns(dir) error:nil];
    return [a[NSFileSystemFreeSize] unsignedLongLongValue];
}

struct ZipWrite {
    FILE *f;
    Progress *p;
    const ProgressFn *progress;
    const std::atomic<bool> *cancel;
};

size_t zip_write(void *opaque, mz_uint64, const void *data, size_t n) {
    ZipWrite *w = (ZipWrite *)opaque;
    if (*w->cancel)
        return 0;
    const size_t wrote = std::fwrite(data, 1, n, w->f);
    w->p->bytes_done += wrote;
    if (*w->progress)
        (*w->progress)(*w->p);
    return wrote;
}

// ---- Xbox 360 disc images (XDVDFS) ------------------------------------------------------------------------------

struct IsoEntry {
    std::string path;  // inside the game folder, '/'-separated
    uint64_t offset = 0, size = 0;
};

// The files of an XDVDFS volume: plain, or the game partition of an XGD1/2/3 disc. Each directory is a binary
// tree of entries (left, right, start sector, size, attributes, name).
bool read_iso(FILE *f, std::vector<IsoEntry> *out) {
    constexpr uint64_t kSector = 2048;
    static const char kMagic[] = "MICROSOFT*XBOX*MEDIA";
    uint64_t base = UINT64_MAX;
    for (uint64_t b : {0x0ull, 0x2080000ull, 0xFD90000ull, 0x18300000ull}) {
        char magic[20];
        if (fseeko(f, (off_t)(b + 32 * kSector), SEEK_SET) == 0 && std::fread(magic, 1, 20, f) == 20 &&
            std::memcmp(magic, kMagic, 20) == 0) {
            base = b;
            break;
        }
    }
    if (base == UINT64_MAX)
        return false;
    uint8_t root[8];
    if (std::fread(root, 1, 8, f) != 8)
        return false;
    auto le32 = [](const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; };
    auto le16 = [](const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; };

    std::function<void(uint32_t, uint32_t, const std::string &, int)> walk = [&](uint32_t sector, uint32_t size,
                                                                                 const std::string &prefix, int depth) {
        if (!size || depth > 16)
            return;
        std::vector<uint8_t> table(size);
        if (fseeko(f, (off_t)(base + sector * kSector), SEEK_SET) != 0 || std::fread(table.data(), 1, size, f) != size)
            return;
        std::vector<uint32_t> stack{0};
        std::vector<bool> seen(size / 4 + 1);
        while (!stack.empty()) {
            const uint32_t off = stack.back();
            stack.pop_back();
            if (off + 14 > size || seen[off / 4])
                continue;
            seen[off / 4] = true;
            const uint8_t *e = table.data() + off;
            const uint32_t left = le16(e), right = le16(e + 2);
            if (left == 0xFFFF)
                continue;
            const uint32_t start = le32(e + 4), length = le32(e + 8);
            const uint8_t attrs = e[12], nlen = e[13];
            if (off + 14 + nlen > size)
                continue;
            const std::string name((const char *)e + 14, nlen);
            const std::string path = prefix.empty() ? name : prefix + "/" + name;
            if (attrs & 0x10)
                walk(start, length, path, depth + 1);
            else
                out->push_back({path, base + (uint64_t)start * kSector, length});
            if (left)
                stack.push_back(left * 4);
            if (right)
                stack.push_back(right * 4);
        }
    };
    walk(le32(root), le32(root + 4), "", 0);
    return true;
}

}  // namespace

std::string human_bytes(uint64_t b) {
    char s[32];
    if (b >= (1ull << 30))
        std::snprintf(s, sizeof s, "%.1f GB", b / 1073741824.0);
    else if (b >= (1ull << 20))
        std::snprintf(s, sizeof s, "%.0f MB", b / 1048576.0);
    else
        std::snprintf(s, sizeof s, "%.0f KB", b / 1024.0);
    return s;
}

GameStatus check_game(const std::string &dir, const ProgressFn &progress) {
    GameStatus st;
    st.root = find_game_root(dir);
    if (st.root.empty()) {
        st.root = dir;
        return st;
    }
    for (const char *f : kGameFiles) {
        struct stat s{};
        if (stat((st.root + "/" + f).c_str(), &s) != 0 || s.st_size == 0)
            st.missing += (st.missing.empty() ? "" : ", ") + std::string(f);
    }
    // The level packages: at least the ones every world needs.
    int packages = 0;
    for (NSString *n in [fm() contentsOfDirectoryAtPath:ns(st.root) error:nil])
        if ([n.pathExtension caseInsensitiveCompare:@"ipk"] == NSOrderedSame)
            ++packages;
    if (packages < 100)
        st.missing += (st.missing.empty() ? "" : ", ") + std::string("level packages (") + std::to_string(packages) +
                      " of 104 .ipk files)";
    if (!st.missing.empty()) {
        st.state = State::Incomplete;
        return st;
    }
    st.state = sha256_file(st.root + "/default.xex", progress) == kXexSha256 ? State::Ready : State::WrongVersion;
    return st;
}

ImportResult import_game(const std::string &source, Source kind, const std::string &dest,
                         const std::atomic<bool> &cancel, const ProgressFn &progress, GameStatus *status,
                         std::string *error) {
    const std::string staging = dest + ".importing";
    [fm() removeItemAtPath:ns(staging) error:nil];
    [fm() createDirectoryAtPath:ns(staging) withIntermediateDirectories:YES attributes:nil error:nil];
    const std::string parent = dest.substr(0, dest.find_last_of('/'));
    Progress p;

    if (kind == Source::Folder) {
        const std::string root = find_game_root(source);
        if (root.empty())
            return ImportResult::NoGame;
        std::vector<std::string> files;
        NSDirectoryEnumerator *e = [fm() enumeratorAtPath:ns(root)];
        for (NSString *rel in e) {
            BOOL is_dir = NO;
            const std::string r = rel.UTF8String;
            if (wanted(r) && [fm() fileExistsAtPath:ns(root + "/" + r) isDirectory:&is_dir] && !is_dir) {
                struct stat s{};
                stat((root + "/" + r).c_str(), &s);
                p.bytes_total += (uint64_t)s.st_size;
                files.push_back(r);
            }
        }
        if (p.bytes_total + (256ull << 20) > free_space(parent)) {
            *error = human_bytes(p.bytes_total);
            return ImportResult::NoSpace;
        }
        p.files_total = files.size();
        for (const std::string &r : files) {
            p.current = r;
            if (!copy_file(root + "/" + r, staging + "/" + r, cancel, p, progress, error))
                return cancel ? ImportResult::Cancelled : ImportResult::Failed;
            p.files_done++;
        }
    } else if (kind == Source::Iso) {
        FILE *f = std::fopen(source.c_str(), "rb");
        if (!f) {
            *error = "cannot read " + base_name(source);
            return ImportResult::Failed;
        }
        std::unique_ptr<FILE, int (*)(FILE *)> guard(f, std::fclose);
        std::vector<IsoEntry> entries;
        if (!read_iso(f, &entries))
            return ImportResult::NoGame;
        std::vector<IsoEntry> files;
        for (const IsoEntry &e : entries)
            if (wanted(e.path)) {
                files.push_back(e);
                p.bytes_total += e.size;
            }
        bool has_xex = false;
        for (const IsoEntry &e : files)
            has_xex |= lower(e.path) == "default.xex";
        if (!has_xex)
            return ImportResult::NoGame;
        if (p.bytes_total + (256ull << 20) > free_space(parent)) {
            *error = human_bytes(p.bytes_total);
            return ImportResult::NoSpace;
        }
        p.files_total = files.size();
        for (const IsoEntry &e : files) {
            p.current = e.path;
            if (fseeko(f, (off_t)e.offset, SEEK_SET) != 0 ||
                !copy_range(f, e.size, staging + "/" + e.path, cancel, p, progress, error))
                return cancel ? ImportResult::Cancelled : ImportResult::Failed;
            p.files_done++;
        }
    } else {
        mz_zip_archive za{};
        if (!mz_zip_reader_init_file(&za, source.c_str(), 0)) {
            *error = "not a ZIP file the app can read";
            return ImportResult::Failed;
        }
        std::unique_ptr<mz_zip_archive, void (*)(mz_zip_archive *)> guard(&za, [](mz_zip_archive *z) {
            mz_zip_reader_end(z);
        });
        const mz_uint count = mz_zip_reader_get_num_files(&za);
        auto entry_name = [&](mz_uint i) {
            char name[1024];
            mz_zip_reader_get_filename(&za, i, name, sizeof name);
            return std::string(name);
        };
        // The game's folder inside the ZIP: wherever default.xex is.
        std::string prefix;
        bool found = false;
        for (mz_uint i = 0; i < count && !found; ++i) {
            const std::string n = entry_name(i);
            if (lower(base_name(n)) == "default.xex" && n.rfind("__MACOSX", 0) != 0) {
                prefix = n.substr(0, n.size() - base_name(n).size());
                found = true;
            }
        }
        if (!found)
            return ImportResult::NoGame;
        std::vector<std::pair<std::string, mz_uint>> files;
        for (mz_uint i = 0; i < count; ++i) {
            const std::string n = entry_name(i);
            if (n.rfind(prefix, 0) != 0 || mz_zip_reader_is_file_a_directory(&za, i))
                continue;
            const std::string rel = n.substr(prefix.size());
            if (!wanted(rel))
                continue;
            mz_zip_archive_file_stat s;
            mz_zip_reader_file_stat(&za, i, &s);
            p.bytes_total += s.m_uncomp_size;
            files.push_back({rel, i});
        }
        if (p.bytes_total + (256ull << 20) > free_space(parent)) {
            *error = human_bytes(p.bytes_total);
            return ImportResult::NoSpace;
        }
        p.files_total = files.size();
        for (const auto &w : files) {
            p.current = w.first;
            const std::string out = staging + "/" + w.first;
            make_parent(out);
            FILE *f = std::fopen(out.c_str(), "wb");
            if (!f) {
                *error = "cannot write " + w.first;
                return ImportResult::Failed;
            }
            ZipWrite zw{f, &p, &progress, &cancel};
            const bool ok = mz_zip_reader_extract_to_callback(&za, w.second, zip_write, &zw, 0);
            const bool closed = std::fclose(f) == 0;
            if (cancel)
                return ImportResult::Cancelled;
            if (!ok || !closed) {
                *error = "could not unpack " + w.first + " (is there enough free space?)";
                return ImportResult::Failed;
            }
            p.files_done++;
        }
    }

    GameStatus st = check_game(staging, progress);
    if (status)
        *status = st;
    if (st.state == State::WrongVersion) {
        [fm() removeItemAtPath:ns(staging) error:nil];
        return ImportResult::WrongVersion;
    }
    if (st.state != State::Ready) {
        *error = st.missing;
        return ImportResult::Incomplete;
    }
    [fm() removeItemAtPath:ns(dest) error:nil];
    NSError *err = nil;
    if (![fm() moveItemAtPath:ns(staging) toPath:ns(dest) error:&err]) {
        *error = err.localizedDescription.UTF8String;
        return ImportResult::Failed;
    }
    // The game is the player's to back up, not iCloud's.
    NSURL *url = [NSURL fileURLWithPath:ns(dest)];
    [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    if (status)
        *status = check_game(dest);
    return ImportResult::Ok;
}

bool export_saves(const std::string &saves_dir, const std::string &zip_path, std::string *error) {
    mz_zip_archive za{};
    if (!mz_zip_writer_init_file(&za, zip_path.c_str(), 0)) {
        *error = "cannot write " + base_name(zip_path);
        return false;
    }
    bool ok = true;
    NSDirectoryEnumerator *e = [fm() enumeratorAtPath:ns(saves_dir)];
    for (NSString *rel in e) {
        BOOL is_dir = NO;
        const std::string full = saves_dir + "/" + rel.UTF8String;
        if ([fm() fileExistsAtPath:ns(full) isDirectory:&is_dir] && !is_dir)
            ok = ok && mz_zip_writer_add_file(&za, rel.UTF8String, full.c_str(), nullptr, 0, MZ_DEFAULT_COMPRESSION);
    }
    ok = mz_zip_writer_finalize_archive(&za) && ok;
    mz_zip_writer_end(&za);
    if (!ok)
        *error = "the ZIP could not be written";
    return ok;
}

bool import_saves(const std::string &zip_path, const std::string &saves_dir, std::string *error) {
    mz_zip_archive za{};
    if (!mz_zip_reader_init_file(&za, zip_path.c_str(), 0)) {
        *error = "not a ZIP file the app can read";
        return false;
    }
    bool ok = true;
    const mz_uint count = mz_zip_reader_get_num_files(&za);
    for (mz_uint i = 0; i < count && ok; ++i) {
        if (mz_zip_reader_is_file_a_directory(&za, i))
            continue;
        char name[1024];
        mz_zip_reader_get_filename(&za, i, name, sizeof name);
        const std::string n = name;
        if (n.empty() || n[0] == '/' || n.find("..") != std::string::npos || n.rfind("__MACOSX", 0) == 0)
            continue;  // never outside the saves folder
        const std::string out = saves_dir + "/" + n;
        make_parent(out);
        ok = mz_zip_reader_extract_to_file(&za, i, out.c_str(), 0);
    }
    mz_zip_reader_end(&za);
    if (!ok)
        *error = "the ZIP could not be read completely";
    return ok;
}

}  // namespace rl
