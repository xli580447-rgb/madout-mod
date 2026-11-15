//
//  UltraMod2.mm — MadOut2 21.30  ESP 版
//  只读内存 + 调用游戏函数，不修改任何指令（非越狱安全）
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>
#include <math.h>

typedef struct { float x, y, z; } Vec3;

static inline Vec3 v3sub(Vec3 a, Vec3 b) { Vec3 r = {a.x-b.x, a.y-b.y, a.z-b.z}; return r; }
static inline float v3len(Vec3 a) { return sqrtf(a.x*a.x + a.y*a.y + a.z*a.z); }
static inline float v3dist(Vec3 a, Vec3 b) { return v3len(v3sub(a, b)); }
static inline bool v3sane(Vec3 v) {
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z) &&
           fabsf(v.x) < 1e6f && fabsf(v.y) < 1e6f && fabsf(v.z) < 1e6f;
}

/* ================= il2cpp ================= */
static void *(*f_domain)(void);
static void *(*f_asms)(void *, size_t *);
static void *(*f_asmimg)(void *);
static const char *(*f_imgname)(void *);
static void *(*f_classfrom)(void *, const char *, const char *);
static void *(*f_methfrom)(void *, const char *, int);
static void *(*f_fieldfrom)(void *, const char *);
static void  (*f_fstatic)(void *, void *);
static void *(*f_objclass)(void *);
static bool  (*f_assign)(void *, void *);
static void *(*f_unbox)(void *);
static void *(*f_invoke)(void *, void *, void **, void **);

static void *kPlayer, *kCamera, *kTransform, *kAnimator, *kScreen;
static void *mCurPlayer, *mCamMain, *mW2S, *mGetPos, *mBone, *mScrW, *mScrH;
static void *mAllCams, *mCamCurrent, *mViewM, *mProjM;
static int (*f_arrlen)(void *);
static void (*f_classinit)(void *);
static size_t (*f_fieldoffset)(void *);
static void *(*f_parent)(void *);
static void *fControls;
static int OFF_BODY = 0x194, OFF_LIVE = 0x208, OFF_ANIM = 0x370, OFF_CTRLS_LIST = 0x10;
static bool gIl2 = false;

