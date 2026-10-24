// ios_overlay.mm - the iOS settings panel over the game, the controller bubble and the frame-rate pill. Modelled on
// the NFSMW and Hercules iOS ports' panels: Liquid Glass on iOS 26+, opened with L3+R3 on a controller, Cmd+S on a
// keyboard, or a three-finger tap or hold; B (circle) or a tap outside closes it.
//
// The game's frames are watched through the runtime's guest output observer (rex::ui::SetGuestOutputFrameObserver),
// called on the GPU emulation thread once per frame: it counts them for the performance readout, and while the panel
// is open it holds the GPU thread there, which stops the game within a frame (paused).
#include "ios_overlay.h"

#include "ios_launcher.h"

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <SDL3/SDL.h>
#include <mach/mach_time.h>

#include <rex/cvar.h>
#include <rex/host_vblank.h>
#include <rex/logging.h>
#include <rex/ui/presenter.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <mutex>

REXCVAR_DECLARE(bool, present_metalfx);
REXCVAR_DECLARE(bool, present_letterbox);
REXCVAR_DECLARE(bool, present_allow_overscan_cutoff);
REXCVAR_DECLARE(int32_t, present_safe_area_x);
REXCVAR_DECLARE(int32_t, present_safe_area_y);
REXCVAR_DECLARE(int32_t, present_upscale_max_height);

namespace {

NSUserDefaults *defaults() { return NSUserDefaults.standardUserDefaults; }

// The connected controller's family: 1 PlayStation (DualSense, DualShock, Backbone One PlayStation Edition), 2 any
// other.
int controller_kind(GCController *c) {
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

UIVisualEffect *glass_effect(BOOL tinted) {
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *g = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        if (tinted)
            g.tintColor = [UIColor colorWithWhite:0.05 alpha:0.45];  // readable over a busy game
        return g;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
}

void round_corners(UIVisualEffectView *v, CGFloat radius) {
    if (@available(iOS 26.0, *)) {
        v.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:radius]];
    } else {
        v.layer.cornerRadius = radius;
        v.layer.cornerCurve = kCACornerCurveContinuous;
        v.clipsToBounds = YES;
    }
}

// ---- the game's frames (GPU emulation thread) ----------------------------------------------------------------

struct FrameStats {
    double fps = 0;        // frames shown in the last second (presented to the display, as the Metal HUD counts)
    double game_fps = 0;   // frames the game made in it
    double average_ms = 0; // their average frame time
    double worst_ms = 0;   // and the longest one
};

std::mutex g_frames_mutex;
std::condition_variable g_frames_resume;
// The game is held at its next frame while the panel is open or the app is in the background (iOS ends an
// app's GPU work there: VK_ERROR_DEVICE_LOST, "Insufficient Permission").
bool g_paused_panel = false;
bool g_paused_background = false;
bool paused() { return g_paused_panel || g_paused_background; }
uint64_t g_window_start = 0;    // mach time the current one-second window began
uint64_t g_last_frame = 0;
uint32_t g_window_frames = 0;
uint64_t g_window_presented = 0;  // presented frames when the window began
double g_window_worst = 0;
FrameStats g_stats;
std::atomic<bool> g_installed{false};

double mach_ms(uint64_t ticks) {
    static mach_timebase_info_data_t tb = [] {
        mach_timebase_info_data_t t;
        mach_timebase_info(&t);
        return t;
    }();
    return double(ticks) * tb.numer / tb.denom / 1e6;
}

void install_on_main();

void on_guest_frame() {
    std::unique_lock<std::mutex> lock(g_frames_mutex);
    const uint64_t now = mach_absolute_time();
    if (g_last_frame) {
        g_window_worst = std::max(g_window_worst, mach_ms(now - g_last_frame));
        ++g_window_frames;
    }
    if (!g_window_start) {
        g_window_start = now;
        g_window_presented = rex::ui::GetPresentedFrameCount();
    }
    const double window_ms = mach_ms(now - g_window_start);
    if (window_ms >= 1000.0) {
        const uint64_t presented = rex::ui::GetPresentedFrameCount();
        g_stats.fps = (presented - g_window_presented) * 1000.0 / window_ms;
        g_stats.game_fps = g_window_frames * 1000.0 / window_ms;
        g_window_presented = presented;
        g_stats.average_ms = g_window_frames ? window_ms / g_window_frames : 0;
        g_stats.worst_ms = g_window_worst;
        // Every 5 s into the log (Documents/Logs), for comparing builds on the phone.
        static uint32_t seconds = 0;
        if (++seconds % 5 == 0) {
            REXLOG_INFO("[perf] {:.1f} fps shown ({:.1f} by the game), frame {:.1f} ms avg, {:.1f} ms worst, "
                        "thermal {}",
                        g_stats.fps, g_stats.game_fps, g_stats.average_ms, g_stats.worst_ms,
                        int(NSProcessInfo.processInfo.thermalState));
        }
        g_window_start = now;
        g_window_frames = 0;
        g_window_worst = 0;
    }
    if (!g_installed.exchange(true))
        dispatch_async(dispatch_get_main_queue(), ^{
          install_on_main();
        });
    // Paused: hold the GPU thread here; the game waits on it within a frame.
    if (paused()) {
        g_frames_resume.wait(lock, [] { return !paused(); });
        g_last_frame = 0;  // the pause is not a frame time
        g_window_start = mach_absolute_time();
        g_window_frames = 0;
        g_window_worst = 0;
        return;
    }
    g_last_frame = now;
}

FrameStats frame_stats() {
    std::lock_guard<std::mutex> lock(g_frames_mutex);
    return g_stats;
}

void set_paused(bool *reason, bool paused) {
    {
        std::lock_guard<std::mutex> lock(g_frames_mutex);
        *reason = paused;
    }
    g_frames_resume.notify_all();
}

