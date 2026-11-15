//
//  PatchMod.mm — MadOut2 21.30 纯字节补丁版（零 hook、零 trampoline）
//
//  只做三件事：
//    1) 无限弹匣      Weapon.Bullets::MinusOne      -> ret
//    2) 弹匣容量 999  Weapon.Bullets::get_Count     -> mov w0,#999 ; ret
//    3) 必中命中      IntersectionBone::ProcessShot -> mov w0,#1   ; ret
//
//  原理：mach_vm_protect(VM_PROT_COPY) 拿到写权限 → 改指令 → 改回 r-x。
//  不申请可执行内存，不挂跳转，所以在非越狱 iOS 18 上不会踩执行权限的坑。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#include <string.h>
#include <unistd.h>

/* ---------------- 目标 ---------------- */
static const uint32_t RVA_MINUS_ONE   = 0x4599508;   // Weapon.Bullets::MinusOne
static const uint32_t RVA_GET_COUNT   = 0x45994A0;   // Weapon.Bullets::get_Count
static const uint32_t RVA_BONE_SHOT   = 0x45924AC;   // IntersectionBone::ProcessShot

static const uint32_t EXP_MINUS_ONE[4] = {0xD10103FFu, 0xA9024FF4u, 0xA9037BFDu, 0x9100C3FDu};
static const uint32_t EXP_GET_COUNT[4] = {0xD10103FFu, 0xA9024FF4u, 0xA9037BFDu, 0x9100C3FDu};
static const uint32_t EXP_BONE_SHOT[4] = {0xD102C3FFu, 0x6D023BEFu, 0x6D0333EDu, 0x6D042BEBu};

/* 补丁内容 */
#define INSN_RET        0xD65F03C0u
#define INSN_MOV_W0_1   0x52800020u          /* mov w0, #1   */
#define INSN_MOV_W0_999 0x52807CE0u          /* mov w0, #999 */

/* ---------------- 状态 ---------------- */
static uintptr_t gBase = 0;
static bool gReady = false;
static NSString *gStatus = @"初始化…";

struct PatchSlot {
    const char *name;
    uint32_t rva;
    const uint32_t *expect;
    uint32_t words[2];
    int wordCount;
    bool applied;
    uint32_t saved[2];
    void *addr;
};
static PatchSlot gMag, gCap, gHit;

/* ---------------- 内存写 ---------------- */
static bool make_writable(void *addr, size_t len) {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)addr, len, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}
static void make_exec(void *addr, size_t len) {
    vm_protect(mach_task_self(), (vm_address_t)addr, len, false,
               VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(addr, len);
}

static uintptr_t resolve_base(void) {
    if (gBase) return gBase;
    void *sym = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    if (!sym) {
        void *h = dlopen("@executable_path/Frameworks/UnityFramework.framework/UnityFramework",
                         RTLD_LAZY | RTLD_NOLOAD);
        if (h) sym = dlsym(h, "il2cpp_domain_get");
    }
    if (!sym) return 0;
    Dl_info info;
    if (dladdr(sym, &info) && info.dli_fbase) gBase = (uintptr_t)info.dli_fbase;
    return gBase;
}

static bool slot_init(PatchSlot *s, const char *name, uint32_t rva, const uint32_t *expect,
                      uint32_t w0, uint32_t w1, int count) {
    s->name = name; s->rva = rva; s->expect = expect;
    s->words[0] = w0; s->words[1] = w1; s->wordCount = count;
    s->applied = false; s->addr = NULL;
    if (!resolve_base()) return false;
    s->addr = (void *)(gBase + rva);
    const uint32_t *cur = (const uint32_t *)s->addr;
    for (int i = 0; i < 4; i++) {
        if (cur[i] != expect[i]) {
            NSLog(@"[PM] %s 序言不匹配 (0x%08x != 0x%08x)", name, cur[i], expect[i]);
            s->addr = NULL;
            return false;
        }
    }
    return true;
}

static bool slot_apply(PatchSlot *s) {
    if (!s->addr || s->applied) return false;
    if (!make_writable(s->addr, 16)) return false;
    uint32_t *p = (uint32_t *)s->addr;
    for (int i = 0; i < s->wordCount; i++) s->saved[i] = p[i];
    for (int i = 0; i < s->wordCount; i++) p[i] = s->words[i];
    make_exec(s->addr, 16);
    s->applied = true;
    NSLog(@"[PM] %s 开启", s->name);
    return true;
}

static bool slot_restore(PatchSlot *s) {
    if (!s->addr || !s->applied) return false;
    if (!make_writable(s->addr, 16)) return false;
    uint32_t *p = (uint32_t *)s->addr;
    for (int i = 0; i < s->wordCount; i++) p[i] = s->saved[i];
    make_exec(s->addr, 16);
    s->applied = false;
    NSLog(@"[PM] %s 关闭", s->name);
    return true;
}

/* ---------------- UI ---------------- */
static UILabel *gStatusLabel = nil;

static void refresh_status(void) {
    gStatus = [NSString stringWithFormat:@"base: %@\n弹匣 %@ · 容量 %@ · 必中 %@",
               gBase ? [NSString stringWithFormat:@"0x%lx", (unsigned long)gBase] : @"未就绪",
               gMag.addr ? (gMag.applied ? @"开" : @"关") : @"✗",
               gCap.addr ? (gCap.applied ? @"开" : @"关") : @"✗",
               gHit.addr ? (gHit.applied ? @"开" : @"关") : @"✗"];
    dispatch_async(dispatch_get_main_queue(), ^{ if (gStatusLabel) gStatusLabel.text = gStatus; });
}

@interface PMSwitch : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, copy) void (^handler)(BOOL);
- (instancetype)initWithTitle:(NSString *)title y:(CGFloat)y;
@end

