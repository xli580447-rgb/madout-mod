//
//  UltraMod.mm — MadOut2 21.30  「ULTRA MOD」
//  · 毛玻璃分页面板 + 关闭按钮（点角标可重新打开）
//  · 全部功能走字节 patch（零 hook，非越狱可跑）
//  · 自检角标：红字 → 绿字
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

/* ================= 目标偏移（21.30 US） ================= */
static const uint32_t RVA_MINUS_ONE   = 0x4599508;  // Weapon.Bullets::MinusOne
static const uint32_t RVA_GET_COUNT   = 0x45994A0;  // Weapon.Bullets::get_Count
static const uint32_t RVA_BONE_SHOT   = 0x45924AC;  // IntersectionBone::ProcessShot

static const uint32_t EXP_MINUS_ONE[4] = {0xD10103FFu, 0xA9024FF4u, 0xA9037BFDu, 0x9100C3FDu};
static const uint32_t EXP_GET_COUNT[4] = {0xD10103FFu, 0xA9024FF4u, 0xA9037BFDu, 0x9100C3FDu};
static const uint32_t EXP_BONE_SHOT[4] = {0xD102C3FFu, 0x6D023BEFu, 0x6D0333EDu, 0x6D042BEBu};

#define INSN_RET        0xD65F03C0u
#define INSN_MOV_W0_1   0x52800020u
#define INSN_MOV_W0_0   0x52800000u
#define INSN_MOV_W0_999 0x52807CE0u

/* ================= 全局 ================= */
static uintptr_t gBase = 0;
static bool gReady = false;

struct Slot {
    const char *name;
    uint32_t rva;
    const uint32_t *expect;
    uint32_t words[2];
    int n;
    bool on;
    uint32_t saved[2];
    void *addr;
};
static Slot gMag, gCap, gHit;

static bool make_writable(void *a, size_t l) {
    return vm_protect(mach_task_self(), (vm_address_t)a, l, false,
                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS;
}
static void make_exec(void *a, size_t l) {
    vm_protect(mach_task_self(), (vm_address_t)a, l, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(a, l);
}
static uintptr_t resolve_base(void) {
    if (gBase) return gBase;
    void *s = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    if (!s) {
        void *h = dlopen("@executable_path/Frameworks/UnityFramework.framework/UnityFramework",
                         RTLD_LAZY | RTLD_NOLOAD);
        if (h) s = dlsym(h, "il2cpp_domain_get");
    }
    if (!s) return 0;
    Dl_info i;
    if (dladdr(s, &i) && i.dli_fbase) gBase = (uintptr_t)i.dli_fbase;
    return gBase;
}
static bool slot_init(Slot *s, const char *nm, uint32_t rva, const uint32_t *exp,
                      uint32_t w0, uint32_t w1, int n) {
    s->name = nm; s->rva = rva; s->expect = exp; s->words[0] = w0; s->words[1] = w1; s->n = n;
    s->on = false; s->addr = NULL;
    if (!resolve_base()) return false;
    void *a = (void *)(gBase + rva);
    const uint32_t *cur = (const uint32_t *)a;
    for (int i = 0; i < 4; i++) if (cur[i] != exp[i]) { NSLog(@"[UM] %s 指纹不符", nm); return false; }
    s->addr = a;
    return true;
}
static bool slot_set(Slot *s, bool on) {
    if (!s->addr) return false;
    if (on == s->on) return true;
    if (!make_writable(s->addr, 16)) return false;
    uint32_t *p = (uint32_t *)s->addr;
    if (on) {
        for (int i = 0; i < s->n; i++) { s->saved[i] = p[i]; p[i] = s->words[i]; }
    } else {
        for (int i = 0; i < s->n; i++) p[i] = s->saved[i];
    }
    make_exec(s->addr, 16);
    s->on = on;
    return true;
}

/* ================= 毛玻璃 UI ================= */
static UIView *gHost = nil;
static UILabel *gBadge = nil, *gDiag = nil;
static UIView *gPanel = nil;
static BOOL gVerified = NO;
static void toggle_panel(void);

static int gWinCount = 0;
static NSString *gHostDesc = @"?";

static UIView *host_view(void) {
    UIWindow *best = nil; CGFloat bestA = 0; gWinCount = 0;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            gWinCount++;
            if (w.hidden) continue;
            CGFloat a = w.bounds.size.width * w.bounds.size.height;
            if (w.windowLevel == UIWindowLevelNormal && a > bestA) { best = w; bestA = a; }
        }
    }
    if (!best) best = UIApplication.sharedApplication.keyWindow;
    if (!best) best = UIApplication.sharedApplication.windows.firstObject;
    if (!best) { gHostDesc = @"no window"; return nil; }

    UIView *host = best; CGFloat area = 0;
    NSMutableArray *st = [NSMutableArray arrayWithObject:best];
    while (st.count) {
        UIView *v = st.lastObject; [st removeLastObject];
        CGFloat a = v.bounds.size.width * v.bounds.size.height;
        if (a > area) { area = a; host = v; }
        for (UIView *sv in v.subviews) [st addObject:sv];
    }
    gHostDesc = [NSString stringWithFormat:@"%@ %.0fx%.0f", NSStringFromClass([host class]),
                 host.bounds.size.width, host.bounds.size.height];
    return host;
}