static void bind_api(void) {
    f_domain   = (void *(*)(void))dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    f_asms     = (void *(*)(void *, size_t *))dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    f_asmimg   = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    f_imgname  = (const char *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_image_get_name");
    f_classfrom= (void *(*)(void *, const char *, const char *))dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    f_methfrom = (void *(*)(void *, const char *, int))dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    f_fieldfrom= (void *(*)(void *, const char *))dlsym(RTLD_DEFAULT, "il2cpp_class_get_field_from_name");
    f_fstatic  = (void (*)(void *, void *))dlsym(RTLD_DEFAULT, "il2cpp_field_static_get_value");
    f_objclass = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_object_get_class");
    f_assign   = (bool (*)(void *, void *))dlsym(RTLD_DEFAULT, "il2cpp_class_is_assignable_from");
    f_unbox    = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_object_unbox");
    f_invoke   = (void *(*)(void *, void *, void **, void **))dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    f_arrlen   = (int (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_array_length");
    f_classinit   = (void (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_runtime_class_init");
    f_fieldoffset = (size_t (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_field_get_offset");
    f_parent      = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_class_get_parent");
}

static void *img_find(const char *n) {
    if (!f_domain) return NULL;
    void *dm = f_domain(); if (!dm) return NULL;
    size_t cnt = 0; void **as = (void **)f_asms(dm, &cnt);
    if (!as) return NULL;
    for (size_t i = 0; i < cnt; i++) {
        void *im = f_asmimg(as[i]);
        const char *s = im ? f_imgname(im) : NULL;
        if (s && strcmp(s, n) == 0) return im;
    }
    return NULL;
}

static void *call0(void *mi, void *self) { return (mi && f_invoke) ? f_invoke(mi, self, NULL, NULL) : NULL; }

/* int 返回值：il2cpp_runtime_invoke 返回的是指向值的指针（或装箱对象） */
static int call_int(void *mi, void *self) {
    void *r = call0(mi, self);
    if (!r) return 0;
    int v = 0;
    memcpy(&v, r, 4);
    if (v <= 0 || v > 20000) {
        if (f_unbox) { void *u = f_unbox(r); if (u) memcpy(&v, u, 4); }
    }
    return v;
}

static bool call_vec3(void *mi, void *self, Vec3 *arg, Vec3 *out) {
    if (!mi || !f_invoke) return false;
    void *params[1]; void *buf = NULL;
    if (arg) { buf = malloc(16); memcpy(buf, arg, 12); params[0] = buf; }
    void *r = f_invoke(mi, self, arg ? params : NULL, NULL);
    if (buf) free(buf);
    if (!r) return false;
    Vec3 v; memcpy(&v, r, 12);
    if (!v3sane(v) && f_unbox) {
        void *u = f_unbox(r);
        if (u) memcpy(&v, u, 12);
    }
    if (!v3sane(v)) return false;
    *out = v;
    return true;
}

static NSString *gCamSrc = @"-";

/* Camera.main 在没打 MainCamera tag 的游戏里是 null，退回 allCameras / current */
static void *resolve_camera(void) {
    void *c = call0(mCamMain, NULL);
    if (c) { gCamSrc = @"main"; return c; }
    if (mAllCams && f_arrlen) {
        void *arr = call0(mAllCams, NULL);
        if (arr) {
            int n = f_arrlen(arr);
            if (n <= 0) { int n2 = *(int *)((char *)arr + 0x18); if (n2 > 0 && n2 < 64) n = n2; }
            for (int i = 0; i < n && i < 64; i++) {
                void *cc = *(void **)((char *)arr + 0x20 + i * 8);
                if (cc) { gCamSrc = [NSString stringWithFormat:@"all[%d/%d]", i, n]; return cc; }
            }
            gCamSrc = [NSString stringWithFormat:@"all0/%d", n];
        }
    }
    void *cur = call0(mCamCurrent, NULL);
    if (cur) { gCamSrc = @"current"; return cur; }
    gCamSrc = @"none";
    return NULL;
}

/* 沿继承链找字段偏移（PlayerControl 的 body_pos/_live/animator 大多在 Control 上） */
static int off_of(void *klass, const char *name) {
    void *k = klass;
    int depth = 0;
    while (k && depth++ < 12) {
        void *f = f_fieldfrom(k, name);
        if (f && f_fieldoffset) {
            size_t off = f_fieldoffset(f);
            if (off < 0x4000) return (int)off;
        }
        k = f_parent ? f_parent(k) : NULL;
    }
    return -1;
}

/* 从 il2cpp_runtime_invoke 拿 Matrix4x4（返回的是指向 64 字节结构的指针） */
static bool get_mat4(void *mi, void *self, float m[16]) {
    if (!mi || !f_invoke) return false;
    void *r = f_invoke(mi, self, NULL, NULL);
    if (!r) return false;
    memcpy(m, r, 64);
    for (int i = 0; i < 16; i++) if (!isfinite(m[i])) return false;
    return true;
}

/* 逆向自 ESP_ProjectWorld：view 取 z/y/x 行，proj 求 w 与 ndc，越界剔除 */
static bool project_manual(const float V[16], const float P[16], Vec3 w,
                           int sw, int sh, Vec3 *out) {
    float zv = V[2]*w.x + V[6]*w.y + V[10]*w.z + V[14];
    if (!isfinite(zv) || zv > -0.01f) return false;       /* 在相机后面 */
    float yv = V[1]*w.x + V[5]*w.y + V[9]*w.z + V[13];
    float xv = V[0]*w.x + V[4]*w.y + V[8]*w.z + V[12];
    float cw = P[3]*xv + P[7]*yv + P[11]*zv + P[15];
    if (!isfinite(cw) || cw <= 0.001f) return false;
    float nx = (P[0]*xv + P[4]*yv + P[8]*zv + P[12]) / cw;
    float ny = (P[1]*xv + P[5]*yv + P[9]*zv + P[13]) / cw;
    if (!isfinite(nx) || !isfinite(ny)) return false;
    if (fabsf(nx) > 1.6f || fabsf(ny) > 1.6f) return false;
    out->x = (nx * 0.5f + 0.5f) * sw;
    out->y = (0.5f - ny * 0.5f) * sh;
    out->z = -zv;
    return true;
}

static void *bone_of(void *anim, int bone) {
    if (!mBone || !anim) return NULL;
    int b = bone; void *params[1] = { &b };
    return f_invoke(mBone, anim, params, NULL);
}

static bool il2_init(void) {
    if (gIl2) return true;
    if (!f_domain) bind_api();
    if (!f_domain) return false;
    void *cs = img_find("Assembly-CSharp.dll");
    if (!cs) return false;
    kPlayer = f_classfrom(cs, "", "PlayerControl");
    if (!kPlayer) return false;
    void *unity = img_find("UnityEngine.CoreModule.dll");
    if (unity) {
        kCamera    = f_classfrom(unity, "UnityEngine", "Camera");
        kTransform = f_classfrom(unity, "UnityEngine", "Transform");
        kAnimator  = f_classfrom(unity, "UnityEngine", "Animator");
        kScreen    = f_classfrom(unity, "UnityEngine", "Screen");
    }
    void *kCtl = f_classfrom(cs, "", "Control");
    if (f_classinit) {                       /* 强制静态构造，controls 才会建好 */
        if (kCtl) f_classinit(kCtl);
        f_classinit(kPlayer);
    }
    fControls = kCtl ? f_fieldfrom(kCtl, "controls") : NULL;
    if (!fControls) fControls = f_fieldfrom(kPlayer, "controls");

    int offA = off_of(kPlayer, "body_pos");
    int offB = off_of(kPlayer, "_live");
    int offC = off_of(kPlayer, "animator");
    if (offA > 0) OFF_BODY = offA;
    if (offB > 0) OFF_LIVE = offB;
    if (offC > 0) OFF_ANIM = offC;
    NSLog(@"[UM] offsets body=0x%x live=0x%x anim=0x%x", OFF_BODY, OFF_LIVE, OFF_ANIM);
    mCurPlayer = f_methfrom(kPlayer, "get_CurrentPlayer", 0);
    kCar = f_classfrom(cs, "", "CarControl");
    if (kCar) mCarCur = f_methfrom(kCar, "get_CurrentCar", 0);
    mAimSet = f_methfrom(kCtl ? kCtl : kPlayer, "SetCamDirByWorldPoint", 1);
    if (kCamera) {
        mCamMain = f_methfrom(kCamera, "get_main", 0);
        mAllCams = f_methfrom(kCamera, "get_allCameras", 0);
        mCamCurrent = f_methfrom(kCamera, "get_current", 0);
        mW2S = f_methfrom(kCamera, "WorldToScreenPoint", 1);
        mViewM = f_methfrom(kCamera, "get_worldToCameraMatrix", 0);
        mProjM = f_methfrom(kCamera, "get_projectionMatrix", 0);
    }
    if (kTransform) mGetPos = f_methfrom(kTransform, "get_position", 0);
    if (kAnimator)  mBone   = f_methfrom(kAnimator, "GetBoneTransform", 1);
    if (kScreen) { mScrW = f_methfrom(kScreen, "get_width", 0); mScrH = f_methfrom(kScreen, "get_height", 0); }
    gIl2 = (mCurPlayer && fControls && mCamMain && mW2S);
    return gIl2;
}

/* ================= 配置 / 全局 ================= */
static BOOL gBox = YES, gSkel = NO, gDist = YES;
static BOOL gCarBox = NO, gAntenna = NO, gFovCircle = NO, gAimOn = NO, gBotOnly = NO;
static float gFovRadius = 120.0f;      /* 准心 FOV 半径（像素） */
static void *kCar = NULL, *mCarCur = NULL;
static void *mAimSet = NULL;           /* Control::SetCamDirByWorldPoint */
static Vec3 gAimTarget; static BOOL gAimHas = NO;
static int gDbgTotal = 0, gDbgDrawn = 0;
static NSString *gDbgText = @"-";
static float gMaxDist = 300.0f;
static BOOL gVerified = NO;
static int gWinCount = 0;
static NSString *gHostDesc = @"?";

static UIView *gHost = nil;
static UIView *gPanel = nil;
static UILabel *gBadge = nil, *gDiag = nil;
static UIView *gEsp = nil;

static const int kPairs[18][2] = {
    {10,9},{9,8},{8,7},{7,0},
    {9,11},{11,13},{13,15},{15,17},
    {9,12},{12,14},{14,16},{16,18},
    {0,1},{1,3},{3,5},{0,2},{2,4},{4,6},
};

/* ================= ESP 视图 ================= */
@interface UMESPView : UIView
@end

@implementation UMESPView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return NO; }
- (void)tick:(CADisplayLink *)link { [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)rect {
    if (!gIl2 || (!gBox && !gSkel)) return;
    CGContextRef cx = UIGraphicsGetCurrentContext();
    if (!cx) return;

    void *lp = call0(mCurPlayer, NULL);
    void *list = NULL;
    if (!lp || !fControls) return;
    f_fstatic(fControls, &list);
    if (!list) return;

    void *items = *(void **)((char *)list + 0x10);
    int n = *(int *)((char *)list + 0x18);
    if (!items || n <= 0 || n > 4096) return;

    int sw = call_int(mScrW, NULL);
    int sh = call_int(mScrH, NULL);
    if (sw <= 0 || sh <= 0) return;

    void *cam = resolve_camera();
    if (!cam) { gDbgText = @"no camera"; return; }

    float V[16], P[16];
    bool haveMat = get_mat4(mViewM, cam, V) && get_mat4(mProjM, cam, P);
    gDbgTotal = n;
    int drawn = 0;

    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    Vec3 origin; memcpy(&origin, (char *)lp + OFF_BODY, 12);

    for (int i = 0; i < n; i++) {
        void *c = *(void **)((char *)items + 0x20 + i * 8);
        if (!c || c == lp) continue;
        if (!f_assign || !f_assign(kPlayer, f_objclass(c))) continue;
        if (*(int *)((char *)c + OFF_LIVE) <= 0) continue;

        Vec3 body; memcpy(&body, (char *)c + OFF_BODY, 12);
        float d = v3dist(origin, body);
        if (d > gMaxDist || d < 1.0f) continue;

        void *anim = *(void **)((char *)c + OFF_ANIM);
        Vec3 head = body, foot = body, tmp;
        head.y += 0.85f; foot.y -= 0.95f;
        void *trH = bone_of(anim, 10);
        void *trF = bone_of(anim, 5);
        if (trH && call_vec3(mGetPos, trH, NULL, &tmp)) head = tmp;
        if (trF && call_vec3(mGetPos, trF, NULL, &tmp)) { tmp.y -= 0.1f; foot = tmp; }

        Vec3 shr, sfo;
        bool ok = false;
        if (haveMat) {
            ok = project_manual(V, P, head, sw, sh, &shr) &&
                 project_manual(V, P, foot, sw, sh, &sfo);
        }
        if (!ok) {
            if (!call_vec3(mW2S, cam, &head, &shr)) continue;
            if (!call_vec3(mW2S, cam, &foot, &sfo)) continue;
            if (shr.z <= 0.1f || sfo.z <= 0.1f) continue;
        }

        CGFloat hx = shr.x / sw * W, hy = (1.0f - shr.y / sh) * H;
        CGFloat fy = (1.0f - sfo.y / sh) * H;
        CGFloat bh = fabs(fy - hy), bw = bh * 0.5f;
        if (bh < 6 || bh > H * 1.6f) continue;

        drawn++;
        if (gBox) {
            CGContextSetLineWidth(cx, 1.6);
            CGContextSetRGBStrokeColor(cx, 1.0, 0.30, 0.30, 1.0);
            CGContextStrokeRect(cx, CGRectMake(hx - bw * 0.5f, hy, bw, bh));
            CGContextSetLineWidth(cx, 1.0);
            CGContextSetRGBStrokeColor(cx, 1, 1, 1, 0.25);
            CGContextMoveToPoint(cx, W * 0.5f, H);
            CGContextAddLineToPoint(cx, hx, fy);
            CGContextStrokePath(cx);
            if (gDist) {
                NSString *t = [NSString stringWithFormat:@"%.0fm", d];
                [t drawAtPoint:CGPointMake(hx - 12, hy - 14)
                withAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:10],
                                 NSForegroundColorAttributeName: [UIColor yellowColor]}];
            }
            if (gAntenna) {
                CGContextSetLineWidth(cx, 1.0);
                CGContextSetRGBStrokeColor(cx, 0.4, 0.9, 1.0, 0.95);
                CGContextMoveToPoint(cx, hx, hy);
                CGContextAddLineToPoint(cx, hx, hy - 40);
                CGContextStrokePath(cx);
                CGContextMoveToPoint(cx, W * 0.5f, 0);
                CGContextAddLineToPoint(cx, hx, hy - 40);
                CGContextStrokePath(cx);
            }
            }
        }
        if (gSkel && anim) {
            CGContextSetLineWidth(cx, 1.2);
            CGContextSetRGBStrokeColor(cx, 0.35, 1.0, 0.55, 0.95);
            for (int k = 0; k < 18; k++) {
                void *ta = bone_of(anim, kPairs[k][0]);
                void *tb = bone_of(anim, kPairs[k][1]);
                Vec3 a, b, sa, sb;
                if (!ta || !tb) continue;
                if (!call_vec3(mGetPos, ta, NULL, &a)) continue;
                if (!call_vec3(mGetPos, tb, NULL, &b)) continue;
                bool oka = haveMat ? project_manual(V, P, a, sw, sh, &sa)
                                   : call_vec3(mW2S, cam, &a, &sa);
                bool okb = haveMat ? project_manual(V, P, b, sw, sh, &sb)
                                   : call_vec3(mW2S, cam, &b, &sb);
                if (!oka || !okb) continue;
                CGContextMoveToPoint(cx, sa.x / sw * W, (1.0f - sa.y / sh) * H);
                CGContextAddLineToPoint(cx, sb.x / sw * W, (1.0f - sb.y / sh) * H);
                CGContextStrokePath(cx);
            }
        }
    }

    /* ---- FOV 圈 ---- */
    if (gFovCircle) {
        CGContextSetLineWidth(cx, 1.2);
        CGContextSetRGBStrokeColor(cx, 1, 1, 1, 0.75);
        CGContextStrokeEllipseInRect(cx, CGRectMake(W/2 - gFovRadius, H/2 - gFovRadius,
                                                    gFovRadius*2, gFovRadius*2));
    }

    /* ---- 车辆方框 ---- */
    if (gCarBox && kCar && f_assign) {
        for (int i = 0; i < n; i++) {
            void *c = *(void **)((char *)items + 0x20 + i * 8);
            if (!c) continue;
            void *oc = f_objclass(c);
            if (f_assign(kPlayer, oc)) continue;          /* 是玩家，跳过 */
            if (!f_assign(kCar, oc)) continue;
            Vec3 body; memcpy(&body, (char *)c + OFF_BODY, 12);
            float d = v3dist(origin, body);
            if (d > gMaxDist || d < 1.0f) continue;
            Vec3 top = body, bot = body;
            top.y += 0.9f; bot.y -= 0.6f;
            Vec3 st, sb;
            bool ok1 = haveMat ? project_manual(V, P, top, sw, sh, &st)
                               : call_vec3(mW2S, cam, &top, &st);
            bool ok2 = haveMat ? project_manual(V, P, bot, sw, sh, &sb)
                               : call_vec3(mW2S, cam, &bot, &sb);
            if (!ok1 || !ok2) continue;
            CGFloat x1 = st.x/sw*W, y1 = (1.0f - st.y/sh)*H;
            CGFloat y2 = (1.0f - sb.y/sh)*H;
            CGFloat hh = fabs(y2-y1), ww = hh*0.7f;
            if (hh < 6 || hh > H*1.6f) continue;
            CGContextSetLineWidth(cx, 1.4);
            CGContextSetRGBStrokeColor(cx, 1.0, 0.62, 0.15, 1.0);
            CGContextStrokeRect(cx, CGRectMake(x1-ww/2, y1, ww, hh));
        }
    }

    gDbgDrawn = drawn;
    gDbgText = [NSString stringWithFormat:@"n=%d drawn=%d sw=%d sh=%d cam=%@ mat=%d", n, drawn, sw, sh, gCamSrc, (int)haveMat];
}
@end

/* ================= 开关行 ================= */
@interface UMRow : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, copy) void (^handler)(BOOL);
@end

@implementation UMRow {
    UIView *_track, *_knob; UILabel *_lb;
}
- (instancetype)initWithTitle:(NSString *)t y:(CGFloat)y {
    if ((self = [super initWithFrame:CGRectMake(0, y, 244, 36)])) {
        _lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, 180, 20)];
        _lb.text = t; _lb.textColor = [UIColor whiteColor]; _lb.font = [UIFont systemFontOfSize:13];
        [self addSubview:_lb];
        _track = [[UIView alloc] initWithFrame:CGRectMake(190, 6, 46, 24)];
        _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _track.layer.cornerRadius = 12;
        [self addSubview:_track];
        _knob = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 20, 20)];
        _knob.backgroundColor = [UIColor whiteColor]; _knob.layer.cornerRadius = 10;
        [_track addSubview:_knob];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)]];
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

