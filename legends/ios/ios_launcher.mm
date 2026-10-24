// ios_launcher.mm - the iOS launcher: a Liquid Glass screen that finds, checks and imports the player's copy of
// Rayman Legends (Xbox 360), then lets the game start in this process (ios_launcher.h).
//
// The view (RecompLauncherView) is the one from the NFSMW and Hercules iOS ports: the cover art blurred behind and
// sharp on a card, the title and the status, one glass button per launcher button with Play the prominent one, the
// focused button lifted with a ring while a controller or keyboard is in use, and button hints in the connected
// controller's own glyphs. The model under it checks default.xex and imports the game from a folder, a ZIP or the
// disc image (ios_game.h).
//
// It runs before the game makes its window, in a window of its own, turning the run loop itself; the game's window
// replaces it when Play is pressed.
#include "ios_game.h"
#include "ios_launcher.h"
#include "ios_overlay.h"

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace launcher {

enum class Screen { Main, Import, Manage, Importing, Message };
enum class Key { Up, Down, Activate, Back };
enum Action : int {
    kPlay = 1,
    kImportFolder,
    kImportZip,
    kImportIso,
    kManage,
    kImportMenu,
    kExportSaves,
    kImportSaves,
    kDeleteData,
    kBack,
    kCancel,
    kOk,
    kQuit,
};

struct Button {
    int id;
    std::string label;
    bool enabled = true;
};

struct Progress {
    uint64_t files_done = 0, files_total = 0, bytes_done = 0, bytes_total = 0;
    std::string current;
};

struct View {
    std::string title, headline, detail, detail2, message;
    int tone = 0;  // 0 bad, 1 ready, 2 warning
    Screen screen = Screen::Main;
    Progress progress;
    std::vector<Button> buttons;
    int focus = 0;
};

std::string human_bytes(uint64_t b) { return rl::human_bytes(b); }

class Platform {
  public:
    virtual ~Platform() = default;
    virtual void pick(rl::Source kind) = 0;
    virtual void pick_saves() = 0;
    virtual void export_file(const std::string &path) = 0;
};

class Launcher {
  public:
    Launcher(Platform &platform, std::string import_root, std::string bundled_root, std::string saves_dir)
        : platform_(platform), import_root_(std::move(import_root)), bundled_root_(std::move(bundled_root)),
          saves_dir_(std::move(saves_dir)) {}

    void start() { check(); }

    View view() {
        View v;
        v.title = "Rayman Legends";
        status_text(&v.tone, &v.headline, &v.detail);
        v.screen = screen_;
        v.message = message_;
        if (screen_ == Screen::Import)
            v.detail2 = "Replaces the installed game with a new copy once it has been checked. Saves are kept.";
        if (screen_ == Screen::Manage)
            v.detail2 = "Saves are in the app's Documents/Saves folder (Files app). They are kept when the game is "
                        "deleted or imported again.";
        {
            std::lock_guard<std::mutex> lock(m_);
            v.progress = progress_;
        }
        v.buttons = buttons_;
        v.focus = focus_;
        dirty_ = false;
        return v;
    }

    bool dirty() const { return dirty_ || busy_; }
    bool finished() const { return finished_; }
    bool quit() const { return quit_; }
    const rl::GameStatus &status() const { return status_; }

    void key(Key k) {
        if (buttons_.empty())
            return;
        switch (k) {
        case Key::Up:
        case Key::Down: {
            const int n = (int)buttons_.size(), step = k == Key::Up ? -1 : 1;
            for (int i = 1; i <= n; ++i) {
                const int f = ((focus_ + step * i) % n + n) % n;
                if (buttons_[f].enabled) {
                    focus_ = f;
                    break;
                }
            }
            break;
        }
        case Key::Activate:
            if (focus_ < (int)buttons_.size() && buttons_[focus_].enabled)
                activate(buttons_[focus_].id);
            return;
        case Key::Back:
            if (screen_ == Screen::Manage || screen_ == Screen::Import || screen_ == Screen::Message)
                go(Screen::Main);
            else if (screen_ == Screen::Importing)
                activate(kCancel);
            return;
        }
        dirty_ = true;
    }

    void activate(int id) {
        switch (id) {
        case kPlay:
            if (status_.state == rl::State::Ready)
                finished_ = true;
            break;
        case kImportFolder: platform_.pick(rl::Source::Folder); break;
        case kImportZip: platform_.pick(rl::Source::Zip); break;
        case kImportIso: platform_.pick(rl::Source::Iso); break;
        case kManage: confirm_delete_ = false; go(Screen::Manage); break;
        case kImportMenu: go(Screen::Import); break;
        case kExportSaves: {
            const std::string zip = std::string(NSTemporaryDirectory().UTF8String) + "/Rayman Legends Saves.zip";
            std::string err;
            if (rl::export_saves(saves_dir_, zip, &err))
                platform_.export_file(zip);
            else
                show("Could not export saves: " + err);
            break;
        }
        case kImportSaves: platform_.pick_saves(); break;
        case kDeleteData:
            if (!confirm_delete_) {
                confirm_delete_ = true;
                rebuild();
                break;
            }
            [NSFileManager.defaultManager removeItemAtPath:@(import_root_.c_str()) error:nil];
            confirm_delete_ = false;
            check();
            show("Game deleted. Saves are kept.");
            break;
        case kBack: go(Screen::Main); break;
        case kOk: go(Screen::Main); break;
        case kCancel: cancel_ = true; break;
        case kQuit: finished_ = quit_ = true; break;
        }
        dirty_ = true;
    }

    // A folder, ZIP or disc image the player picked (security-scoped access is the platform's).
    void picked(const std::string &path, rl::Source kind, std::function<void()> release) {
        go(Screen::Importing);
        cancel_ = false;
        busy_ = true;
        std::thread([this, path, kind, release] {
            rl::GameStatus st;
            std::string err;
            const rl::ImportResult r = rl::import_game(
                path, kind, import_root_, cancel_,
                [this](const rl::Progress &p) {
                    std::lock_guard<std::mutex> lock(m_);
                    progress_ = {p.files_done, p.files_total, p.bytes_done, p.bytes_total, p.current};
                },
                &st, &err);
            dispatch_async(dispatch_get_main_queue(), ^{
              release();
              busy_ = false;
              finish_import(r, st, err);
            });
        }).detach();
    }

    void picked_saves(const std::string &path) {
        std::string err;
        show(rl::import_saves(path, saves_dir_, &err) ? "Saves imported." : "Could not import saves: " + err);
    }

    void show(const std::string &text) {
        message_ = text;
        go(Screen::Message);
    }

  private:
    void go(Screen s) {
        screen_ = s;
        rebuild();
    }

    // The game in Documents/game, else the one inside the app (the owner's IPA). The first check of a copy hashes
    // default.xex, so it runs off the main thread with the progress showing.
    void check() {
        busy_ = true;
        screen_ = Screen::Importing;
        checking_ = true;
        rebuild();
        std::thread([this] {
            auto progress = [this](const rl::Progress &p) {
                std::lock_guard<std::mutex> lock(m_);
                progress_ = {p.files_done, p.files_total, p.bytes_done, p.bytes_total, p.current};
            };
            rl::GameStatus st = rl::check_game(import_root_, progress);
            if (st.state == rl::State::NotFound && !bundled_root_.empty())
                st = rl::check_game(bundled_root_, progress);
            dispatch_async(dispatch_get_main_queue(), ^{
              status_ = st;
              busy_ = checking_ = false;
              go(Screen::Main);
            });
        }).detach();
    }

    void finish_import(rl::ImportResult r, const rl::GameStatus &st, const std::string &err) {
        switch (r) {
        case rl::ImportResult::Ok:
            status_ = st;
            go(Screen::Main);
            break;
        case rl::ImportResult::Cancelled: show("Import cancelled. The copy you had before is kept."); break;
        case rl::ImportResult::NoGame:
            show("The chosen files do not contain Rayman Legends: pick the game's folder (with default.xex), a ZIP of "
                 "it, or the Xbox 360 disc image (.iso).");
            break;
        case rl::ImportResult::WrongVersion:
            show(std::string("This is a different build of Rayman Legends. This app is translated from the ") +
                 rl::kReleaseName + " disc.");
            break;
        case rl::ImportResult::Incomplete: show("The chosen files are incomplete: " + err + " is missing."); break;
        case rl::ImportResult::NoSpace: show("Not enough free space: the import needs " + err + "."); break;
        case rl::ImportResult::Failed: show("The import failed: " + err + "."); break;
        }
    }

    void rebuild() {
        buttons_.clear();
        auto add = [&](int id, const std::string &label, bool enabled = true) {
            buttons_.push_back({id, label, enabled});
        };
        switch (screen_) {
        case Screen::Main: {
            const bool have = status_.state != rl::State::NotFound;
            if (status_.state == rl::State::Ready)
                add(kPlay, "Play");
            // With a game installed, importing again is one button (its own page), so the column fits a
            // landscape phone; without one the three ways to import are the point of the screen.
            if (have) {
                add(kImportMenu, "Import again...");
            } else {
                add(kImportIso, "Import disc image (.iso)...");
                add(kImportFolder, "Import game folder...");
                add(kImportZip, "Import game ZIP...");
            }
            add(kManage, "Manage...");
            add(kQuit, "Quit");
            break;
        }
        case Screen::Import:
            add(kImportIso, "From the disc image (.iso)...");
            add(kImportFolder, "From a folder...");
            add(kImportZip, "From a ZIP...");
            add(kBack, "Back");
            break;
        case Screen::Manage:
            add(kExportSaves, "Export saves...");
            add(kImportSaves, "Import saves...");
            if ([NSFileManager.defaultManager fileExistsAtPath:@(import_root_.c_str())])
                add(kDeleteData, confirm_delete_ ? "Delete game - press again" : "Delete game");
            add(kBack, "Back");
            break;
        case Screen::Importing:
            if (!checking_)
                add(kCancel, "Cancel");
            break;
        case Screen::Message: add(kOk, "OK"); break;
        }
        focus_ = 0;
        dirty_ = true;
    }

    void status_text(int *tone, std::string *headline, std::string *detail) const {
        *tone = 0;
        if (checking_) {
            *tone = 1;
            *headline = "Checking your game";
            *detail = "Only the first time: default.xex is checked against the release this app is built from.";
            return;
        }
        const bool bundled = !bundled_root_.empty() && status_.root.rfind(bundled_root_, 0) == 0;
        switch (status_.state) {
        case rl::State::Ready:
            *tone = 1;
            *headline = "Ready to play";
            *detail = std::string(rl::kReleaseName) + (bundled ? "  ·  included with the app" : "  ·  Documents/game");
            break;
        case rl::State::WrongVersion:
            *tone = 2;
            *headline = "Different build of the game";
            *detail = std::string("This app is translated from the ") + rl::kReleaseName + " disc (Redump).";
            break;
        case rl::State::Incomplete:
            *tone = 2;
            *headline = "Game is incomplete";
            *detail = "Missing: " + status_.missing;
            break;
        case rl::State::NotFound:
            *headline = "Game not found";
            *detail = "Import your copy of Rayman Legends (Xbox 360): the disc image (.iso), the game's folder, or a "
                      "ZIP of it. Or copy the folder into the app's Documents/game with the Files app or Finder.";
            break;
        }
    }

    Platform &platform_;
    std::string import_root_, bundled_root_, saves_dir_;
    rl::GameStatus status_;
    Screen screen_ = Screen::Main;
    std::vector<Button> buttons_;
    int focus_ = 0;
    std::string message_;
    bool confirm_delete_ = false, finished_ = false, quit_ = false, dirty_ = true, checking_ = false;
    std::atomic<bool> busy_{false}, cancel_{false};
    std::mutex m_;
    Progress progress_;
};

}  // namespace launcher