// The output resolution: the height MetalFX upscales the game's picture to (a bilinear stretch does the rest, to the
// screen's own resolution). 0: the screen's own.
const int kOutputSteps[] = {720, 900, 1080, 0};
constexpr int kOutputStepCount = sizeof(kOutputSteps) / sizeof(kOutputSteps[0]);

// How the 16:9 picture meets the screen: 0 Fit (bars at the sides), 1 Zoom (at most 3% cut off the top and bottom:
// the game's own text at the edges stays whole, slim bars at the sides), 2 Fill (the whole screen, up to 10% of the
// top and bottom cut off, where the game's level names and button prompts are), 3 Stretch (the whole screen,
// widened). The safe area is the share of the picture that must stay visible. Read by the presenter at every frame.
// Set when the game renders at the screen's own shape (Native widescreen at launch): a few percent wider than
// the screen, cropped evenly at the sides whatever the picture mode.
bool g_widescreen = false;
// The renderer this launch runs on (rl_ios_gpu_backend), and the default choice: native Metal through Metal 4
// command queues (Metal 3 on devices without), Metal 3 only, or Vulkan through MoltenVK.
NSArray<NSString *> *const kRenderers = @[ @"metal", @"metal3", @"vulkan" ];
NSArray<NSString *> *const kRendererNames = @[ @"Metal 4", @"Metal 3", @"Vulkan" ];
int g_renderer = 0;
NSString *const kDefaultRenderer = @"metal";

int chosen_renderer() {
    const NSUInteger index = [kRenderers indexOfObject:[defaults() stringForKey:@"ios.renderer"] ?: kDefaultRenderer];
    return index == NSNotFound ? 0 : int(index);
}

void apply_picture_fit(int fit) {
    if (g_widescreen) {
        // Already at about the screen's shape: Fit and Zoom show all of it (thin bars where the shapes differ),
        // Fill crops to fill, Stretch fills by widening a few percent.
        REXCVAR_SET(present_letterbox, fit != 3);
        REXCVAR_SET(present_allow_overscan_cutoff, fit == 2);
        REXCVAR_SET(present_safe_area_x, fit == 2 ? 90 : 100);
        REXCVAR_SET(present_safe_area_y, fit == 2 ? 90 : 100);
        return;
    }
    const int safe = fit == 1 ? 94 : fit == 2 ? 80 : 100;
    REXCVAR_SET(present_letterbox, fit != 3);
    REXCVAR_SET(present_allow_overscan_cutoff, fit == 1 || fit == 2);
    REXCVAR_SET(present_safe_area_x, safe);
    REXCVAR_SET(present_safe_area_y, safe);
}

// Sustained performance mode: how far MetalFX upscales the game's picture steps down with the device's
// temperature instead of the chosen output resolution: to the screen's own, 1080p when hot (serious), none when
// very hot (critical: the 720p picture stretched). iPad: the screen's, 1440p, 1080p. (The game itself renders at
// 720p at the least: its resolution is fixed at launch.)
bool sustained() { return [defaults() boolForKey:@"ios.sustained"]; }

// Low power: no upscaling past the game's own 720p and no MetalFX (a plain stretch to the screen), the least
// GPU work per frame, for phones without a vapor chamber or when warm. (The game can't run at 30: its logic is
// tied to its frame rate.)
bool low_power() { return [defaults() boolForKey:@"ios.lowPower"]; }

void apply_metalfx() { REXCVAR_SET(present_metalfx, [defaults() boolForKey:@"ios.metalfx"] && !low_power()); }

int sustained_rows() {
    const bool pad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    const int steps[3] = {0, pad ? 1440 : 1080, pad ? 1080 : 720};
    switch (NSProcessInfo.processInfo.thermalState) {
    case NSProcessInfoThermalStateSerious: return steps[1];
    case NSProcessInfoThermalStateCritical: return steps[2];
    default: return steps[0];
    }
}

int output_rows() {
    if (low_power())
        return 720;
    return sustained() ? sustained_rows() : (int)[defaults() integerForKey:@"ios.outputRows"];
}

// The height the game renders at, chosen at launch (rl_ios_game_rows): what the upscaler starts from.
int g_game_rows = 1080;

// SDL's Metal view in the game's window (its layer is the CAMetalLayer the game presents to).
UIView *metal_view(UIView *v) {
    if ([v.layer isKindOfClass:CAMetalLayer.class])
        return v;
    for (UIView *sub in v.subviews)
        if (UIView *m = metal_view(sub))
            return m;
    return nil;
}

// The output resolution: how far MetalFX upscales the game's picture (the rest is a bilinear stretch). The
// drawable itself stays at the display's resolution: the Metal HUD and the system draw into it at the size they
// expect (a smaller drawable shrank and squashed the HUD).
void apply_output_rows(UIWindow *window) {
    REXCVAR_SET(present_upscale_max_height, output_rows());
    UIView *view = metal_view(window);
    if (!view)
        return;
    UIScreen *screen = window.windowScene.screen ?: UIScreen.mainScreen;
    const CGFloat native = screen.nativeScale;
    if (std::fabs(view.layer.contentsScale - native) < 0.001)
        return;
    view.layer.contentsScale = native;
    view.contentScaleFactor = native;
    [view setNeedsLayout];
    [view layoutIfNeeded];
}

NSString *thermal_text(NSProcessInfoThermalState s) {
    switch (s) {
    case NSProcessInfoThermalStateNominal: return @"Cool";
    case NSProcessInfoThermalStateFair: return @"Warm";
    case NSProcessInfoThermalStateSerious: return @"Hot: the phone may slow down";
    case NSProcessInfoThermalStateCritical: return @"Very hot: the phone is slowing down";
    }
    return @"";
}

}  // namespace

// ---- the controller bubble --------------------------------------------------------------------------------

@interface RLBubble : NSObject
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic) UIVisualEffectView *view;
@property(nonatomic) UIImageView *icon;
@property(nonatomic) UILabel *title;
@property(nonatomic) UILabel *detail;
@property(nonatomic) NSUInteger serial;
@end

@implementation RLBubble