/* ================= 面板 ================= */
@interface UMPanel : UIView
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation UMPanel
- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    CGPoint c = self.center; c.x += t.x; c.y += t.y; self.center = c;
    [g setTranslation:CGPointZero inView:self.superview];
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.layer.cornerRadius = 16;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.55;
        self.layer.shadowRadius = 14;
        self.layer.shadowOffset = CGSizeMake(0, 6);

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.frame = self.bounds;
        blur.layer.cornerRadius = 16;
        blur.clipsToBounds = YES;
        [self addSubview:blur];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 160, 22)];
        title.text = @"ULTRA MOD";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:15];
        [self addSubview:title];

        UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
        x.frame = CGRectMake(f.size.width - 42, 6, 34, 30);
        [x setTitle:@"✕" forState:UIControlStateNormal];
        [x setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        x.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [x addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:x];

        /* 页签 */
        UISegmentedControl *tabs = [[UISegmentedControl alloc] initWithItems:@[@"人物", @"车辆", @"瞄准", @"其它"]];
        tabs.frame = CGRectMake(12, 38, f.size.width - 24, 26);
        tabs.selectedSegmentIndex = 0;
        [tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
        tabs.tag = 910;
        [self addSubview:tabs];

        /* 人物页 */
        UIView *pg0 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 170)];
        UMRow *a1 = [[UMRow alloc] initWithTitle:@"人物方框" y:0];
        a1.on = gBox; a1.handler = ^(BOOL v){ gBox = v; [gEsp setNeedsDisplay]; }; [pg0 addSubview:a1];
        UMRow *a2 = [[UMRow alloc] initWithTitle:@"骨骼" y:36];
        a2.on = gSkel; a2.handler = ^(BOOL v){ gSkel = v; [gEsp setNeedsDisplay]; }; [pg0 addSubview:a2];
        UMRow *a3 = [[UMRow alloc] initWithTitle:@"天线" y:72];
        a3.on = gAntenna; a3.handler = ^(BOOL v){ gAntenna = v; [gEsp setNeedsDisplay]; }; [pg0 addSubview:a3];
        UMRow *a4 = [[UMRow alloc] initWithTitle:@"距离显示" y:108];
        a4.on = gDist; a4.handler = ^(BOOL v){ gDist = v; [gEsp setNeedsDisplay]; }; [pg0 addSubview:a4];

        /* 车辆页 */
        UIView *pg1 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 120)];
        UMRow *b1 = [[UMRow alloc] initWithTitle:@"车辆方框" y:0];
        b1.on = gCarBox; b1.handler = ^(BOOL v){ gCarBox = v; [gEsp setNeedsDisplay]; }; [pg1 addSubview:b1];

        /* 瞄准页 */
        UIView *pg2 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 170)];
        UMRow *c1 = [[UMRow alloc] initWithTitle:@"自瞄（追踪）" y:0];
        c1.on = gAimOn; c1.handler = ^(BOOL v){ gAimOn = v; }; [pg2 addSubview:c1];
        UMRow *c2 = [[UMRow alloc] initWithTitle:@"FOV 圈" y:36];
        c2.on = gFovCircle; c2.handler = ^(BOOL v){ gFovCircle = v; [gEsp setNeedsDisplay]; }; [pg2 addSubview:c2];
        UISlider *fov = [[UISlider alloc] initWithFrame:CGRectMake(0, 78, 250, 30)];
        fov.minimumValue = 40; fov.maximumValue = 300; fov.value = gFovRadius;
        fov.continuous = YES;
        [fov addTarget:self action:@selector(fovChanged:) forControlEvents:UIControlEventValueChanged];
        [pg2 addSubview:fov];

        /* 其它页 */
        UIView *pg3 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 120)];
        UMRow *d1 = [[UMRow alloc] initWithTitle:@"防录屏" y:0];
        d1.handler = ^(BOOL v){ [self antiCapture:v]; }; [pg3 addSubview:d1];

        _pages = @[pg0, pg1, pg2, pg3];
        CGRect fb = self.bounds;
        _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(14, 70, fb.size.width - 28, fb.size.height - 84)];
        _scroll.showsVerticalScrollIndicator = NO;
        [self addSubview:_scroll];
        for (UIView *pg in _pages) { pg.hidden = (pg != pg0); [_scroll addSubview:pg]; }
        _scroll.contentSize = CGSizeMake(fb.size.width - 28, 180);

        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    }
    return self;
}
- (void)closeTap { if (self.onClose) self.onClose(); }