namespace {

NSString *ns(const std::string &s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

UIVisualEffect *glass_or_blur() {
    if (@available(iOS 26.0, *))
        return [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
}

bool controller_in_use() {
    return GCController.controllers.count > 0 || GCKeyboard.coalescedKeyboard != nil;
}

}  // namespace

int rl_pad_family(void) {
    GCController *c = GCController.current ?: GCController.controllers.firstObject;
    if (!c)
        return 0;
    NSString *cat = c.productCategory ?: @"";
    if ([cat isEqualToString:GCProductCategoryDualSense] || [cat isEqualToString:GCProductCategoryDualShock4])
        return 1;
    GCExtendedGamepad *pad = c.extendedGamepad;
    if ([pad isKindOfClass:GCDualSenseGamepad.class] || [pad isKindOfClass:GCDualShockGamepad.class])
        return 1;
    NSString *name = [NSString stringWithFormat:@"%@ %@", c.vendorName ?: @"", cat].lowercaseString;
    for (NSString *word in @[ @"playstation", @"dualsense", @"dualshock", @"ps5", @"ps4" ])
        if ([name containsString:word])
            return 1;
    return 2;
}

@interface RecompLauncherView : UIView
@property(nonatomic) launcher::Launcher *model;
@property(nonatomic) UIImageView *backdrop;
@property(nonatomic) UIImageView *art;
@property(nonatomic) UILabel *titleLabel;
@property(nonatomic) UILabel *versionLabel;
@property(nonatomic) UIView *statusPill;
@property(nonatomic) UIImageView *statusIcon;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UILabel *detailLabel;
@property(nonatomic) UIStackView *buttonStack;
@property(nonatomic) UIView *progressCard;
@property(nonatomic) UIProgressView *progress;
@property(nonatomic) UILabel *progressLabel;
@property(nonatomic) UILabel *hintLabel;
@property(nonatomic) NSMutableArray<UIButton *> *buttons;
@property(nonatomic) std::vector<std::pair<int, std::string>> shown;  // the buttons on screen (id, label)
@property(nonatomic) int shownScreen;
@property(nonatomic) int focus;
@property(nonatomic) BOOL compact;   // a phone in landscape (under 520 points tall): smaller type and buttons
@property(nonatomic) int lastFocus;  // the launcher's focus as last shown (a controller connecting redraws it)
@end

@implementation RecompLauncherView

// The cover: LauncherArt.png in the bundle (ios/LauncherArt.png, the owner's box art, kept out of git). Without one,
// a card in the colours of the game's world map with its name.
+ (UIImage *)coverArt {
    NSString *path = [NSBundle.mainBundle pathForResource:@"LauncherArt" ofType:@"png"];
    if (UIImage *img = path ? [UIImage imageWithContentsOfFile:path] : nil)
        return img;
    const CGSize size = CGSizeMake(600, 600);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
      CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
      NSArray *colors = @[
          (id)[UIColor colorWithRed:0.10 green:0.36 blue:0.20 alpha:1].CGColor,
          (id)[UIColor colorWithRed:0.95 green:0.62 blue:0.10 alpha:1].CGColor,
          (id)[UIColor colorWithRed:0.62 green:0.16 blue:0.48 alpha:1].CGColor
      ];
      const CGFloat stops[] = {0, 0.55, 1};
      CGGradientRef grad = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, stops);
      CGContextDrawLinearGradient(ctx.CGContext, grad, CGPointMake(0, 0), CGPointMake(size.width, size.height), 0);
      CGGradientRelease(grad);
      CGColorSpaceRelease(space);
      NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
      para.alignment = NSTextAlignmentCenter;
      UIFont *serif = [UIFont fontWithDescriptor:[[UIFont systemFontOfSize:64 weight:UIFontWeightHeavy].fontDescriptor
                                                     fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif]
                                            size:64];
      [@"RAYMAN\nLEGENDS" drawInRect:CGRectMake(0, 190, size.width, 220)
               withAttributes:@{
                   NSFontAttributeName : serif,
                   NSForegroundColorAttributeName : UIColor.whiteColor,
                   NSParagraphStyleAttributeName : para,
                   NSKernAttributeName : @6
               }];
    }];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame]))
        return nil;
    self.backgroundColor = UIColor.blackColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.buttons = [NSMutableArray array];
    self.shownScreen = -1;
    self.focus = -1;
    UIImage *artImage = [RecompLauncherView coverArt];

    // Behind everything: the art, filling the screen, softened and darkened towards the text.
    self.backdrop = [[UIImageView alloc] initWithImage:artImage];
    self.backdrop.contentMode = UIViewContentModeScaleAspectFill;
    self.backdrop.clipsToBounds = YES;
    self.backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.backdrop];
    UIVisualEffectView *soften =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    soften.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:soften];
    CAGradientLayer *shade = [CAGradientLayer layer];
    shade.colors = @[ (id)[UIColor colorWithWhite:0 alpha:0.15].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.65].CGColor ];
    shade.startPoint = CGPointMake(0, 0.5);
    shade.endPoint = CGPointMake(1, 0.5);
    UIView *shadeView = [UIView new];
    shadeView.translatesAutoresizingMaskIntoConstraints = NO;
    shadeView.userInteractionEnabled = NO;
    [shadeView.layer addSublayer:shade];
    [self addSubview:shadeView];

    // The hero: the cover on a card, with a soft shadow.
    UIView *artShadow = [UIView new];
    artShadow.translatesAutoresizingMaskIntoConstraints = NO;
    artShadow.layer.shadowColor = UIColor.blackColor.CGColor;
    artShadow.layer.shadowOpacity = 0.55;
    artShadow.layer.shadowRadius = 28;
    artShadow.layer.shadowOffset = CGSizeMake(0, 14);
    [self addSubview:artShadow];
    self.art = [[UIImageView alloc] initWithImage:artImage];
    self.art.translatesAutoresizingMaskIntoConstraints = NO;
    self.art.contentMode = UIViewContentModeScaleAspectFill;
    self.art.clipsToBounds = YES;
    self.art.layer.cornerRadius = 18;
    self.art.layer.cornerCurve = kCACornerCurveContinuous;
    self.art.layer.borderWidth = 0.5;
    self.art.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [artShadow addSubview:self.art];

    // The text column.
    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.7;
    self.versionLabel = [UILabel new];
    self.versionLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.versionLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    NSString *v = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    self.versionLabel.text = [NSString stringWithFormat:@"Xbox 360  ·  iOS %@", v];

    self.statusPill = [[UIVisualEffectView alloc] initWithEffect:glass_or_blur()];
    self.statusPill.layer.cornerRadius = 15;
    self.statusPill.layer.cornerCurve = kCACornerCurveContinuous;
    self.statusPill.clipsToBounds = YES;
    self.statusIcon = [UIImageView new];
    self.statusIcon.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = UIColor.whiteColor;
    UIStackView *pill = [[UIStackView alloc] initWithArrangedSubviews:@[ self.statusIcon, self.statusLabel ]];
    pill.spacing = 7;
    pill.alignment = UIStackViewAlignmentCenter;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    [((UIVisualEffectView *)self.statusPill).contentView addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [pill.leadingAnchor constraintEqualToAnchor:self.statusPill.leadingAnchor constant:12],
        [pill.trailingAnchor constraintEqualToAnchor:self.statusPill.trailingAnchor constant:-14],
        [pill.topAnchor constraintEqualToAnchor:self.statusPill.topAnchor constant:6],
        [pill.bottomAnchor constraintEqualToAnchor:self.statusPill.bottomAnchor constant:-6],
    ]];
    UIStackView *pillRow = [[UIStackView alloc] initWithArrangedSubviews:@[ self.statusPill, [UIView new] ]];

    self.detailLabel = [UILabel new];
    self.detailLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    self.detailLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    self.detailLabel.numberOfLines = 4;

    // The import's progress, in place of the buttons while it runs.
    self.progressCard = [UIView new];
    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progress.progressTintColor = UIColor.whiteColor;
    self.progress.trackTintColor = [UIColor colorWithWhite:1 alpha:0.18];
    self.progressLabel = [UILabel new];
    self.progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.progressLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    self.progressLabel.numberOfLines = 3;
    UIStackView *prog = [[UIStackView alloc] initWithArrangedSubviews:@[ self.progress, self.progressLabel ]];
    prog.axis = UILayoutConstraintAxisVertical;
    prog.spacing = 10;
    prog.translatesAutoresizingMaskIntoConstraints = NO;
    [self.progressCard addSubview:prog];
    [NSLayoutConstraint activateConstraints:@[
        [prog.leadingAnchor constraintEqualToAnchor:self.progressCard.leadingAnchor],
        [prog.trailingAnchor constraintEqualToAnchor:self.progressCard.trailingAnchor],
        [prog.topAnchor constraintEqualToAnchor:self.progressCard.topAnchor],
        [prog.bottomAnchor constraintEqualToAnchor:self.progressCard.bottomAnchor],
    ]];
    self.progressCard.hidden = YES;

    self.compact = UIScreen.mainScreen.bounds.size.height < 520 || UIScreen.mainScreen.bounds.size.width < 520;
    if (self.compact) {
        self.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
        self.titleLabel.numberOfLines = 1;
        self.detailLabel.numberOfLines = 3;
    }
    self.buttonStack = [UIStackView new];
    self.buttonStack.axis = UILayoutConstraintAxisVertical;
    self.buttonStack.spacing = self.compact ? 8 : 10;

    self.hintLabel = [UILabel new];
    self.hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    self.hintLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.titleLabel, self.versionLabel, pillRow, self.detailLabel, self.progressCard, self.buttonStack, self.hintLabel
    ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 10;
    [column setCustomSpacing:2 afterView:self.titleLabel];
    [column setCustomSpacing:self.compact ? 12 : 18 afterView:self.versionLabel];
    [column setCustomSpacing:self.compact ? 12 : 20 afterView:self.detailLabel];
    [column setCustomSpacing:self.compact ? 10 : 16 afterView:self.buttonStack];
    [column setCustomSpacing:self.compact ? 12 : 16 afterView:pillRow];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:column];

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.backdrop.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.backdrop.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.backdrop.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.backdrop.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [soften.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [soften.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [soften.topAnchor constraintEqualToAnchor:self.topAnchor],
        [soften.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [shadeView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [shadeView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [shadeView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [shadeView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        // the cover: on the left, most of the height, in the art's own shape (the box art is portrait)
        [artShadow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:36],
        [artShadow.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [artShadow.heightAnchor constraintEqualToAnchor:safe.heightAnchor multiplier:0.8],
        [artShadow.widthAnchor constraintEqualToAnchor:artShadow.heightAnchor
                                            multiplier:artImage.size.height > 0
                                                           ? artImage.size.width / artImage.size.height
                                                           : 1],
        [self.art.leadingAnchor constraintEqualToAnchor:artShadow.leadingAnchor],
        [self.art.trailingAnchor constraintEqualToAnchor:artShadow.trailingAnchor],
        [self.art.topAnchor constraintEqualToAnchor:artShadow.topAnchor],
        [self.art.bottomAnchor constraintEqualToAnchor:artShadow.bottomAnchor],

        // the column: beside it, centred, at most 380 wide
        [column.leadingAnchor constraintEqualToAnchor:artShadow.trailingAnchor constant:44],
        [column.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-36],
        [column.widthAnchor constraintLessThanOrEqualToConstant:380],
        [column.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [column.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:12],
        [column.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];
    NSLayoutConstraint *wide = [column.widthAnchor constraintEqualToConstant:380];
    wide.priority = UILayoutPriorityDefaultHigh;
    wide.active = YES;
    // the gradient follows the view's size
    self.layer.name = @"launcher";
    shadeView.layer.name = @"shade";
    for (NSNotificationName n in @[ GCControllerDidConnectNotification, GCControllerDidDisconnectNotification,
                                     GCControllerDidBecomeCurrentNotification, GCKeyboardDidConnectNotification,
                                     GCKeyboardDidDisconnectNotification ])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllersChanged:) name:n object:nil];
    self.alpha = 0;
    [UIView animateWithDuration:0.45
                     animations:^{
                       self.alpha = 1;
                     }];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (UIView *v in self.subviews)
        if ([v.layer.name isEqualToString:@"shade"])
            for (CALayer *l in v.layer.sublayers)
                l.frame = v.bounds;
}

- (UIButton *)makeButton:(const launcher::Button &)b primary:(BOOL)primary {
    UIButtonConfiguration *c = nil;
    if (@available(iOS 26.0, *))
        c = primary ? [UIButtonConfiguration prominentGlassButtonConfiguration] : [UIButtonConfiguration glassButtonConfiguration];
    else
        c = primary ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration grayButtonConfiguration];
    c.title = ns(b.label);
    c.buttonSize = self.compact ? UIButtonConfigurationSizeMedium : UIButtonConfigurationSizeLarge;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *in) {
      NSMutableDictionary *out = [in mutableCopy];
      const BOOL small = self.compact;
      out[NSFontAttributeName] = [UIFont systemFontOfSize:primary ? (small ? 17 : 19) : (small ? 15 : 16)
                                                   weight:primary ? UIFontWeightSemibold : UIFontWeightMedium];
      return out;
    };
    NSString *symbol = nil;
    switch (b.id) {
    case launcher::kPlay: symbol = @"play.fill"; break;
    case launcher::kImportFolder: symbol = @"folder"; break;
    case launcher::kImportZip: symbol = @"doc.zipper"; break;
    case launcher::kImportIso: symbol = @"opticaldisc"; break;
    case launcher::kManage: symbol = @"slider.horizontal.3"; break;
    case launcher::kImportMenu: symbol = @"opticaldisc"; break;
    case launcher::kExportSaves: symbol = @"square.and.arrow.up"; break;
    case launcher::kImportSaves: symbol = @"square.and.arrow.down"; break;
    case launcher::kDeleteData: symbol = @"trash"; break;
    case launcher::kBack: symbol = @"chevron.backward"; break;
    case launcher::kCancel: symbol = @"xmark"; break;
    case launcher::kOk: symbol = @"checkmark"; break;
    case launcher::kQuit: symbol = @"power"; break;
    default: break;
    }
    if (symbol) {
        c.image = [UIImage systemImageNamed:symbol];
        c.imagePadding = 9;
        c.preferredSymbolConfigurationForImage =
            [UIImageSymbolConfiguration configurationWithPointSize:primary ? 17 : 15 weight:UIImageSymbolWeightSemibold];
    }
    if (primary)
        c.baseBackgroundColor = [UIColor colorWithRed:0.20 green:0.47 blue:1.0 alpha:1.0];
    if (b.id == launcher::kDeleteData || b.id == launcher::kQuit)
        c.baseForegroundColor = b.id == launcher::kDeleteData ? UIColor.systemRedColor : [UIColor colorWithWhite:1 alpha:0.8];
    UIButton *button = [UIButton buttonWithConfiguration:c primaryAction:nil];
    button.enabled = b.enabled;
    button.tag = b.id;
    [button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.heightAnchor constraintEqualToConstant:self.compact ? (primary ? 46 : 36) : (primary ? 56 : 46)].active = YES;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    return button;
}

- (void)tapped:(UIButton *)b {
    if (!self.model)
        return;
    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
    self.model->activate((int)b.tag);
}

- (void)showView:(const launcher::View &)v {
    self.titleLabel.text = ns(v.title);
    // status: an SF Symbol and colour by tone
    NSString *symbol = v.tone == 1 ? @"checkmark.circle.fill" : v.tone == 2 ? @"exclamationmark.triangle.fill"
                                                                            : @"xmark.octagon.fill";
    UIColor *tint = v.tone == 1 ? UIColor.systemGreenColor : v.tone == 2 ? UIColor.systemOrangeColor : UIColor.systemRedColor;
    std::string head = v.headline, detail = v.detail;
    const bool checking = v.screen == launcher::Screen::Importing && v.buttons.empty();
    if (v.screen == launcher::Screen::Importing && !checking) {
        head = "Importing your disc";
        symbol = @"arrow.down.circle.fill";
        tint = UIColor.systemBlueColor;
        detail = "Keep the app open. The disc you had before stays until the new one has been checked.";
    } else if (checking) {
        symbol = @"opticaldisc.fill";
        tint = UIColor.systemBlueColor;
    } else if (v.screen == launcher::Screen::Message) {
        head = "Notice";
        symbol = @"info.circle.fill";
        tint = UIColor.systemBlueColor;
        detail = v.message;
    } else if (v.screen == launcher::Screen::Import) {
        head = "Import again";
        symbol = @"opticaldisc";
        tint = UIColor.systemGrayColor;
        detail = v.detail2;
    } else if (v.screen == launcher::Screen::Manage) {
        head = "Manage";
        symbol = @"slider.horizontal.3";
        tint = UIColor.systemGrayColor;
        detail = v.detail2;
    }
    self.statusIcon.image = [UIImage systemImageNamed:symbol];
    self.statusIcon.tintColor = tint;
    self.statusLabel.text = ns(head);
    self.detailLabel.text = ns(detail);
    self.detailLabel.hidden = detail.empty();

    // progress
    const bool importing = v.screen == launcher::Screen::Importing;
    self.progressCard.hidden = !importing;
    if (importing) {
        const launcher::Progress &p = v.progress;
        const float f = p.bytes_total ? (float)((double)p.bytes_done / (double)p.bytes_total) : 0.0f;
        [self.progress setProgress:f animated:YES];
        self.progressLabel.text =
            p.files_total ? [NSString stringWithFormat:@"%llu of %llu files  ·  %@ of %@\n%@",
                                                       (unsigned long long)p.files_done, (unsigned long long)p.files_total,
                                                       ns(launcher::human_bytes(p.bytes_done)),
                                                       ns(launcher::human_bytes(p.bytes_total)), ns(p.current).lastPathComponent]
                          : @"";
    }

    // buttons: rebuilt when the set changes
    std::vector<std::pair<int, std::string>> want;
    for (const launcher::Button &b : v.buttons)
        want.push_back({b.id, b.label + (b.enabled ? "" : "\x01")});
    if (want != self.shown || (int)v.screen != self.shownScreen) {
        self.shown = want;
        self.shownScreen = (int)v.screen;
        for (UIButton *b in self.buttons)
            [b removeFromSuperview];
        [self.buttons removeAllObjects];
        for (size_t i = 0; i < v.buttons.size(); ++i) {
            const launcher::Button &b = v.buttons[i];
            UIButton *button = [self makeButton:b primary:(b.id == launcher::kPlay || (i == 0 && b.id == launcher::kOk))];
            [self.buttons addObject:button];
            [self.buttonStack addArrangedSubview:button];
            if (b.id == launcher::kQuit || b.id == launcher::kBack)
                [self.buttonStack setCustomSpacing:18 afterView:self.buttons.count > 1 ? self.buttons[self.buttons.count - 2] : button];
        }
        self.focus = -1;
    }
    [self showFocus:v.focus];

    self.lastFocus = v.focus;
    [self refreshHints];
}

// The hints at the bottom, in the connected controller's own glyphs: PlayStation cross / circle in their colours,
// otherwise A / B; a keyboard alone gets Return / Esc. None for touch alone.
- (void)refreshHints {
    const int family = rl_pad_family();
    if (!controller_in_use()) {
        self.hintLabel.hidden = YES;
        return;
    }
    NSMutableAttributedString *h = [NSMutableAttributedString new];
    UIColor *dim = [UIColor colorWithWhite:1 alpha:0.7];
    auto glyph = [&](NSString *name, UIColor *colour, NSString *text) {
        UIImage *img = [[UIImage systemImageNamed:name] imageWithTintColor:colour renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (img)
            [h appendAttributedString:[NSAttributedString attributedStringWithAttachment:[NSTextAttachment textAttachmentWithImage:img]]];
        [h appendAttributedString:[[NSAttributedString alloc] initWithString:text]];
    };
    if (family == 1) {  // PlayStation: cross selects, circle goes back
        glyph(@"xmark.circle.fill", [UIColor colorWithRed:0.49 green:0.69 blue:0.97 alpha:1], @" Select     ");
        glyph(@"circle.circle.fill", [UIColor colorWithRed:0.95 green:0.39 blue:0.43 alpha:1], @" Back     ");
        glyph(@"dpad.fill", dim, @" Move");
    } else if (family == 2) {
        glyph(@"a.circle.fill", dim, @" Select     ");
        glyph(@"b.circle.fill", dim, @" Back     ");
        glyph(@"dpad.fill", dim, @" Move");
    } else {
        glyph(@"return", dim, @" Select     ");
        glyph(@"escape", dim, @" Back     ");
        glyph(@"arrow.up.arrow.down", dim, @" Move");
    }
    self.hintLabel.attributedText = h;
    self.hintLabel.hidden = NO;
}

// A controller connected or went away: its glyphs and the focus ring follow at once.
- (void)controllersChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self refreshHints];
      self.focus = -2;  // force the ring to be re-evaluated
      [self showFocus:self.lastFocus];
    });
}

// The controller's focus: the focused button lifts a little and gets a white ring; none for touch alone.
- (void)showFocus:(int)focus {
    const bool show = controller_in_use();
    if (focus == self.focus && show == (self.focus >= 0) && self.focus != -2)
        return;
    self.focus = show ? focus : -1;
    [UIView animateWithDuration:0.18
                     animations:^{
                       for (NSUInteger i = 0; i < self.buttons.count; ++i) {
                           UIButton *b = self.buttons[i];
                           const bool on = show && (int)i == focus;
                           b.transform = on ? CGAffineTransformMakeScale(1.035, 1.035) : CGAffineTransformIdentity;
                           b.layer.borderWidth = on ? 2.0 : 0.0;
                           b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
                           b.layer.cornerRadius = b.bounds.size.height / 2;
                           b.layer.shadowColor = UIColor.whiteColor.CGColor;
                           b.layer.shadowOpacity = on ? 0.35 : 0.0;
                           b.layer.shadowRadius = 12;
                           b.layer.shadowOffset = CGSizeZero;
                       }
                     }];
}
@end

// The launcher's own window and the pickers it presents.
@interface RecompLauncherController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic) RecompLauncherView *launcherView;
@property(nonatomic) launcher::Launcher *model;
@property(nonatomic) int picking;  // 0 none, 1 game folder, 2 game ZIP, 3 disc image, 4 saves ZIP, 5 export
@end