+ (instancetype)shared {
    static RLBubble *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      b = [RLBubble new];
      NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
      [nc addObserver:b selector:@selector(connected:) name:GCControllerDidConnectNotification object:nil];
      [nc addObserver:b selector:@selector(disconnected:) name:GCControllerDidDisconnectNotification object:nil];
    });
    return b;
}

- (void)attach:(UIWindow *)window {
    [self.view removeFromSuperview];
    self.window = window;
    UIVisualEffectView *b = [[UIVisualEffectView alloc] initWithEffect:glass_effect(NO)];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.userInteractionEnabled = NO;
    b.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (@available(iOS 26.0, *))
        b.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    else {
        b.layer.cornerRadius = 28;
        b.clipsToBounds = YES;
    }
    b.alpha = 0;
    self.icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"gamecontroller.fill"]];
    self.icon.tintColor = UIColor.whiteColor;
    self.icon.contentMode = UIViewContentModeScaleAspectFit;
    self.icon.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    self.title = [UILabel new];
    self.title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.title.textColor = UIColor.labelColor;
    self.title.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.detail = [UILabel new];
    self.detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.detail.textColor = UIColor.secondaryLabelColor;
    for (UILabel *l in @[ self.title, self.detail ])
        [l setContentCompressionResistancePriority:UILayoutPriorityRequired - 1 forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ self.title, self.detail ]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 1;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[ self.icon, text ]];
    s.alignment = UIStackViewAlignmentCenter;
    s.spacing = 12;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [b.contentView addSubview:s];
    [window addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:10],
        [b.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [b.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor multiplier:0.6],
        [s.topAnchor constraintEqualToAnchor:b.contentView.topAnchor constant:10],
        [s.bottomAnchor constraintEqualToAnchor:b.contentView.bottomAnchor constant:-10],
        [s.leadingAnchor constraintEqualToAnchor:b.contentView.leadingAnchor constant:18],
        [s.trailingAnchor constraintEqualToAnchor:b.contentView.trailingAnchor constant:-22],
        [self.icon.widthAnchor constraintEqualToConstant:32],
    ]];
    self.view = b;
}

- (void)show:(GCController *)c connected:(BOOL)connected {
    if (!self.view || !self.window)
        return;
    NSString *detail = connected ? @"Connected" : @"Disconnected";
    if (connected) {
        GCDeviceBattery *bat = c.battery;
        if (bat && bat.batteryLevel > 0)
            detail = [NSString stringWithFormat:@"Connected · %d%%", (int)lround(bat.batteryLevel * 100)];
    }
    NSString *symbol = @"gamecontroller.fill";
    const int kind = controller_kind(c);
    if (kind == 1 && [UIImage systemImageNamed:@"playstation.logo"])
        symbol = @"playstation.logo";
    else if (kind == 2 && [c.productCategory isEqualToString:GCProductCategoryXboxOne] &&
             [UIImage systemImageNamed:@"xbox.logo"])
        symbol = @"xbox.logo";
    self.icon.image = [UIImage systemImageNamed:symbol];
    self.icon.tintColor = connected ? UIColor.whiteColor : UIColor.secondaryLabelColor;
    self.title.text = c.vendorName.length ? c.vendorName : @"Controller";
    self.detail.text = detail;
    [self.window bringSubviewToFront:self.view];
    const NSUInteger serial = ++self.serial;
    self.view.transform = CGAffineTransformMakeTranslation(0, -24);
    [UIView animateWithDuration:0.45
                          delay:0
         usingSpringWithDamping:0.75
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                       self.view.alpha = 1;
                       self.view.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (serial != self.serial)
          return;  // a newer bubble is showing
      [UIView animateWithDuration:0.35
                       animations:^{
                         self.view.alpha = 0;
                         self.view.transform = CGAffineTransformMakeTranslation(0, -24);
                       }];
    });
}

- (void)connected:(NSNotification *)note {
    GCController *c = note.object;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self show:c connected:YES];
    });
}

- (void)disconnected:(NSNotification *)note {
    GCController *c = note.object;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self show:c connected:NO];
    });
}
@end

// ---- the panel --------------------------------------------------------------------------------------------

@interface RLOverlay : NSObject
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic) UIView *root;
@property(nonatomic) UISegmentedControl *tabs;
@property(nonatomic) UIScrollView *scroll;
@property(nonatomic) UIStackView *performance;
@property(nonatomic) UIStackView *display;
@property(nonatomic) UISegmentedControl *outputRows;
@property(nonatomic) UISegmentedControl *upscaler;
@property(nonatomic) UISegmentedControl *fit;
@property(nonatomic) UILabel *upscalerNote;
@property(nonatomic) UISegmentedControl *gameRows;
@property(nonatomic) UISwitch *sustainedSwitch;
@property(nonatomic) UISwitch *lowPowerSwitch;
@property(nonatomic) UISwitch *wideSwitch;
@property(nonatomic) UISegmentedControl *prompts;
@property(nonatomic) UILabel *gameRowsNote;
@property(nonatomic) UISegmentedControl *renderer;
@property(nonatomic) UILabel *rendererNote;
@property(nonatomic) UIStackView *controller;
@property(nonatomic) UILabel *fpsValue, *frameValue, *worstValue, *thermalValue;
@property(nonatomic) UISwitch *pillSwitch;
@property(nonatomic) UIVisualEffectView *pill;
@property(nonatomic) UILabel *pillLabel;
@property(nonatomic) NSTimer *poll, *stats;
@property(nonatomic) BOOL comboHeld, shortcutHeld;
@property(nonatomic) BOOL open;
@end

@implementation RLOverlay