@implementation PMSwitch {
    UILabel *_label;
    UIView *_track;
    UIView *_knob;
}

- (instancetype)initWithTitle:(NSString *)title y:(CGFloat)y {
    if ((self = [super initWithFrame:CGRectMake(0, y, 260, 40)])) {
        _label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 190, 40)];
        _label.text = title;
        _label.textColor = [UIColor whiteColor];
        _label.font = [UIFont systemFontOfSize:14];
        [self addSubview:_label];

        _track = [[UIView alloc] initWithFrame:CGRectMake(200, 8, 46, 24)];
        _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _track.layer.cornerRadius = 12;
        [self addSubview:_track];

        _knob = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 20, 20)];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.layer.cornerRadius = 10;
        [_track addSubview:_knob];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)onTap {
    self.on = !self.on;
    if (self.handler) self.handler(self.on);
}

- (void)setOn:(BOOL)on {
    _on = on;
    [UIView animateWithDuration:0.15 animations:^{
        self->_track.backgroundColor = on ? [UIColor colorWithRed:0.18 green:0.62 blue:1 alpha:1]
                                          : [UIColor colorWithWhite:1 alpha:0.18];
        self->_knob.frame = CGRectMake(on ? 24 : 2, 2, 20, 20);
    }];
}

@end

@interface PMPanel : UIView
@end

@implementation PMPanel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:1].CGColor;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 220, 22)];
        title.text = @"MadOut2 · Patch 版";
        title.textColor = [UIColor colorWithRed:0.35 green:0.85 blue:1 alpha:1];
        title.font = [UIFont boldSystemFontOfSize:15];
        [self addSubview:title];

        PMSwitch *s1 = [[PMSwitch alloc] initWithTitle:@"无限弹匣" y:40];
        s1.handler = ^(BOOL on) {
            if (on) { if (!slot_apply(&gMag)) { s1.on = NO; } }
            else slot_restore(&gMag);
            refresh_status();
        };
        [self addSubview:s1];

        PMSwitch *s2 = [[PMSwitch alloc] initWithTitle:@"弹匣容量 999" y:84];
        s2.handler = ^(BOOL on) {
            if (on) { if (!slot_apply(&gCap)) { s2.on = NO; } }
            else slot_restore(&gCap);
            refresh_status();
        };
        [self addSubview:s2];

        PMSwitch *s3 = [[PMSwitch alloc] initWithTitle:@"必中命中" y:128];
        s3.handler = ^(BOOL on) {
            if (on) { if (!slot_apply(&gHit)) { s3.on = NO; } }
            else slot_restore(&gHit);
            refresh_status();
        };
        [self addSubview:s3];

        gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 172, 240, 56)];
        gStatusLabel.numberOfLines = 0;
        gStatusLabel.font = [UIFont systemFontOfSize:10];
        gStatusLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1];
        gStatusLabel.text = gStatus;
        [self addSubview:gStatusLabel];
    }
    return self;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.superview];
}

@end

/* 只有面板区域接收触摸，其余位置全部透传给游戏 */
@interface PMWindow : UIWindow
@property (nonatomic, weak) UIView *panelView;
@end