@implementation RecompLauncherController
- (void)loadView {
    self.launcherView = [[RecompLauncherView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view = self.launcherView;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}
- (BOOL)prefersStatusBarHidden {
    return YES;
}
- (void)presentPicker:(NSArray<UTType *> *)types kind:(int)kind {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                                                    asCopy:NO];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    self.picking = kind;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)exportFile:(NSString *)path {
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ [NSURL fileURLWithPath:path] ] asCopy:YES];
    p.delegate = self;
    self.picking = 5;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    const int kind = self.picking;
    self.picking = 0;
    if (!url || !self.model)
        return;
    if (kind == 5) {
        self.model->show("Saves exported.");
        return;
    }
    const BOOL scoped = [url startAccessingSecurityScopedResource];
    void (^release)(void) = ^{
      if (scoped)
          [url stopAccessingSecurityScopedResource];
    };
    if (kind == 4) {
        self.model->picked_saves(url.path.UTF8String);
        release();
        return;
    }
    self.model->picked(url.path.UTF8String,
                       kind == 2 ? rl::Source::Zip : kind == 3 ? rl::Source::Iso : rl::Source::Folder, release);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.picking = 0;
}
@end

namespace {

class IosPlatform final : public launcher::Platform {
  public:
    RecompLauncherController *controller = nil;
    void pick(rl::Source kind) override {
        switch (kind) {
        case rl::Source::Folder: [controller presentPicker:@[ UTTypeFolder ] kind:1]; break;
        case rl::Source::Zip: [controller presentPicker:@[ UTTypeZIP ] kind:2]; break;
        case rl::Source::Iso: {
            UTType *iso = [UTType typeWithFilenameExtension:@"iso"] ?: UTTypeData;
            [controller presentPicker:@[ iso, UTTypeDiskImage ] kind:3];
            break;
        }
        }
    }
    void pick_saves() override { [controller presentPicker:@[ UTTypeZIP ] kind:4]; }
    void export_file(const std::string &path) override { [controller exportFile:ns(path)]; }
};

// Controllers and a keyboard move the launcher's focus: D-pad or left stick, A/cross selects, B/circle goes back,
// Menu/Options plays the focused button too. Edges only, with a repeat while held.
struct PadPoller {
    bool held[4] = {};
    double next_repeat[4] = {};