- (instancetype)initWithWindow:(UIWindow *)window {
    if (!(self = [super init]))
        return nil;
    _window = window;
    [defaults() registerDefaults:@{@"ios.showFps" : @NO, @"ios.outputRows" : @0, @"ios.metalfx" : @YES, @"ios.picture" : @1,
                                   @"ios.gameRows" : @720, @"ios.sustained" : @NO, @"ios.prompts" : @0,
                                   @"ios.widescreen" : @YES, @"ios.renderer" : kDefaultRenderer,
                                   @"ios.lowPower" : @NO}];
    apply_picture_fit((int)[defaults() integerForKey:@"ios.picture"]);
    apply_output_rows(window);
    apply_metalfx();
    [self buildPanel];
    [self buildPill];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thermalChanged:)
                                               name:NSProcessInfoThermalStateDidChangeNotification
                                             object:nil];
    [self installTriggers];
    [[RLBubble shared] attach:window];
    self.stats = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(refreshStats:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.stats forMode:NSRunLoopCommonModes];
    return self;
}

// ---- building blocks (as the NFSMW and Hercules panels') ----

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont preferredFontForTextStyle:style];
    l.adjustsFontForContentSizeCategory = YES;
    l.textColor = UIColor.labelColor;
    l.numberOfLines = 0;
    [l setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return l;
}

- (UILabel *)note:(NSString *)text {
    UILabel *l = [self label:text style:UIFontTextStyleCaption1];
    l.textColor = UIColor.secondaryLabelColor;
    return l;
}

- (UILabel *)section:(NSString *)title {
    UILabel *l = [self label:title.uppercaseString style:UIFontTextStyleFootnote];
    l.textColor = UIColor.systemOrangeColor;
    return l;
}

// A title (and a note below it) on the left, a control on the right.
- (UIView *)row:(NSString *)title note:(NSString *)note control:(UIView *)control {
    UIView *left = [self label:title style:UIFontTextStyleBody];
    if (note) {
        UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[ left, [self note:note] ]];
        s.axis = UILayoutConstraintAxisVertical;
        s.spacing = 2;
        left = s;
    }
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:control ? @[ left, control ] : @[ left ]];
    s.alignment = UIStackViewAlignmentCenter;
    s.spacing = 16;
    [left setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [left setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    if (control) {
        [control setContentHuggingPriority:UILayoutPriorityDefaultHigh + 1 forAxis:UILayoutConstraintAxisHorizontal];
        [control setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh + 1
                                                 forAxis:UILayoutConstraintAxisHorizontal];
    }
    return s;
}

// A row whose right side is a live value.
- (UIView *)row:(NSString *)title value:(UILabel *__strong *)value {
    UILabel *v = [self label:@"–" style:UIFontTextStyleBody];
    v.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold];
    v.textAlignment = NSTextAlignmentRight;
    *value = v;
    return [self row:title note:nil control:v];
}

- (UIButton *)button:(NSString *)title action:(SEL)action prominent:(BOOL)prominent {
    UIButtonConfiguration *c = prominent ? UIButtonConfiguration.filledButtonConfiguration
                                         : UIButtonConfiguration.grayButtonConfiguration;
    if (@available(iOS 26.0, *))
        c = prominent ? UIButtonConfiguration.prominentGlassButtonConfiguration
                      : UIButtonConfiguration.glassButtonConfiguration;
    c.title = title;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.buttonSize = UIButtonConfigurationSizeSmall;
    if (prominent)
        c.baseBackgroundColor = UIColor.systemOrangeColor;
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIStackView *)column:(NSArray<UIView *> *)views {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 12;
    return s;
}

// ---- the panel ----

- (void)buildPanel {
    UIView *root = [[UIView alloc] initWithFrame:self.window.bounds];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.2];
    root.hidden = YES;
    UITapGestureRecognizer *outside = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapOutside:)];
    outside.cancelsTouchesInView = NO;
    [root addGestureRecognizer:outside];

    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:glass_effect(YES)];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    round_corners(panel, 32);
    [root addSubview:panel];

    self.tabs = [[UISegmentedControl alloc] initWithItems:@[ @"Display", @"Performance", @"Controller" ]];
    self.tabs.selectedSegmentIndex = 0;
    [self.tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    UIButton *done = [self button:@"Done" action:@selector(close) prominent:YES];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ self.tabs, done ]];
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;

    [self buildDisplay];
    [self buildPerformance];
    self.performance.hidden = YES;
    self.controller = [self column:@[]];
    self.controller.hidden = YES;
    UIStackView *body =
        [[UIStackView alloc] initWithArrangedSubviews:@[ self.display, self.performance, self.controller ]];
    body.axis = UILayoutConstraintAxisVertical;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll = [UIScrollView new];
    self.scroll.alwaysBounceVertical = YES;
    [self.scroll addSubview:body];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ header, self.scroll ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 14;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:column];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    NSLayoutConstraint *preferredWidth = [panel.widthAnchor constraintEqualToConstant:620];
    preferredWidth.priority = UILayoutPriorityRequired - 1;
    NSLayoutConstraint *fitHeight = [self.scroll.heightAnchor constraintEqualToAnchor:body.heightAnchor];
    fitHeight.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        preferredWidth,
        [panel.widthAnchor constraintLessThanOrEqualToConstant:620],
        [panel.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-24],
        [panel.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-16],
        fitHeight,
        [column.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:16],
        [column.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16],
        [column.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:20],
        [column.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-20],
        [body.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor],
        [body.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor],
        [body.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor],
        [body.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor],
    ]];
    [self.window addSubview:root];
    self.root = root;
}