/* --- 开关行 --- */
@interface UMRow : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, copy) void (^handler)(BOOL);
@end
@implementation UMRow {
    UIView *_track; UIView *_knob; UILabel *_lb;
}
- (instancetype)initWithTitle:(NSString *)t note:(NSString *)note y:(CGFloat)y {
    if ((self = [super initWithFrame:CGRectMake(0, y, 250, 40)])) {
        _lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 190, 18)];
        _lb.text = t; _lb.textColor = [UIColor whiteColor]; _lb.font = [UIFont boldSystemFontOfSize:13];
        [self addSubview:_lb];
        if (note.length) {
            UILabel *n = [[UILabel alloc] initWithFrame:CGRectMake(0, 22, 190, 14)];
            n.text = note; n.textColor = [UIColor colorWithWhite:1 alpha:0.55];
            n.font = [UIFont systemFontOfSize:9];
            [self addSubview:n];
        }
        _track = [[UIView alloc] initWithFrame:CGRectMake(196, 9, 46, 24)];
        _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _track.layer.cornerRadius = 12;
        _track.layer.borderWidth = 1;
        _track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        [self addSubview:_track];
        _knob = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 20, 20)];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.layer.cornerRadius = 10;
        [_track addSubview:_knob];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)];
        [self addGestureRecognizer:tap];
    }
    return self;
}
- (void)tap { self.on = !self.on; if (self.handler) self.handler(self.on); }
- (void)setOn:(BOOL)on {
    _on = on;
    [UIView animateWithDuration:0.15 animations:^{
        self->_track.backgroundColor = on ? [UIColor colorWithRed:0.25 green:0.65 blue:1 alpha:1]
                                          : [UIColor colorWithWhite:1 alpha:0.18];
        self->_knob.frame = CGRectMake(on ? 24 : 2, 2, 20, 20);
    }];
}
@end

/* --- 面板 --- */
@interface UMPanel : UIView
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation UMPanel {
    UIScrollView *_scroll;
    UISegmentedControl *_tabs;
    NSArray<UIView *> *_pages;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    CGPoint c = self.center;
    c.x += t.x; c.y += t.y;
    self.center = c;
    [g setTranslation:CGPointZero inView:self.superview];
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.layer.cornerRadius = 16;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 14;
        self.layer.shadowOffset = CGSizeMake(0, 6);
        self.clipsToBounds = NO;

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.frame = self.bounds;
        blur.layer.cornerRadius = 16;
        blur.clipsToBounds = YES;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:blur];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 160, 22)];
        title.text = @"ULTRA MOD";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:15];
        [self addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(f.size.width - 40, 8, 30, 30);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [close addTarget:self action:@selector(doClose) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

        _tabs = [[UISegmentedControl alloc] initWithItems:@[@"基础", @"命中", @"透视", @"关于"]];
        _tabs.frame = CGRectMake(12, 38, f.size.width - 24, 28);
        _tabs.selectedSegmentIndex = 0;
        [_tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_tabs];

        _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 72, f.size.width - 24, f.size.height - 84)];
        _scroll.showsVerticalScrollIndicator = NO;
        [self addSubview:_scroll];

        [self buildPages];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    }
    return self;
}

- (void)doClose { if (self.onClose) self.onClose(); }