    void poll(launcher::Launcher &model) {
        bool up = false, down = false, select = false, back = false;
        for (GCController *c in GCController.controllers) {
            GCExtendedGamepad *p = c.extendedGamepad;
            if (!p)
                continue;
            up |= p.dpad.up.pressed || p.leftThumbstick.yAxis.value > 0.6f;
            down |= p.dpad.down.pressed || p.leftThumbstick.yAxis.value < -0.6f;
            select |= p.buttonA.pressed || p.buttonMenu.pressed;
            back |= p.buttonB.pressed;
        }
        if (GCKeyboardInput *k = GCKeyboard.coalescedKeyboard.keyboardInput) {
            up |= [k buttonForKeyCode:GCKeyCodeUpArrow].pressed;
            down |= [k buttonForKeyCode:GCKeyCodeDownArrow].pressed;
            select |= [k buttonForKeyCode:GCKeyCodeReturnOrEnter].pressed || [k buttonForKeyCode:GCKeyCodeSpacebar].pressed;
            back |= [k buttonForKeyCode:GCKeyCodeEscape].pressed;
        }
        const bool now[4] = {up, down, select, back};
        const launcher::Key keys[4] = {launcher::Key::Up, launcher::Key::Down, launcher::Key::Activate,
                                       launcher::Key::Back};
        const double t = CACurrentMediaTime();
        for (int i = 0; i < 4; ++i) {
            if (now[i] && !held[i]) {
                model.key(keys[i]);
                next_repeat[i] = t + 0.4;
            } else if (now[i] && i < 2 && t >= next_repeat[i]) {
                model.key(keys[i]);
                next_repeat[i] = t + 0.12;
            }
            held[i] = now[i];
        }
    }
};

UIWindowScene *active_scene() {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class])
            return (UIWindowScene *)s;
    return nil;
}

}  // namespace