- (void)buildDisplay {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger selected = kOutputStepCount - 1;
    for (int i = 0; i < kOutputStepCount; ++i) {
        [titles addObject:kOutputSteps[i] ? [NSString stringWithFormat:@"%dp", kOutputSteps[i]] : @"Screen"];
        if (kOutputSteps[i] == [defaults() integerForKey:@"ios.outputRows"])
            selected = i;
    }
    self.outputRows = [[UISegmentedControl alloc] initWithItems:titles];
    self.outputRows.selectedSegmentIndex = selected;
    [self.outputRows addTarget:self action:@selector(outputRowsChanged:) forControlEvents:UIControlEventValueChanged];
    self.upscaler = [[UISegmentedControl alloc] initWithItems:@[ @"MetalFX", @"Bilinear" ]];
    self.upscaler.selectedSegmentIndex = [defaults() boolForKey:@"ios.metalfx"] ? 0 : 1;
    [self.upscaler addTarget:self action:@selector(upscalerChanged:) forControlEvents:UIControlEventValueChanged];
    self.upscalerNote = [self note:@""];
    self.gameRows = [[UISegmentedControl alloc] initWithItems:@[ @"720p", @"1080p" ]];
    self.gameRows.selectedSegmentIndex = [defaults() integerForKey:@"ios.gameRows"] == 1080 ? 1 : 0;
    [self.gameRows addTarget:self action:@selector(gameRowsChanged:) forControlEvents:UIControlEventValueChanged];
    self.gameRowsNote = [self note:@""];
    self.wideSwitch = [UISwitch new];
    self.wideSwitch.on = [defaults() boolForKey:@"ios.widescreen"];
    self.wideSwitch.onTintColor = UIColor.systemOrangeColor;
    [self.wideSwitch addTarget:self action:@selector(wideChanged:) forControlEvents:UIControlEventValueChanged];
    self.sustainedSwitch = [UISwitch new];
    self.sustainedSwitch.on = sustained();
    self.sustainedSwitch.onTintColor = UIColor.systemOrangeColor;
    [self.sustainedSwitch addTarget:self action:@selector(sustainedChanged:) forControlEvents:UIControlEventValueChanged];
    self.lowPowerSwitch = [UISwitch new];
    self.lowPowerSwitch.on = low_power();
    self.lowPowerSwitch.onTintColor = UIColor.systemOrangeColor;
    [self.lowPowerSwitch addTarget:self action:@selector(lowPowerChanged:) forControlEvents:UIControlEventValueChanged];
    [self refreshPowerControls];
    self.renderer = [[UISegmentedControl alloc] initWithItems:kRendererNames];
    self.renderer.selectedSegmentIndex = chosen_renderer();
    [self.renderer addTarget:self action:@selector(rendererChanged:) forControlEvents:UIControlEventValueChanged];
    self.rendererNote = [self note:@""];
    self.fit = [[UISegmentedControl alloc] initWithItems:@[ @"Fit", @"Zoom", @"Fill", @"Stretch" ]];
    self.fit.selectedSegmentIndex = [defaults() integerForKey:@"ios.picture"];
    [self.fit addTarget:self action:@selector(fitChanged:) forControlEvents:UIControlEventValueChanged];
    self.display = [self column:@[
        [self section:@"Picture"],
        [self row:@"Native widescreen"
             note:@"The game drawn at the display's own shape, its menus and HUD laid out to the edges: more of "
                  @"each level at the sides (above and below on iPad), the whole screen, nothing stretched or cut "
                  @"off. Uses the game's 720p mode. From the next launch of the game."
          control:self.wideSwitch],
        [self row:@"Screen"
             note:@"Fit: the whole picture, bars at the sides. Zoom: nearly the whole display, the game's text "
                  @"kept whole. Fill: the whole display, the top and bottom edges (level names, button prompts) cut "
                  @"off. Stretch: the whole display, widened."
          control:self.fit],
        [self row:@"Game resolution"
             note:@"The resolution the game itself renders at (both are the game's own modes). 720p draws "
                  @"less than half the pixels of 1080p: far less GPU work and heat, with MetalFX upscaling it "
                  @"to the screen."
          control:self.gameRows],
        self.gameRowsNote,
        [self row:@"Renderer"
             note:@"Metal: the Xbox 360 GPU emulated on Metal directly, the native path (less CPU work and "
                  @"heat). Vulkan: through MoltenVK, the earlier builds' path. From the next launch of the game."
          control:self.renderer],
        self.rendererNote,
        [self row:@"Low power"
             note:@"The least GPU work and heat: the game's 720p picture stretched to the screen, no MetalFX. "
                  @"For phones without a vapor chamber (or when warm); the picture is softer."
          control:self.lowPowerSwitch],
        [self row:@"Sustained performance"
             note:UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
                      ? @"MetalFX upscaling steps down by temperature: to the screen, 1440p when hot, 1080p "
                        @"when very hot."
                      : @"MetalFX upscaling steps down by temperature: to the screen, 1080p when hot, off (the "
                        @"720p picture stretched) when very hot."
          control:self.sustainedSwitch],
        [self row:@"Output resolution"
             note:@"How far the upscaler takes the game's picture; a plain stretch does the rest. Lower is "
                  @"less GPU work; Screen upscales all the way to the display's resolution."
          control:self.outputRows],
        [self row:@"Upscaler"
             note:@"How the game's picture is scaled up to the output: MetalFX (sharper) or bilinear."
          control:self.upscaler],
        self.upscalerNote,
    ]];
    [self refreshUpscalerNote];
}

- (void)refreshUpscalerNote {
    const int rows = output_rows();
    UIScreen *screen = self.window.windowScene.screen ?: UIScreen.mainScreen;
    const int screen_rows = (int)std::min(screen.nativeBounds.size.width, screen.nativeBounds.size.height);
    const int out = rows > 0 ? std::min(rows, screen_rows) : screen_rows;
    if (!rex::ui::IsMetalFxUpscalingSupported())
        self.upscalerNote.text = @"MetalFX is not available on this device.";
    else if (out <= g_game_rows)
        self.upscalerNote.text = [NSString stringWithFormat:@"At %dp output there is nothing to upscale.", out];
    else
        self.upscalerNote.text = [NSString stringWithFormat:@"Now: %dp to %dp with %@.", g_game_rows, out,
                                                           REXCVAR_GET(present_metalfx) ? @"MetalFX" : @"bilinear"];
    const int renderer_chosen = chosen_renderer();
    self.rendererNote.text = renderer_chosen == g_renderer
                                 ? [NSString stringWithFormat:@"Now running on %@.", kRendererNames[g_renderer]]
                                 : [NSString stringWithFormat:@"Now %@; %@ from the next launch of the game.",
                                                              kRendererNames[g_renderer],
                                                              kRendererNames[renderer_chosen]];
    const int chosen = (int)[defaults() integerForKey:@"ios.gameRows"] == 1080 ? 1080 : 720;
    self.gameRowsNote.text = chosen == g_game_rows
                                 ? [NSString stringWithFormat:@"Now rendering at %dp.", g_game_rows]
                                 : [NSString stringWithFormat:@"Now %dp; %dp from the next launch of the game.",
                                                              g_game_rows, chosen];
}