- (void)tabChanged:(UISegmentedControl *)s {
    for (NSInteger i = 0; i < (NSInteger)_pages.count; i++) _pages[i].hidden = (i != s.selectedSegmentIndex);
}
- (void)fovChanged:(UISlider *)sl {
    gFovRadius = sl.value;
    [gEsp setNeedsDisplay];
}
- (void)antiCapture:(BOOL)on {
    UIWindow *w = self.window;
    if (!w) return;
    static UITextField *secure = nil;
    if (on && !secure) {
        secure = [[UITextField alloc] initWithFrame:CGRectZero];
        secure.secureTextEntry = YES;
        [w addSubview:secure];
    } else if (!on && secure) {
        [secure removeFromSuperview];
        secure = nil;
    }
}
@end

/* ================= 挂载 ================= */
static void toggle_panel(void);

/* ---- 自瞄：调用游戏自己的 SetCamDirByWorldPoint，不改任何指令 ---- */
static void aim_tick(void) {
    if (!gAimOn || !gIl2 || !mAimSet) return;
    void *lp = call0(mCurPlayer, NULL);
    if (!lp) return;
    void *list = NULL;
    f_fstatic(fControls, &list);
    if (!list) return;
    void *items = *(void **)((char *)list + 0x10);
    int n = *(int *)((char *)list + 0x18);
    if (!items || n <= 0 || n > 4096) return;

    int sw = call_int(mScrW, NULL), sh = call_int(mScrH, NULL);
    if (sw <= 0 || sh <= 0) return;
    void *cam = resolve_camera();
    if (!cam) return;
    float V[16], P[16];
    bool haveMat = get_mat4(mViewM, cam, V) && get_mat4(mProjM, cam, P);

    Vec3 origin; memcpy(&origin, (char *)lp + OFF_BODY, 12);
    float best = gFovRadius;           /* 像素半径 */
    Vec3 bestPos; bool found = false;

    for (int i = 0; i < n; i++) {
        void *c = *(void **)((char *)items + 0x20 + i * 8);
        if (!c || c == lp) continue;
        if (!f_assign(kPlayer, f_objclass(c))) continue;
        if (*(int *)((char *)c + OFF_LIVE) <= 0) continue;
        Vec3 body; memcpy(&body, (char *)c + OFF_BODY, 12);
        if (v3dist(origin, body) > gMaxDist) continue;

        void *anim = *(void **)((char *)c + OFF_ANIM);
        Vec3 head = body; head.y += 0.85f; Vec3 tmp;
        void *trH = bone_of(anim, 10);
        if (trH && call_vec3(mGetPos, trH, NULL, &tmp)) head = tmp;

        Vec3 sp;
        bool ok = haveMat ? project_manual(V, P, head, sw, sh, &sp)
                          : call_vec3(mW2S, cam, &head, &sp);
        if (!ok) continue;
        float px = sp.x / sw * [UIScreen mainScreen].bounds.size.width;
        float py = sp.y / sh * [UIScreen mainScreen].bounds.size.height;
        float d = hypotf(px - [UIScreen mainScreen].bounds.size.width * 0.5f,
                         py - [UIScreen mainScreen].bounds.size.height * 0.5f);
        if (d < best) { best = d; bestPos = head; found = true; }
    }

    gAimHas = found;
    if (found) {
        gAimTarget = bestPos;
        Vec3 arg = bestPos;
        void *params[1] = { &arg };
        f_invoke(mAimSet, lp, params, NULL);
    }
}