std::string rl_ios_run_launcher(const std::string &documents, const std::string &bundled_game) {
    @autoreleasepool {
        IosPlatform platform;
        launcher::Launcher model(platform, documents + "/game", bundled_game, documents + "/Saves");
        RecompLauncherController *controller = [RecompLauncherController new];
        controller.model = &model;
        platform.controller = controller;

        UIWindowScene *scene = active_scene();
        UIWindow *window = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                                 : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        window.windowLevel = UIWindowLevelNormal + 1;
        window.rootViewController = controller;
        [window makeKeyAndVisible];
        rl_bubble_attach((__bridge void *)window);  // the controller bubble over the launcher, too
        controller.launcherView.model = &model;
        model.start();

        // The launcher's own loop: UIKit (touches, pickers, animations) runs inside the run loop turns.
        PadPoller pads;
        while (!model.finished()) {
            // As SDL's UIKit_PumpEvents: a timeout above zero, so the run loop reaches its before-waiting observers
            // (where UIKit finishes gesture recognizers: the glass buttons' taps), then the tracking mode.
            SInt32 r;
            do
                r = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.000002, true);
            while (r == kCFRunLoopRunHandledSource);
            do
                r = CFRunLoopRunInMode((CFStringRef)UITrackingRunLoopMode, 0.000002, true);
            while (r == kCFRunLoopRunHandledSource);
            [NSThread sleepForTimeInterval:1.0 / 120.0];
            if (!controller.presentedViewController)
                pads.poll(model);
            if (model.dirty())
                [controller.launcherView showView:model.view()];
            // development: straight into the game once the game checks out
            if (getenv("RL_AUTOPLAY") && model.status().state == rl::State::Ready && !model.dirty())
                model.activate(launcher::kPlay);
        }

        if (model.quit())
            exit(0);  // iOS: nothing else ends the app from the launcher
        // Out of the hierarchy at once: a window over the game's Metal layer makes iOS composite every frame.
        controller.launcherView.model = nullptr;
        window.hidden = YES;
        window.rootViewController = nil;
        return model.status().root;
    }
}