@implementation PMWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    if (self.panelView) {
        CGPoint p = [self convertPoint:point toView:self.panelView];
        if (![self.panelView pointInside:p withEvent:event]) return nil;
    } else {
        return nil;   /* 面板还没出来 → 整窗不拦触摸 */
    }
    return v;
}
@end

/* 不再自建 UIWindow —— 直接把面板塞进游戏自己的窗口里，
   这样不会抢 key、不会挡触摸、也不会和 Scene 打架 */
static int gWinCount = 0;
static NSString *gHostDesc = @"?";

static UIView *pm_host_view(void) {
    UIWindow *bestWin = nil;
    CGFloat bestArea = 0;
    gWinCount = 0;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            gWinCount++;
            if (w.hidden) continue;
            CGFloat a = w.bounds.size.width * w.bounds.size.height;
            if (w.windowLevel == UIWindowLevelNormal && a > bestArea) { bestWin = w; bestArea = a; }
        }
    }
    if (!bestWin) bestWin = UIApplication.sharedApplication.keyWindow;
    if (!bestWin) bestWin = UIApplication.sharedApplication.windows.firstObject;
    if (!bestWin) { gHostDesc = @"no window"; return nil; }

    /* 在 window 的整棵子树里找面积最大的 view —— Unity 的渲染视图不一定挂在 rootVC.view 上 */
    UIView *host = bestWin;
    CGFloat area = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:bestWin];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        CGFloat a = v.bounds.size.width * v.bounds.size.height;
        if (a > area) { area = a; host = v; }
        for (UIView *sv in v.subviews) [stack addObject:sv];
    }
    gHostDesc = [NSString stringWithFormat:@"%@ %.0fx%.0f sub=%lu",
                 NSStringFromClass([host class]), host.bounds.size.width, host.bounds.size.height,
                 (unsigned long)host.subviews.count];
    return host;
}

static UIView *gHostView = nil;
static UILabel *gBadge = nil;
static PMPanel *gPanel = nil;

static void pm_attach_badge(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gBadge) return;
        UIView *host = gHostView;
        if (!host) return;
        gBadge = [[UILabel alloc] initWithFrame:CGRectMake(12, 60, 240, 18)];
        gBadge.text = [NSString stringWithFormat:@"PM ok W:%d %@", gWinCount, gHostDesc];
        gBadge.textColor = [UIColor colorWithRed:0.4 green:1 blue:0.6 alpha:1];
        gBadge.font = [UIFont boldSystemFontOfSize:12];
        gBadge.userInteractionEnabled = NO;
        [host addSubview:gBadge];
        NSLog(@"[PM] badge 挂到 %@", host);
    });
}

static void pm_attach_panel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanel) return;
        UIView *host = gHostView;
        if (!host) return;
        CGRect f = host.bounds;
        CGFloat x = (f.size.width - 268) / 2;
        gPanel = [[PMPanel alloc] initWithFrame:CGRectMake(x, 120, 268, 240)];
        [gPanel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gPanel action:@selector(pan:)]];
        [host addSubview:gPanel];
        NSLog(@"[PM] 面板挂到 %@", host);
    });
}

__attribute__((constructor)) static void pm_entry(void) {
    /* 前 20 秒完全不动作，避免拖慢 Unity 启动被看门狗杀 */
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (int i = 0; i < 40 && !gHostView; i++) {
            dispatch_sync(dispatch_get_main_queue(), ^{ if (!gHostView) gHostView = pm_host_view(); });
            if (!gHostView) sleep(1);
        }
        pm_attach_badge();
        sleep(17);
        for (int i = 0; i < 30 && !gBase; i++) { resolve_base(); if (!gBase) sleep(1); }
        bool a = slot_init(&gMag, "MinusOne", RVA_MINUS_ONE, EXP_MINUS_ONE, INSN_RET, 0, 1);
        bool b = slot_init(&gCap, "GetCount", RVA_GET_COUNT, EXP_GET_COUNT, INSN_MOV_W0_999, INSN_RET, 2);
        bool c = slot_init(&gHit, "BoneShot", RVA_BONE_SHOT, EXP_BONE_SHOT, INSN_MOV_W0_1, INSN_RET, 2);
        gReady = true;
        NSLog(@"[PM] 就绪 base=%p 槽位 %d%d%d", (void *)gBase, a, b, c);
        refresh_status();
        pm_attach_panel();
    });
}