@interface UMBadge : UILabel
@end
@implementation UMBadge
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { toggle_panel(); }
@end

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

    UIView *h = best; CGFloat area = 0;
    NSMutableArray *st = [NSMutableArray arrayWithObject:best];
    while (st.count) {
        UIView *v = st.lastObject; [st removeLastObject];
        CGFloat a = v.bounds.size.width * v.bounds.size.height;
        if (a > area) { area = a; h = v; }
        for (UIView *s in v.subviews) [st addObject:s];
    }
    gHostDesc = [NSString stringWithFormat:@"%@ %.0fx%.0f", NSStringFromClass([h class]),
                 h.bounds.size.width, h.bounds.size.height];
    return h;
}

static void attach_all(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gHost) return;

        gEsp = [[UMESPView alloc] initWithFrame:gHost.bounds];
        gEsp.backgroundColor = [UIColor clearColor];
        gEsp.opaque = NO;
        gEsp.userInteractionEnabled = NO;
        [gHost addSubview:gEsp];

        gBadge = [[UMBadge alloc] initWithFrame:CGRectMake(14, 56, 280, 26)];
        gBadge.text = @"ULTRA MOD · 自检中";
        gBadge.textColor = [UIColor colorWithRed:1 green:0.28 blue:0.28 alpha:1];
        gBadge.font = [UIFont boldSystemFontOfSize:18];
        gBadge.userInteractionEnabled = YES;
        [gHost addSubview:gBadge];

        gDiag = [[UILabel alloc] initWithFrame:CGRectMake(14, 82, 320, 14)];
        gDiag.text = [NSString stringWithFormat:@"W:%d %@ il2:%d", gWinCount, gHostDesc, (int)gIl2];
        gDiag.textColor = [UIColor colorWithWhite:0.9 alpha:0.85];
        gDiag.font = [UIFont systemFontOfSize:9];
        [gHost addSubview:gDiag];

        UMPanel *p = [[UMPanel alloc] initWithFrame:CGRectMake((gHost.bounds.size.width - 272) / 2, 110, 272, 220)];
        __weak UMPanel *wp = p;
        p.onClose = ^{ wp.hidden = YES; };
        [gHost addSubview:p];
        gPanel = p;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!gVerified && gPanel.superview && gPanel.window) {
                gVerified = YES;
                gBadge.text = @"ULTRA MOD";
                gBadge.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.55 alpha:1];
                gDiag.hidden = YES;
            }
        });

        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) { aim_tick(); }];

        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:gEsp selector:@selector(tick:)];
        link.preferredFramesPerSecond = 15;
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}

static void toggle_panel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPanel) return;
        gPanel.hidden = !gPanel.hidden;
    });
}

__attribute__((constructor)) static void um_entry(void) {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (int i = 0; i < 40 && !gHost; i++) {
            dispatch_sync(dispatch_get_main_queue(), ^{ if (!gHost) gHost = host_view(); });
            if (!gHost) sleep(1);
        }
        sleep(15);                       /* 让 Unity 先把第一帧跑完 */
        dispatch_sync(dispatch_get_main_queue(), ^{ il2_init(); });
        attach_all();
    });
}