- (void)buildPages {
    CGFloat w = _scroll.bounds.size.width;

    /* 基础页 */
    UIView *p0 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 170)];
    UMRow *r1 = [[UMRow alloc] initWithTitle:@"子弹不减" note:@"MinusOne 直接 return（真·无限弹）" y:0];
    r1.handler = ^(BOOL on) { if (!slot_set(&gMag, on)) { NSLog(@"[UM] Mag 失败"); } };
    [p0 addSubview:r1];

    UMRow *r2 = [[UMRow alloc] initWithTitle:@"弹匣容量 999" note:@"只改 HUD 显示上限，不影响真实子弹" y:44];
    r2.handler = ^(BOOL on) { slot_set(&gCap, on); };
    [p0 addSubview:r2];
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, 92, w, 60)];
    tip.numberOfLines = 0;
    tip.text = @"说明：\n·「子弹不减」= 真的不扣弹，能一直打\n·「弹匣容量 999」= 只把界面数字改大，给外观用\n两者可以只开第一个。";
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    tip.font = [UIFont systemFontOfSize:10];
    [p0 addSubview:tip];

    /* 命中页 */
    UIView *p1 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 120)];
    UMRow *r3 = [[UMRow alloc] initWithTitle:@"必中命中" note:@"骨骼命中判定恒为真（很激进）" y:0];
    r3.handler = ^(BOOL on) { slot_set(&gHit, on); };
    [p1 addSubview:r3];

    /* 透视页 */
    UIView *p2 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 100)];
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 80)];
    l2.numberOfLines = 0;
    l2.text = @"透视（方框 / 骨骼）下一版接入。\n当前版本只含字节 patch 功能，\n先确保稳定再叠加绘制。";
    l2.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    l2.font = [UIFont systemFontOfSize:11];
    [p2 addSubview:l2];

    /* 关于页 */
    UIView *p3 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 120)];
    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 110)];
    l3.numberOfLines = 0;
    l3.font = [UIFont systemFontOfSize:10];
    l3.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    l3.text = [NSString stringWithFormat:
               @"ULTRA MOD · MadOut2 21.30\nbase: %@\n子弹不减 %@ · 容量 %@ · 必中 %@\n\n点右上角 ✕ 关闭，点左上角 ULTRA MOD 重新打开。",
               gBase ? [NSString stringWithFormat:@"0x%lx", (unsigned long)gBase] : @"未就绪",
               gMag.addr ? (gMag.on ? @"开" : @"关") : @"✗",
               gCap.addr ? (gCap.on ? @"开" : @"关") : @"✗",
               gHit.addr ? (gHit.on ? @"开" : @"关") : @"✗"];
    [p3 addSubview:l3];

    _pages = @[p0, p1, p2, p3];
    for (UIView *p in _pages) { p.hidden = (p != p0); [_scroll addSubview:p]; }
    _scroll.contentSize = CGSizeMake(w, 180);
}

- (void)tabChanged {
    NSInteger i = _tabs.selectedSegmentIndex;
    for (NSInteger k = 0; k < _pages.count; k++) _pages[k].hidden = (k != i);
}
@end

/* 点角标 = 开关面板 */
@interface UMBadge : UILabel
@end
@implementation UMBadge
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    toggle_panel();
}
@end

/* ================= 挂载 ================= */
static void attach_badge(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gBadge || !gHost) return;
        gBadge = [[UMBadge alloc] initWithFrame:CGRectMake(14, 56, 280, 26)];
        gBadge.text = @"ULTRA MOD · 自检中";
        gBadge.textColor = [UIColor colorWithRed:1 green:0.28 blue:0.28 alpha:1];
        gBadge.font = [UIFont boldSystemFontOfSize:18];
        gBadge.userInteractionEnabled = YES;
        [gHost addSubview:gBadge];

        gDiag = [[UILabel alloc] initWithFrame:CGRectMake(14, 82, 300, 14)];
        gDiag.text = [NSString stringWithFormat:@"W:%d %@", gWinCount, gHostDesc];
        gDiag.textColor = [UIColor colorWithWhite:0.9 alpha:0.85];
        gDiag.font = [UIFont systemFontOfSize:9];
        [gHost addSubview:gDiag];
    });
}

static void show_panel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanel || !gHost) return;
        CGRect b = gHost.bounds;
        UMPanel *p = [[UMPanel alloc] initWithFrame:CGRectMake((b.size.width - 276) / 2, 110, 276, 300)];
        __weak UMPanel *weakP = p;
        p.onClose = ^{ weakP.hidden = YES; };
        [gHost addSubview:p];
        gPanel = p;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!gVerified && gPanel.superview && gPanel.window) {
                gVerified = YES;
                gBadge.text = @"ULTRA MOD";
                gBadge.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.55 alpha:1];
                gDiag.hidden = YES;
            }
        });
    });
}

static void toggle_panel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPanel) { show_panel(); return; }
        gPanel.hidden = !gPanel.hidden;
    });
}

__attribute__((constructor)) static void um_entry(void) {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (int i = 0; i < 40 && !gHost; i++) {
            dispatch_sync(dispatch_get_main_queue(), ^{ if (!gHost) gHost = host_view(); });
            if (!gHost) sleep(1);
        }
        attach_badge();
        sleep(17);

        for (int i = 0; i < 20 && !gBase; i++) { resolve_base(); if (!gBase) sleep(1); }
        slot_init(&gMag, "MinusOne", RVA_MINUS_ONE, EXP_MINUS_ONE, INSN_RET, 0, 1);
        slot_init(&gCap, "GetCount", RVA_GET_COUNT, EXP_GET_COUNT, INSN_MOV_W0_999, INSN_RET, 2);
        slot_init(&gHit, "BoneShot", RVA_BONE_SHOT, EXP_BONE_SHOT, INSN_MOV_W0_1, INSN_RET, 2);
        gReady = true;
        show_panel();
    });
}