- (void)rendererChanged:(UISegmentedControl *)s {
    [defaults() setObject:kRenderers[s.selectedSegmentIndex] forKey:@"ios.renderer"];
    [self refreshUpscalerNote];
}

- (void)wideChanged:(UISwitch *)s {
    [defaults() setBool:s.on forKey:@"ios.widescreen"];
}

- (void)refreshPowerControls {
    self.sustainedSwitch.enabled = !low_power();
    self.outputRows.enabled = !low_power() && !sustained();
    self.upscaler.enabled = !low_power();
}

- (void)lowPowerChanged:(UISwitch *)s {
    [defaults() setBool:s.on forKey:@"ios.lowPower"];
    apply_metalfx();
    apply_output_rows(self.window);
    [self refreshPowerControls];
    [self refreshUpscalerNote];
}

- (void)sustainedChanged:(UISwitch *)s {
    [defaults() setBool:s.on forKey:@"ios.sustained"];
    [self refreshPowerControls];
    apply_output_rows(self.window);
    [self refreshUpscalerNote];
}

- (void)thermalChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!sustained())
          return;
      REXLOG_INFO("Sustained performance: thermal state {}, output {}p",
                  int(NSProcessInfo.processInfo.thermalState), sustained_rows());
      apply_output_rows(self.window);
      [self refreshUpscalerNote];
    });
}

- (void)promptsChanged:(UISegmentedControl *)s {
    [defaults() setInteger:s.selectedSegmentIndex forKey:@"ios.prompts"];
}

- (void)gameRowsChanged:(UISegmentedControl *)s {
    [defaults() setInteger:s.selectedSegmentIndex == 1 ? 1080 : 720 forKey:@"ios.gameRows"];
    [self refreshUpscalerNote];
}

- (void)fitChanged:(UISegmentedControl *)s {
    [defaults() setInteger:s.selectedSegmentIndex forKey:@"ios.picture"];
    apply_picture_fit((int)s.selectedSegmentIndex);
}

- (void)upscalerChanged:(UISegmentedControl *)s {
    [defaults() setBool:s.selectedSegmentIndex == 0 forKey:@"ios.metalfx"];
    apply_metalfx();
    [self refreshUpscalerNote];
}

- (void)outputRowsChanged:(UISegmentedControl *)s {
    [defaults() setInteger:kOutputSteps[s.selectedSegmentIndex] forKey:@"ios.outputRows"];
    apply_output_rows(self.window);
    [self refreshUpscalerNote];
}

- (void)buildPerformance {
    UILabel *fps, *frame, *worst, *thermal;
    UIView *fpsRow = [self row:@"Frame rate" value:&fps];
    UIView *frameRow = [self row:@"Frame time (average)" value:&frame];
    UIView *worstRow = [self row:@"Longest frame" value:&worst];
    UIView *thermalRow = [self row:@"Phone temperature" value:&thermal];
    self.fpsValue = fps;
    self.frameValue = frame;
    self.worstValue = worst;
    self.thermalValue = thermal;
    self.pillSwitch = [UISwitch new];
    self.pillSwitch.on = [defaults() boolForKey:@"ios.showFps"];
    self.pillSwitch.onTintColor = UIColor.systemOrangeColor;
    [self.pillSwitch addTarget:self action:@selector(pillChanged:) forControlEvents:UIControlEventValueChanged];
    self.performance = [self column:@[
        [self section:@"While playing"],
        fpsRow,
        frameRow,
        worstRow,
        thermalRow,
        [self note:@"Measured over the last second of play, before the panel opened. The game runs at 60 fps on "
                   @"Xbox 360 (16.7 ms a frame)."],
        [self section:@"Frame rate counter"],
        [self row:@"Show over the game" note:@"A small counter in the corner while you play." control:self.pillSwitch],
    ]];
}

// The counter over the game: frames per second and the frame time, top left.
- (void)buildPill {
    UIVisualEffectView *p = [[UIVisualEffectView alloc] initWithEffect:glass_effect(YES)];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    p.userInteractionEnabled = NO;
    p.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (@available(iOS 26.0, *))
        p.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    else {
        p.layer.cornerRadius = 16;
        p.clipsToBounds = YES;
    }
    self.pillLabel = [UILabel new];
    self.pillLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    self.pillLabel.textColor = UIColor.whiteColor;
    self.pillLabel.text = @"– fps";
    self.pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [p.contentView addSubview:self.pillLabel];
    [self.window addSubview:p];
    UILayoutGuide *safe = self.window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [p.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [p.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.pillLabel.topAnchor constraintEqualToAnchor:p.contentView.topAnchor constant:6],
        [self.pillLabel.bottomAnchor constraintEqualToAnchor:p.contentView.bottomAnchor constant:-6],
        [self.pillLabel.leadingAnchor constraintEqualToAnchor:p.contentView.leadingAnchor constant:12],
        [self.pillLabel.trailingAnchor constraintEqualToAnchor:p.contentView.trailingAnchor constant:-12],
    ]];
    p.hidden = ![defaults() boolForKey:@"ios.showFps"];
    self.pill = p;
}

- (void)refreshStats:(NSTimer *)t {
    const FrameStats s = frame_stats();
    if (!self.pill.hidden && !self.open)
        self.pillLabel.text = s.fps > 0 ? [NSString stringWithFormat:@"%.0f fps · %.1f ms", s.fps, s.average_ms] : @"– fps";
    if (!self.open)
        return;
    if (s.fps > 0) {
        self.fpsValue.text = [NSString stringWithFormat:@"%.0f fps", s.fps];
        self.fpsValue.textColor = s.fps >= 57 ? UIColor.systemGreenColor
                                  : s.fps >= 45 ? UIColor.systemYellowColor
                                                : UIColor.systemOrangeColor;
        self.frameValue.text = [NSString stringWithFormat:@"%.1f ms", s.average_ms];
        self.worstValue.text = [NSString stringWithFormat:@"%.1f ms", s.worst_ms];
    }
    self.thermalValue.text = thermal_text(NSProcessInfo.processInfo.thermalState);
}

- (void)pillChanged:(UISwitch *)s {
    [defaults() setBool:s.on forKey:@"ios.showFps"];
    self.pill.hidden = !s.on;
}

// The connected controller as a card: its family's logo, its name, and its own button glyphs (cross and circle on a
// DualSense or a Backbone One PlayStation Edition, A and B on an Xbox-style pad).
- (UIView *)controllerCard:(GCController *)c {
    const int kind = controller_kind(c);
    NSString *logo = kind == 1 ? @"playstation.logo"
                     : [c.productCategory containsString:@"Xbox"] ? @"xbox.logo" : @"gamecontroller.fill";
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:logo]
                                                              ?: [UIImage systemImageNamed:@"gamecontroller.fill"]];
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:30];
    [icon.widthAnchor constraintEqualToConstant:44].active = YES;
    [icon.heightAnchor constraintEqualToConstant:44].active = YES;
    NSString *detail = kind == 1 ? @"PlayStation buttons" : @"Xbox buttons";
    GCDeviceBattery *bat = c.battery;
    if (bat && bat.batteryLevel > 0)
        detail = [NSString stringWithFormat:@"%@ · battery %d%%", detail, (int)lround(bat.batteryLevel * 100)];
    UIStackView *glyphs = [UIStackView new];
    glyphs.spacing = 8;
    GCExtendedGamepad *pad = c.extendedGamepad;
    if (pad) {
        NSArray<GCControllerElement *> *els = @[
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY, pad.leftShoulder, pad.rightShoulder, pad.leftTrigger,
            pad.rightTrigger, pad.buttonOptions ?: pad.buttonMenu, pad.buttonMenu
        ];
        NSArray<UIColor *> *ps = @[
            [UIColor colorWithRed:0.49 green:0.69 blue:1 alpha:1], [UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1],
            [UIColor colorWithRed:1 green:0.5 blue:0.78 alpha:1], [UIColor colorWithRed:0.25 green:0.89 blue:0.63 alpha:1]
        ];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSUInteger i = 0; i < els.count; ++i) {
            NSString *name = els[i].sfSymbolsName;
            if (!name || [seen containsObject:name])
                continue;
            [seen addObject:name];
            UIImageView *g = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name]];
            g.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:20];
            g.tintColor = kind == 1 && i < 4 ? ps[i] : [UIColor colorWithWhite:1 alpha:0.85];
            [glyphs addArrangedSubview:g];
        }
    }
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self label:c.vendorName ?: @"Controller" style:UIFontTextStyleHeadline], [self note:detail], glyphs
    ]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 4;
    text.alignment = UIStackViewAlignmentLeading;
    UIStackView *card = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, text ]];
    card.alignment = UIStackViewAlignmentCenter;
    card.spacing = 14;
    return card;
}

- (void)buildController {
    for (UIView *v in self.controller.arrangedSubviews)
        [v removeFromSuperview];
    [self.controller addArrangedSubview:[self section:@"Controller"]];
    if (GCController.controllers.count == 0)
        [self.controller addArrangedSubview:[self row:@"No controller connected"
                                                 note:@"Pair one in Settings > General > Game Controller, or plug "
                                                      @"in your Backbone One."
                                              control:nil]];
    for (GCController *c in GCController.controllers)
        [self.controller addArrangedSubview:[self controllerCard:c]];
    if (!self.prompts) {
        self.prompts = [[UISegmentedControl alloc] initWithItems:@[ @"Auto", @"Xbox", @"PlayStation" ]];
        [self.prompts addTarget:self action:@selector(promptsChanged:) forControlEvents:UIControlEventValueChanged];
    }
    self.prompts.selectedSegmentIndex = [defaults() integerForKey:@"ios.prompts"];
    [self.controller addArrangedSubview:[self row:@"Button prompts"
                                             note:@"The buttons the game shows. Auto: PlayStation for a DualSense, "
                                                  @"DualShock or Backbone PlayStation Edition, Xbox otherwise. From "
                                                  @"the next launch of the game."
                                          control:self.prompts]];
    [self.controller addArrangedSubview:[self section:@"Shortcuts"]];
    [self.controller addArrangedSubview:[self row:@"This panel"
                                             note:@"L3 + R3, a three-finger tap, or Cmd+S on a keyboard. B (circle) "
                                                  @"closes it."
                                          control:nil]];
    [self.controller addArrangedSubview:[self row:@"The game's own menu"
                                             note:@"Start (Options on a DualSense)."
                                          control:nil]];
}

- (void)tabChanged:(UISegmentedControl *)s {
    self.display.hidden = s.selectedSegmentIndex != 0;
    self.performance.hidden = s.selectedSegmentIndex != 1;
    self.controller.hidden = s.selectedSegmentIndex != 2;
    if (s.selectedSegmentIndex == 2)
        [self buildController];
}

// ---- opening and closing ----

- (void)tapOutside:(UITapGestureRecognizer *)g {
    if ([self.root hitTest:[g locationInView:self.root] withEvent:nil] == self.root)
        [self close];
}

- (void)show {
    if (self.open)
        return;
    self.open = YES;
    [self refreshStats:nil];  // the readout as the game left it
    set_paused(&g_paused_panel, true);
    [self.window bringSubviewToFront:self.root];
    self.root.hidden = NO;
    if (self.tabs.selectedSegmentIndex == 2)
        [self buildController];
}

- (void)close {
    if (!self.open)
        return;
    self.root.hidden = YES;
    self.open = NO;
    set_paused(&g_paused_panel, false);
}

- (void)toggle {
    self.open ? [self close] : [self show];
}

- (void)installTriggers {
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)];
    hold.numberOfTouchesRequired = 3;
    hold.minimumPressDuration = 0.6;
    hold.cancelsTouchesInView = YES;
    [self.window addGestureRecognizer:hold];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped3:)];
    tap.numberOfTouchesRequired = 3;
    tap.cancelsTouchesInView = YES;
    [tap requireGestureRecognizerToFail:hold];
    [self.window addGestureRecognizer:tap];
    // Controllers and the keyboard are polled, not observed: SDL owns their change handlers.
    self.poll = [NSTimer timerWithTimeInterval:1.0 / 30 target:self selector:@selector(pollInputs:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.poll forMode:NSRunLoopCommonModes];
}

- (void)tapped3:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized)
        [self toggle];
}

- (void)held:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan)
        [self toggle];
}

- (void)pollInputs:(NSTimer *)t {
    // L3+R3 on any controller: an edge, so holding both toggles once.
    BOOL combo = NO;
    for (GCController *c in GCController.controllers) {
        GCExtendedGamepad *pad = c.extendedGamepad;
        if (pad && pad.leftThumbstickButton.isPressed && pad.rightThumbstickButton.isPressed)
            combo = YES;
    }
    if (combo && !self.comboHeld)
        [self toggle];
    self.comboHeld = combo;
    BOOL shortcut = NO;
    if (GCKeyboardInput *k = GCKeyboard.coalescedKeyboard.keyboardInput) {
        const BOOL cmd = [k buttonForKeyCode:GCKeyCodeLeftGUI].isPressed || [k buttonForKeyCode:GCKeyCodeRightGUI].isPressed;
        shortcut = cmd && [k buttonForKeyCode:GCKeyCodeKeyS].isPressed;
    }
    if (shortcut && !self.shortcutHeld)
        [self toggle];
    self.shortcutHeld = shortcut;
    // B / circle closes, as in a system sheet.
    if (self.open)
        for (GCController *c in GCController.controllers)
            if (c.extendedGamepad.buttonB.isPressed) {
                [self close];
                break;
            }
}
@end

// ---------------------------------------------------------------------------

namespace {
RLOverlay *g_overlay;

UIWindow *game_window() {
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    UIWindow *w = nil;
    if (windows && count > 0)
        w = (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(windows[0]),
                                                       SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
    SDL_free(windows);
    return w;
}

void install_on_main() {
    UIWindow *w = game_window();
    if (!w) {
        g_installed = false;  // try again at the next frame
        return;
    }
    g_overlay = [[RLOverlay alloc] initWithWindow:w];
    // development: the panel without a controller (Simulator screenshots), after RL_OPEN_PANEL seconds
    if (const char *e = getenv("RL_OPEN_PANEL")) {
        RLOverlay *o = g_overlay;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(e) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          [o show];
        });
    }
}
}  // namespace

const char *rl_ios_gpu_backend(void) {
    [defaults() registerDefaults:@{@"ios.renderer" : kDefaultRenderer}];
    g_renderer = chosen_renderer();
    return g_renderer == 2 ? "vulkan" : "metal";
}

bool rl_ios_metal4(void) {
    return g_renderer == 0;
}

double rl_ios_widescreen_aspect(void) {
    [defaults() registerDefaults:@{@"ios.widescreen" : @YES}];
    if (![defaults() boolForKey:@"ios.widescreen"])
        return 0;
    g_widescreen = true;
    const CGSize s = UIScreen.mainScreen.nativeBounds.size;
    return std::max(s.width, s.height) / std::max(1.0, std::min(s.width, s.height));
}

bool rl_ios_playstation_prompts(void) {
    [defaults() registerDefaults:@{@"ios.prompts" : @0}];
    const NSInteger choice = [defaults() integerForKey:@"ios.prompts"];
    return choice == 2 || (choice == 0 && rl_pad_family() == 1);
}

const char *rl_ios_help_pad(void) {
    for (GCController *c in GCController.controllers) {
        if ([c.productCategory isEqualToString:GCProductCategoryDualSense] ||
            [c.extendedGamepad isKindOfClass:GCDualSenseGamepad.class])
            return "dualsense";
    }
    return "backbone";
}

int rl_ios_game_rows(void) {
    [defaults() registerDefaults:@{@"ios.gameRows" : @720}];
    g_game_rows = [defaults() integerForKey:@"ios.gameRows"] == 1080 ? 1080 : 720;
    return g_game_rows;
}

// The display's refreshes, as the game's vblank: a display link at 60 Hz on a thread of its own (the main thread
// may be busy with the game's window), each refresh signalled to the vblank thread.
@interface RLVblankSource : NSObject
@end

@implementation RLVblankSource

+ (void)start {
    static RLVblankSource *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      source = [RLVblankSource new];
      NSThread *thread = [[NSThread alloc] initWithBlock:^{
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:source selector:@selector(refresh:)];
        link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
        [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        rex::SetHostVblankSource(true);
        while (true)
            @autoreleasepool {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
            }
      }];
      thread.name = @"Display vblank";
      thread.qualityOfService = NSQualityOfServiceUserInteractive;
      [thread start];
    });
}

- (void)refresh:(CADisplayLink *)link {
    rex::SignalHostVblank();
}

@end

void rl_ios_overlay_start(void) {
    rex::ui::SetGuestOutputFrameObserver(&on_guest_frame);
    [RLVblankSource start];
    // In the background the game waits at its next frame, before any GPU work.
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationWillResignActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *) {
                  set_paused(&g_paused_background, true);
                }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *) {
                  set_paused(&g_paused_background, false);
                }];
}

void rl_bubble_attach(void *uiwindow) { [[RLBubble shared] attach:(__bridge UIWindow *)uiwindow]; }
