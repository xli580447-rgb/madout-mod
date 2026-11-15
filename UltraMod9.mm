//
//  UltraMod3.mm — MadOut2 21.30  ULTRA MOD
//  非越狱安全：只读内存 + 调游戏函数（不改一行指令）
//  功能：人物方框/骨骼/天线/距离、车辆方框、FOV 圈、自瞄、防录屏
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
static inline bool v3ok(Vec3 v) {
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z) &&
           fabsf(v.x) < 1e6f && fabsf(v.y) < 1e6f && fabsf(v.z) < 1e6f;
}

/* ================= il2cpp ================= */
static void *(*A_domain)(void);
static void *(*A_asms)(void *, size_t *);
static void *(*A_asmimg)(void *);
static const char *(*A_imgname)(void *);
static void *(*A_class)(void *, const char *, const char *);
static void *(*A_meth)(void *, const char *, int);
static void *(*A_field)(void *, const char *);
static void  (*A_fstatic)(void *, void *);
static void *(*A_objclass)(void *);
static bool  (*A_assign)(void *, void *);
static void *(*A_unbox)(void *);
static void *(*A_invoke)(void *, void *, void **, void **);
static void  (*A_classinit)(void *);
static size_t (*A_foffset)(void *);
static void *(*A_parent)(void *);
static int   (*A_arrlen)(void *);
static void *(*A_classtype)(void *);
static void *(*A_typeobj)(void *);
static const char *(*A_classname)(void *);
static size_t (*A_imgclasscount)(void *);
static void *(*A_imgclass)(void *, size_t);

/* 类/方法 */
static void *kPlayer, *kControl, *kCar, *kCamera, *kTransform, *kAnimator, *kScreen;
static void *mCurPlayer, *mCurCar, *mCamMain, *mCamAll, *mCamCur;
static void *mW2S, *mViewM, *mProjM, *mGetPos, *mBone, *mScrW, *mScrH, *mAimSet;
static void *fControls;
static void *kObject, *mFindOfType, *mFindOfTypeAll, *mResFind, *kPlayerType, *kCarType;
static int OFF_BODY = 0x194, OFF_LIVE = 0x208, OFF_ANIM = 0x370;
static bool gIl2 = false;

static void bind_api(void) {
    A_domain  = (void *(*)(void))dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    A_asms    = (void *(*)(void *, size_t *))dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    A_asmimg  = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    A_imgname = (const char *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_image_get_name");
    A_class   = (void *(*)(void *, const char *, const char *))dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    A_meth    = (void *(*)(void *, const char *, int))dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    A_field   = (void *(*)(void *, const char *))dlsym(RTLD_DEFAULT, "il2cpp_class_get_field_from_name");
    A_fstatic = (void (*)(void *, void *))dlsym(RTLD_DEFAULT, "il2cpp_field_static_get_value");
    A_objclass= (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_object_get_class");
    A_assign  = (bool (*)(void *, void *))dlsym(RTLD_DEFAULT, "il2cpp_class_is_assignable_from");
    A_unbox   = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_object_unbox");
    A_invoke  = (void *(*)(void *, void *, void **, void **))dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    A_classinit = (void (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_runtime_class_init");
    A_foffset = (size_t (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_field_get_offset");
    A_parent  = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_class_get_parent");
    A_arrlen  = (int (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_array_length");
    A_classtype = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_class_get_type");
    A_typeobj   = (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_type_get_object");
    A_classname = (const char *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    A_imgclasscount = (size_t (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
    A_imgclass  = (void *(*)(void *, size_t))dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
}

/* 在整个程序集里按短类名找类，忽略命名空间 —— 命名空间猜错也能命中 */
static void *class_by_name(void *img, const char *name) {
    if (!img || !A_imgclasscount || !A_imgclass || !A_classname) return NULL;
    size_t cnt = A_imgclasscount(img);
    for (size_t i = 0; i < cnt; i++) {
        void *k = A_imgclass(img, i);
        const char *cn = k ? A_classname(k) : NULL;
        if (cn && strcmp(cn, name) == 0) return k;
    }
    return NULL;
}

static void *img_find(const char *n) {
    if (!A_domain) return NULL;
    void *dm = A_domain(); if (!dm) return NULL;
    size_t c = 0; void **as = (void **)A_asms(dm, &c);
    if (!as) return NULL;
    for (size_t i = 0; i < c; i++) {
        void *im = A_asmimg(as[i]);
        const char *s = im ? A_imgname(im) : NULL;
        if (s && strcmp(s, n) == 0) return im;
    }
    return NULL;
}

static void *call0(void *mi, void *self) { return (mi && A_invoke) ? A_invoke(mi, self, NULL, NULL) : NULL; }

static int call_int(void *mi, void *self) {
    void *r = call0(mi, self);
    if (!r) return 0;
    int v = 0; memcpy(&v, r, 4);
    if (v <= 0 || v > 20000) { if (A_unbox) { void *u = A_unbox(r); if (u) memcpy(&v, u, 4); } }
    return v;
}

static bool call_vec3(void *mi, void *self, Vec3 *arg, Vec3 *out) {
    if (!mi || !A_invoke) return false;
    void *params[1]; void *buf = NULL;
    if (arg) { buf = malloc(16); memcpy(buf, arg, 12); params[0] = buf; }
    void *r = A_invoke(mi, self, arg ? params : NULL, NULL);
    if (buf) free(buf);
    if (!r) return false;
    Vec3 v; memcpy(&v, r, 12);
    if (!v3ok(v) && A_unbox) { void *u = A_unbox(r); if (u) memcpy(&v, u, 12); }
    if (!v3ok(v)) return false;
    *out = v;
    return true;
}

static int gMatPath = 0;   /* 0=未读 1=直接 2=解箱 */

/* Matrix4x4 是值类型：il2cpp 可能返回原始数据，也可能返回装箱对象（前 8 字节是 klass 指针） */
static bool get_mat4(void *mi, void *self, float m[16]) {
    if (!mi || !A_invoke) return false;
    void *r = A_invoke(mi, self, NULL, NULL);
    if (!r) return false;

    /* 先按原始数据处理 */
    memcpy(m, r, 64);
    int okFloat = 0;
    for (int i = 0; i < 16; i++) if (isfinite(m[i]) && fabsf(m[i]) < 1e7f) okFloat++;
    if (okFloat >= 14) { gMatPath = 1; return true; }

    /* 再按装箱处理：跳过 16 字节对象头 */
    memcpy(m, (char *)r + 0x10, 64);
    okFloat = 0;
    for (int i = 0; i < 16; i++) if (isfinite(m[i]) && fabsf(m[i]) < 1e7f) okFloat++;
    if (okFloat >= 14) { gMatPath = 2; return true; }

    /* 走 unbox */
    if (A_unbox) {
        void *u = A_unbox(r);
        if (u) {
            memcpy(m, u, 64);
            okFloat = 0;
            for (int i = 0; i < 16; i++) if (isfinite(m[i]) && fabsf(m[i]) < 1e7f) okFloat++;
            if (okFloat >= 14) { gMatPath = 3; return true; }
        }
    }
    return false;
}

static void *bone_of(void *anim, int b) {
    if (!mBone || !anim) return NULL;
    int v = b; void *p[1] = { &v };
    return A_invoke(mBone, anim, p, NULL);
}

static int off_of(void *klass, const char *name) {
    void *k = klass; int d = 0;
    while (k && d++ < 12) {
        void *f = A_field(k, name);
        if (f && A_foffset) {
            size_t off = A_foffset(f);
            if (off < 0x4000) return (int)off;
        }
        k = A_parent ? A_parent(k) : NULL;
    }
    return -1;
}

static bool il2_init(void) {
    if (gIl2) return true;
    if (!A_domain) bind_api();
    if (!A_domain) return false;
    void *cs = img_find("Assembly-CSharp.dll");
    if (!cs) return false;

    /* 候选类名 + 候选命名空间，逐个试，谁先命中用谁 */
    const char *nsList[] = {"", "Game", "MadOut", "Scripts", "Player", "Game.Player"};
    const char *playerNames[] = {"PlayerControl", "Player", "PlayerController", "PersonControl"};
    const char *ctlNames[]    = {"Control", "PlayerBase", "BaseControl"};
    const char *carNames[]    = {"CarControl", "VehicleControl", "Car", "Vehicle"};

    void *best = NULL;
    for (int i = 0; i < 6 && !best; i++)
        for (int j = 0; j < 4 && !best; j++) {
            void *k = A_class(cs, nsList[i], playerNames[j]);
            if (k) { best = k; NSLog(@"[UM] PlayerControl via ns='%s' name='%s'", nsList[i], playerNames[j]); }
        }
    if (!best) best = class_by_name(cs, "PlayerControl");
    if (!best) best = class_by_name(cs, "Player");
    kPlayer = best;

    void *kctl = NULL;
    for (int j = 0; j < 3 && !kctl; j++) kctl = A_class(cs, "", ctlNames[j]);
    if (!kctl) kctl = class_by_name(cs, "Control");
    kControl = kctl;

    void *kcar = NULL;
    for (int j = 0; j < 4 && !kcar; j++) kcar = A_class(cs, "", carNames[j]);
    if (!kcar) kcar = class_by_name(cs, "CarControl");
    kCar = kcar;

    /* 父类兜底：PlayerControl 的父类就是 Control */
    if (!kControl && kPlayer && A_parent) kControl = A_parent(kPlayer);
    if (!kPlayer) return false;
    NSLog(@"[UM] classes player=%p control=%p car=%p", kPlayer, kControl, kCar);

    void *unity = img_find("UnityEngine.CoreModule.dll");
    if (unity) {
        kCamera    = A_class(unity, "UnityEngine", "Camera");
        kTransform = A_class(unity, "UnityEngine", "Transform");
        kAnimator  = A_class(unity, "UnityEngine", "Animator");
        kScreen    = A_class(unity, "UnityEngine", "Screen");
    }

    if (A_classinit) {
        if (kControl) A_classinit(kControl);
        A_classinit(kPlayer);
        if (kCar) A_classinit(kCar);
    }

    mCurPlayer = A_meth(kPlayer, "get_CurrentPlayer", 0);
    if (kCar) mCurCar = A_meth(kCar, "get_CurrentCar", 0);
    fControls = kControl ? A_field(kControl, "controls") : NULL;
    if (!fControls) fControls = A_field(kPlayer, "controls");
    if (kControl) mAimSet = A_meth(kControl, "SetCamDirByWorldPoint", 1);
    if (!mAimSet) mAimSet = A_meth(kPlayer, "SetCamDirByWorldPoint", 1);
    if (!mAimSet && kControl) mAimSet = A_meth(kControl, "SetCamDirByVector", 1);
    NSLog(@"[UM] aim method = %p", mAimSet);

    if (kCamera) {
        mCamMain = A_meth(kCamera, "get_main", 0);
        mCamAll  = A_meth(kCamera, "get_allCameras", 0);
        mCamCur  = A_meth(kCamera, "get_current", 0);
        mW2S     = A_meth(kCamera, "WorldToScreenPoint", 1);
        mViewM   = A_meth(kCamera, "get_worldToCameraMatrix", 0);
        mProjM   = A_meth(kCamera, "get_projectionMatrix", 0);
    }
    if (unity) {
        kObject = A_class(unity, "UnityEngine", "Object");
        if (kObject) {
            mFindOfType    = A_meth(kObject, "FindObjectsOfType", 1);
            mFindOfTypeAll = A_meth(kObject, "FindObjectsOfTypeAll", 1);
        }
        void *kRes = A_class(unity, "UnityEngine", "Resources");
        if (kRes) mResFind = A_meth(kRes, "FindObjectsOfTypeAll", 1);
    }
    if (A_classtype && A_typeobj) {
        kPlayerType = A_typeobj(A_classtype(kPlayer));
        if (kCar) kCarType = A_typeobj(A_classtype(kCar));
    }
    NSLog(@"[UM] find=%p type=%p", mFindOfType ?: mFindOfTypeAll, kPlayerType);

    if (kTransform) mGetPos = A_meth(kTransform, "get_position", 0);
    if (kAnimator)  mBone   = A_meth(kAnimator, "GetBoneTransform", 1);
    if (kScreen) { mScrW = A_meth(kScreen, "get_width", 0); mScrH = A_meth(kScreen, "get_height", 0); }

    int a = off_of(kPlayer, "body_pos");
    int b = off_of(kPlayer, "_live");
    int c = off_of(kPlayer, "animator");
    if (a > 0) OFF_BODY = a;
    if (b > 0) OFF_LIVE = b;
    if (c > 0) OFF_ANIM = c;

    gIl2 = (mCurPlayer && fControls && mW2S);
    NSLog(@"[UM] il2=%d body=0x%x live=0x%x anim=0x%x", (int)gIl2, OFF_BODY, OFF_LIVE, OFF_ANIM);
    return gIl2;
}

/* ================= 配置 ================= */
static BOOL gBox = YES, gSkel = NO, gAntenna = NO, gDist = YES;
static BOOL gCarBox = NO, gFovCircle = NO, gAimOn = NO;
static float gMaxDist = 300.0f, gFovRadius = 120.0f;

static NSString *gCamSrc = @"-";
#define UM_MAX_OBJ 512
static void *gObjs[UM_MAX_OBJ];
static int gObjCount = 0;
static NSString *gSrcText = @"-";

static void push_obj(void *c) {
    if (!c || gObjCount >= UM_MAX_OBJ) return;
    gObjs[gObjCount++] = c;
}

static int gStrategy = 0;          /* 上一次成功的枚举方式 */
static NSString *gTried = @"-";

static int try_list(void) {
    gObjCount = 0;
    /* Control.controls 静态列表 */
    void *list = NULL;
    if (fControls) A_fstatic(fControls, &list);
    if (list) {
        void *items = *(void **)((char *)list + 0x10);
        int n = *(int *)((char *)list + 0x18);
        if (items && n > 0 && n < 8192) {
            for (int i = 0; i < n; i++) push_obj(*(void **)((char *)items + 0x20 + i * 8));
        }
    }
    return gObjCount;
}

static int try_find(void *mi) {
    gObjCount = 0;
    if (!mi || !kPlayerType || !A_invoke) return 0;
    void *params[1] = { kPlayerType };
    void *arr = A_invoke(mi, NULL, params, NULL);
    if (!arr) return 0;
    int n = A_arrlen ? A_arrlen(arr) : *(int *)((char *)arr + 0x18);
    if (n <= 0 || n > 8192) return 0;
    for (int i = 0; i < n; i++) push_obj(*(void **)((char *)arr + 0x20 + i * 8));
    return gObjCount;
}

/* 多路合并：静态列表 + FindObjectsOfType + FindObjectsOfTypeAll + Resources，去重后一起用 */
static bool obj_seen(void *c) {
    for (int i = 0; i < gObjCount; i++) if (gObjs[i] == c) return true;
    return false;
}

static void push_unique(void *c) {
    if (!c || gObjCount >= UM_MAX_OBJ || obj_seen(c)) return;
    gObjs[gObjCount++] = c;
}

static int collect_from_list(void) {
    void *list = NULL;
    if (!fControls) return 0;
    A_fstatic(fControls, &list);
    if (!list) return 0;
    void *items = *(void **)((char *)list + 0x10);
    int n = *(int *)((char *)list + 0x18);
    if (!items || n <= 0 || n > 8192) return 0;
    int before = gObjCount;
    for (int i = 0; i < n; i++) push_unique(*(void **)((char *)items + 0x20 + i * 8));
    return gObjCount - before;
}

static int collect_from_find(void *mi, void *type) {
    if (!mi || !type || !A_invoke) return 0;
    void *params[1] = { type };
    void *arr = A_invoke(mi, NULL, params, NULL);
    if (!arr) return 0;
    int n = A_arrlen ? A_arrlen(arr) : *(int *)((char *)arr + 0x18);
    if (n <= 0 || n > 8192) return 0;
    int before = gObjCount;
    for (int i = 0; i < n; i++) push_unique(*(void **)((char *)arr + 0x20 + i * 8));
    return gObjCount - before;
}

static int collect_objects(void) {
    gObjCount = 0;
    int fromList = collect_from_list();
    int fromFind = collect_from_find(mFindOfType, kPlayerType);
    int fromAll  = collect_from_find(mFindOfTypeAll, kPlayerType);
    int fromRes  = collect_from_find(mResFind, kPlayerType);
    gSrcText = [NSString stringWithFormat:@"L%d F%d A%d R%d", fromList, fromFind, fromAll, fromRes];
    return gObjCount;
}

static void *resolve_camera(void) {
    void *c = call0(mCamMain, NULL);
    if (c) { gCamSrc = @"main"; return c; }
    if (mCamAll && A_arrlen) {
        void *arr = call0(mCamAll, NULL);
        if (arr) {
            int n = A_arrlen(arr);
            if (n <= 0) { n = *(int *)((char *)arr + 0x18); }
            for (int i = 0; i < n && i < 64; i++) {
                void *cc = *(void **)((char *)arr + 0x20 + i * 8);
                if (cc) { gCamSrc = [NSString stringWithFormat:@"all[%d/%d]", i, n]; return cc; }
            }
        }
    }
    void *cu = call0(mCamCur, NULL);
    if (cu) { gCamSrc = @"current"; return cu; }
    /* 最后一招：找场景里任意一个 Camera 实例 */
    void *mi = mFindOfType ? mFindOfType : mFindOfTypeAll;
    if (mi && kCamera && A_typeobj && A_classtype) {
        void *t = A_typeobj(A_classtype(kCamera));
        void *params[1] = { t };
        void *arr = A_invoke(mi, NULL, params, NULL);
        if (arr) {
            int n = A_arrlen ? A_arrlen(arr) : 0;
            if (n > 0) {
                void *c2 = *(void **)((char *)arr + 0x20);
                if (c2) { gCamSrc = @"find"; return c2; }
            }
        }
    }
    gCamSrc = @"none";
    return NULL;
}

/* 投影：4 种约定全试（z 正/负向前 × y 正/负向上），任一命中即用
   逆向自 A_nokey 的 ESP_ProjectWorld，但去掉了它对符号的硬编码假设 */
static int gProjMode = -1;   /* 记住成功的约定 */

static bool project_one(const float V[16], const float P[16], Vec3 w,
                        int sw, int sh, int zSign, int ySign, Vec3 *o) {
    float zv = V[2]*w.x + V[6]*w.y + V[10]*w.z + V[14];
    if (zSign > 0) zv = -zv;
    float yv = V[1]*w.x + V[5]*w.y + V[9]*w.z + V[13];
    float xv = V[0]*w.x + V[4]*w.y + V[8]*w.z + V[12];

    float cw = P[3]*xv + P[7]*yv + P[11]*zv + P[15];
    if (!isfinite(cw) || cw <= 0.001f) return false;

    float nx = (P[0]*xv + P[4]*yv + P[8]*zv + P[12]) / cw;
    float ny = (P[1]*xv + P[5]*yv + P[9]*zv + P[13]) / cw;
    if (!isfinite(nx) || !isfinite(ny)) return false;
    if (fabsf(nx) > 1.0f || fabsf(ny) > 1.0f) return false;

    o->x = (nx * 0.5f + 0.5f) * sw;
    float nyy = (ySign > 0) ? -ny : ny;
    o->y = (nyy * 0.5f + 0.5f) * sh;
    o->z = cw;
    return true;
}

static bool project_manual(const float V[16], const float P[16], Vec3 w,
                           int sw, int sh, Vec3 *o) {
    /* 先试上次成功的那种 */
    if (gProjMode >= 0) {
        int zs = (gProjMode & 2) ? 1 : -1;
        int ys = (gProjMode & 1) ? 1 : -1;
        if (project_one(V, P, w, sw, sh, zs, ys, o)) return true;
    }
    for (int m = 0; m < 4; m++) {
        int zs = (m & 2) ? 1 : -1;
        int ys = (m & 1) ? 1 : -1;
        if (project_one(V, P, w, sw, sh, zs, ys, o)) { gProjMode = m; return true; }
    }
    return false;
}

/* ================= 全局 UI 句柄 ================= */
static UIView *gHost = nil, *gPanel = nil, *gEsp = nil;
static UILabel *gBadge = nil, *gDiag = nil;
static BOOL gVerified = NO;
static int gWinCount = 0;
static NSString *gHostDesc = @"?";
static NSString *gDbgText = @"-";
static NSString *gAimDbg = @"aim=-";
static int gCntAssign = 0, gCntLive = 0, gCntProj = 0, gCntW2S = 0, gCntMat = 0;
static int gFirstFail[1] = {0};
static Vec3 gFailPos;
static void toggle_panel(void);

/* ================= ESP ================= */
static const int kPairs[18][2] = {
    {10,9},{9,8},{8,7},{7,0},
    {9,11},{11,13},{13,15},{15,17},
    {9,12},{12,14},{14,16},{16,18},
    {0,1},{1,3},{3,5},{0,2},{2,4},{4,6},
};

@interface UMESP : UIView
@end

@implementation UMESP
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return NO; }
- (void)tick:(CADisplayLink *)l { [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)rect {
    if (!gIl2) { gDbgText = @"il2 未就绪"; return; }
    if (!gBox && !gSkel && !gCarBox && !gFovCircle && !gAntenna) return;

    CGContextRef cx = UIGraphicsGetCurrentContext();
    if (!cx) return;

    void *lp = call0(mCurPlayer, NULL);
    if (!lp) { gDbgText = @"no player"; return; }
    int n = collect_objects();
    if (n <= 0) { gDbgText = [NSString stringWithFormat:@"n=0 src=%@", gSrcText]; return; }

    int sw = call_int(mScrW, NULL), sh = call_int(mScrH, NULL);
    if (sw <= 0 || sh <= 0) { gDbgText = @"no screen"; return; }

    void *cam = resolve_camera();
    if (!cam) { gDbgText = @"no camera"; return; }

    float V[16], P[16];
    bool mat = get_mat4(mViewM, cam, V) && get_mat4(mProjM, cam, P);

    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    Vec3 origin; memcpy(&origin, (char *)lp + OFF_BODY, 12);

    int drawn = 0, cars = 0;
    gCntAssign = 0; gCntLive = 0; gCntProj = 0; gCntW2S = 0; gCntMat = 0; gFirstFail[0] = 0;

    if (gFovCircle) {
        CGContextSetLineWidth(cx, 1.2);
        CGContextSetRGBStrokeColor(cx, 1, 1, 1, 0.7);
        CGContextStrokeEllipseInRect(cx, CGRectMake(W/2 - gFovRadius, H/2 - gFovRadius,
                                                    gFovRadius * 2, gFovRadius * 2));
    }

    for (int i = 0; i < n; i++) {
        void *c = gObjs[i];
        if (!c || c == lp) continue;
        void *oc = A_objclass(c);
        if (!oc) continue;

        bool isPlayer = A_assign && A_assign(kPlayer, oc);
        bool isCar = (!isPlayer && kCar && A_assign && A_assign(kCar, oc));
        if (!isPlayer && !isCar) continue;
        gCntAssign++;

        Vec3 body; memcpy(&body, (char *)c + OFF_BODY, 12);
        if (!v3ok(body)) continue;
        float d = v3dist(origin, body);
        if (d > gMaxDist || d < 1.0f) continue;

        if (isCar) {
            if (!gCarBox) continue;
            Vec3 top = body, bot = body; top.y += 0.9f; bot.y -= 0.6f;
            Vec3 st, sb;
            bool o1 = mat ? project_manual(V, P, top, sw, sh, &st) : call_vec3(mW2S, cam, &top, &st);
            bool o2 = mat ? project_manual(V, P, bot, sw, sh, &sb) : call_vec3(mW2S, cam, &bot, &sb);
            if (!o1 || !o2) continue;
            CGFloat x = st.x / sw * W, y1 = (1.0f - st.y / sh) * H, y2 = (1.0f - sb.y / sh) * H;
            CGFloat h = fabs(y2 - y1), w = h * 0.7f;
            if (h < 6 || h > H * 1.6f) continue;
            CGContextSetLineWidth(cx, 1.4);
            CGContextSetRGBStrokeColor(cx, 1.0, 0.62, 0.15, 1.0);
            CGContextStrokeRect(cx, CGRectMake(x - w/2, y1, w, h));
            cars++;
            continue;
        }

        if (*(int *)((char *)c + OFF_LIVE) > 0) gCntLive++;

        void *anim = *(void **)((char *)c + OFF_ANIM);
        Vec3 head = body, foot = body, tmp;
        head.y += 1.0f;          /* A_nokey 是 y+1.0 再投影 */
        foot.y -= 0.2f;
        void *trH = bone_of(anim, 10), *trF = bone_of(anim, 5);
        if (trH && call_vec3(mGetPos, trH, NULL, &tmp)) head = tmp;
        if (trF && call_vec3(mGetPos, trF, NULL, &tmp)) { tmp.y -= 0.1f; foot = tmp; }

        Vec3 sh_, sf_;
        bool okW2S = call_vec3(mW2S, cam, &head, &sh_) && call_vec3(mW2S, cam, &foot, &sf_) &&
                     sh_.z > 0.01f && sf_.z > 0.01f;
        bool okMat = false;
        if (okW2S) { gCntW2S++; }
        else if (mat) {
            okMat = project_manual(V, P, head, sw, sh, &sh_) &&
                    project_manual(V, P, foot, sw, sh, &sf_);
            if (okMat) gCntMat++;
        }
        if (!okW2S && !okMat) {
            if (gFirstFail[0] == 0) {
                gFirstFail[0] = 1;
                memcpy(&gFailPos, &head, 12);
            }
            continue;
        }

        gCntProj++;
        CGFloat hx = sh_.x / sw * W, hy = (1.0f - sh_.y / sh) * H;
        CGFloat fy = (1.0f - sf_.y / sh) * H;
        CGFloat bh = fabs(fy - hy), bw = bh * 0.5f;
        if (bh < 6 || bh > H * 1.6f) continue;
        drawn++;

        if (gBox) {
            CGContextSetLineWidth(cx, 1.6);
            CGContextSetRGBStrokeColor(cx, 1.0, 0.30, 0.30, 1.0);
            CGContextStrokeRect(cx, CGRectMake(hx - bw/2, hy, bw, bh));
            if (gDist) {
                NSString *t = [NSString stringWithFormat:@"%.0fm", d];
                [t drawAtPoint:CGPointMake(hx - 12, hy - 14)
                withAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:10],
                                 NSForegroundColorAttributeName: [UIColor yellowColor]}];
            }
        }
        if (gAntenna) {
            CGContextSetLineWidth(cx, 1.0);
            CGContextSetRGBStrokeColor(cx, 0.4, 0.9, 1.0, 0.9);
            CGContextMoveToPoint(cx, hx, hy);
            CGContextAddLineToPoint(cx, hx, MAX(0, hy - 40));
            CGContextStrokePath(cx);
            CGContextMoveToPoint(cx, W * 0.5f, 0);
            CGContextAddLineToPoint(cx, hx, MAX(0, hy - 40));
            CGContextStrokePath(cx);
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
                bool oa = mat ? project_manual(V, P, a, sw, sh, &sa) : call_vec3(mW2S, cam, &a, &sa);
                bool ob = mat ? project_manual(V, P, b, sw, sh, &sb) : call_vec3(mW2S, cam, &b, &sb);
                if (!oa || !ob) continue;
                CGContextMoveToPoint(cx, sa.x / sw * W, (1.0f - sa.y / sh) * H);
                CGContextAddLineToPoint(cx, sb.x / sw * W, (1.0f - sb.y / sh) * H);
                CGContextStrokePath(cx);
            }
        }
    }

    /* 自检：把自己的坐标也投一次 */
    Vec3 selfS;
    bool selfW = call_vec3(mW2S, cam, &origin, &selfS) && selfS.z > 0.01f;
    bool selfM = false;
    if (!selfW && mat) selfM = project_manual(V, P, origin, sw, sh, &selfS);
    NSString *selfTxt = selfW ? [NSString stringWithFormat:@"self=%.0f,%.0f", selfS.x, selfS.y]
                              : (selfM ? @"selfMat" : @"selfFail");

    NSString *matTxt = mat ? [NSString stringWithFormat:@"V0=%.2f,%.2f P0=%.2f,%.2f pth=%d",
                              V[0], V[2], P[0], P[3], gMatPath] : @"matFail";
    gDbgText = [NSString stringWithFormat:@"n=%d a=%d l=%d w2s=%d mat=%d p=%d %@ cam=%@ %@ %@",
                n, gCntAssign, gCntLive, gCntW2S, gCntMat, drawn, gSrcText, gCamSrc, selfTxt, matTxt];
}
@end

/* ================= 自瞄 ================= */
static void aim_tick(void) {
    if (!gAimOn || !gIl2 || !mAimSet) return;
    void *lp = call0(mCurPlayer, NULL);
    if (!lp) return;
    int n = collect_objects();
    if (n <= 0) return;

    int sw = call_int(mScrW, NULL), sh = call_int(mScrH, NULL);
    if (sw <= 0 || sh <= 0) return;
    void *cam = resolve_camera();
    if (!cam) return;
    float V[16], P[16];
    bool mat = get_mat4(mViewM, cam, V) && get_mat4(mProjM, cam, P);

    CGRect scr = [UIScreen mainScreen].bounds;
    CGFloat cx0 = scr.size.width * 0.5f, cy0 = scr.size.height * 0.5f;

    Vec3 origin; memcpy(&origin, (char *)lp + OFF_BODY, 12);
    float best = gFovRadius; Vec3 bestPos; bool found = false;

    for (int i = 0; i < n; i++) {
        void *c = gObjs[i];
        if (!c || c == lp) continue;
        if (!A_assign || !A_assign(kPlayer, A_objclass(c))) continue;
        if (*(int *)((char *)c + OFF_LIVE) <= 0) continue;
        Vec3 body; memcpy(&body, (char *)c + OFF_BODY, 12);
        if (v3dist(origin, body) > gMaxDist) continue;

        void *anim = *(void **)((char *)c + OFF_ANIM);
        Vec3 head = body; head.y += 0.85f; Vec3 tmp;
        void *trH = bone_of(anim, 10);
        if (trH && call_vec3(mGetPos, trH, NULL, &tmp)) head = tmp;

        Vec3 sp;
        bool ok = mat ? project_manual(V, P, head, sw, sh, &sp) : call_vec3(mW2S, cam, &head, &sp);
        if (!ok) continue;
        CGFloat px = sp.x / sw * scr.size.width, py = sp.y / sh * scr.size.height;
        CGFloat dd = hypotf(px - cx0, py - cy0);
        if (dd < best) { best = dd; bestPos = head; found = true; }
    }
    static int aimHit = 0;
    if (found) {
        Vec3 arg = bestPos;
        void *params[1] = { &arg };
        A_invoke(mAimSet, lp, params, NULL);
        aimHit++;
    }
    gAimDbg = [NSString stringWithFormat:@"aim=%d m=%d", aimHit, mAimSet != NULL];
}

/* ================= 开关行 ================= */
@interface UMRow : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, copy) void (^handler)(BOOL);
@end

@implementation UMRow {
    UIView *_track, *_knob; UILabel *_lb;
}
- (instancetype)initWithTitle:(NSString *)t y:(CGFloat)y {
    if ((self = [super initWithFrame:CGRectMake(0, y, 244, 34)])) {
        _lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 7, 180, 20)];
        _lb.text = t; _lb.textColor = [UIColor whiteColor]; _lb.font = [UIFont systemFontOfSize:13];
        [self addSubview:_lb];
        _track = [[UIView alloc] initWithFrame:CGRectMake(192, 5, 46, 24)];
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

/* ================= 面板：左侧分类 + 右侧功能（分页仿 A_nokey，视觉用我们自己的毛玻璃） ================= */
@interface UMPanel : UIView
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation UMPanel {
    UIView *_content;
    NSArray<UIView *> *_pages;
    NSMutableArray<UIButton *> *_cats;
    NSInteger _sel;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    CGPoint c = self.center; c.x += t.x; c.y += t.y; self.center = c;
    [g setTranslation:CGPointZero inView:self.superview];
}

- (UIButton *)catButton:(NSString *)title y:(CGFloat)y {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(8, y, 72, 34);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
    b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 9;
    [b addTarget:self action:@selector(catTap:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.layer.cornerRadius = 18;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.30].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.6;
        self.layer.shadowRadius = 18;
        self.layer.shadowOffset = CGSizeMake(0, 8);

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.frame = self.bounds;
        blur.layer.cornerRadius = 18;
        blur.clipsToBounds = YES;
        [self addSubview:blur];

        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 9, 180, 22)];
        t.text = @"ULTRA MOD";
        t.textColor = [UIColor whiteColor];
        t.font = [UIFont boldSystemFontOfSize:15];
        [self addSubview:t];

        UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
        x.frame = CGRectMake(f.size.width - 38, 6, 30, 28);
        [x setTitle:@"✕" forState:UIControlStateNormal];
        [x setTitleColor:[UIColor colorWithWhite:1 alpha:0.85] forState:UIControlStateNormal];
        x.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [x addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:x];

        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, 36, f.size.width - 20, 1)];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
        [self addSubview:line];

        _cats = [NSMutableArray array];
        NSArray *names = @[@"视觉", @"瞄准", @"车辆"];
        for (int i = 0; i < (int)names.count; i++) {
            UIButton *b = [self catButton:names[i] y:46 + i * 40];
            [self addSubview:b];
            [_cats addObject:b];
        }

        _content = [[UIView alloc] initWithFrame:CGRectMake(86, 44, f.size.width - 96, f.size.height - 56)];
        _content.clipsToBounds = YES;
        [self addSubview:_content];
        CGFloat w = _content.bounds.size.width;

        UIView *p0 = [[UIView alloc] initWithFrame:_content.bounds];
        UMRow *a1 = [[UMRow alloc] initWithTitle:@"人物方框" y:0];
        a1.on = gBox; a1.handler = ^(BOOL v){ gBox = v; [gEsp setNeedsDisplay]; }; [p0 addSubview:a1];
        UMRow *a2 = [[UMRow alloc] initWithTitle:@"骨骼" y:36];
        a2.on = gSkel; a2.handler = ^(BOOL v){ gSkel = v; [gEsp setNeedsDisplay]; }; [p0 addSubview:a2];
        UMRow *a3 = [[UMRow alloc] initWithTitle:@"天线" y:72];
        a3.on = gAntenna; a3.handler = ^(BOOL v){ gAntenna = v; [gEsp setNeedsDisplay]; }; [p0 addSubview:a3];
        UMRow *a4 = [[UMRow alloc] initWithTitle:@"距离显示" y:108];
        a4.on = gDist; a4.handler = ^(BOOL v){ gDist = v; [gEsp setNeedsDisplay]; }; [p0 addSubview:a4];

        UIView *p1 = [[UIView alloc] initWithFrame:_content.bounds];
        UMRow *c1 = [[UMRow alloc] initWithTitle:@"坐标自瞄" y:0];
        c1.on = gAimOn; c1.handler = ^(BOOL v){ gAimOn = v; }; [p1 addSubview:c1];
        UMRow *c2 = [[UMRow alloc] initWithTitle:@"FOV 圈" y:36];
        c2.on = gFovCircle; c2.handler = ^(BOOL v){ gFovCircle = v; [gEsp setNeedsDisplay]; }; [p1 addSubview:c2];
        UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(0, 74, w, 16)];
        l1.text = @"FOV 半径"; l1.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        l1.font = [UIFont systemFontOfSize:11];
        [p1 addSubview:l1];
        UISlider *s1 = [[UISlider alloc] initWithFrame:CGRectMake(0, 92, w, 28)];
        s1.minimumValue = 40; s1.maximumValue = 320; s1.value = gFovRadius;
        [s1 addTarget:self action:@selector(fovChanged:) forControlEvents:UIControlEventValueChanged];
        [p1 addSubview:s1];
        UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(0, 126, w, 16)];
        l2.text = @"自瞄距离上限"; l2.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        l2.font = [UIFont systemFontOfSize:11];
        [p1 addSubview:l2];
        UISlider *s2 = [[UISlider alloc] initWithFrame:CGRectMake(0, 144, w, 28)];
        s2.minimumValue = 30; s2.maximumValue = 500; s2.value = gMaxDist;
        [s2 addTarget:self action:@selector(distChanged:) forControlEvents:UIControlEventValueChanged];
        [p1 addSubview:s2];

        UIView *p2 = [[UIView alloc] initWithFrame:_content.bounds];
        UMRow *b1 = [[UMRow alloc] initWithTitle:@"车辆方框" y:0];
        b1.on = gCarBox; b1.handler = ^(BOOL v){ gCarBox = v; [gEsp setNeedsDisplay]; }; [p2 addSubview:b1];

        _pages = @[p0, p1, p2];
        for (UIView *p in _pages) { p.hidden = (p != p0); [_content addSubview:p]; }

        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
        [self selectCat:0];
    }
    return self;
}

- (void)selectCat:(NSInteger)i {
    _sel = i;
    for (NSInteger k = 0; k < (NSInteger)_cats.count; k++) {
        BOOL on = (k == i);
        _cats[k].selected = on;
        _cats[k].backgroundColor = on ? [UIColor colorWithWhite:1 alpha:0.16] : [UIColor clearColor];
    }
    for (NSInteger k = 0; k < (NSInteger)_pages.count; k++) _pages[k].hidden = (k != i);
}

- (void)catTap:(UIButton *)b {
    NSInteger i = [_cats indexOfObject:b];
    if (i != NSNotFound) [self selectCat:i];
}
- (void)closeTap { if (self.onClose) self.onClose(); }
- (void)fovChanged:(UISlider *)s { gFovRadius = s.value; [gEsp setNeedsDisplay]; }
- (void)distChanged:(UISlider *)s { gMaxDist = s.value; }
@end

/* ================= 角标 ================= */
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

        gEsp = [[UMESP alloc] initWithFrame:gHost.bounds];
        gEsp.backgroundColor = [UIColor clearColor];
        gEsp.opaque = NO;
        gEsp.userInteractionEnabled = NO;
        [gHost addSubview:gEsp];

        gBadge = [[UMBadge alloc] initWithFrame:CGRectMake(14, 56, 280, 26)];
        gBadge.text = @"ULTRA MOD";
        gBadge.textColor = [UIColor colorWithRed:1 green:0.28 blue:0.28 alpha:1];
        gBadge.font = [UIFont boldSystemFontOfSize:18];
        gBadge.userInteractionEnabled = YES;
        [gHost addSubview:gBadge];

        gDiag = [[UILabel alloc] initWithFrame:CGRectMake(14, 82, 340, 14)];
        gDiag.text = [NSString stringWithFormat:@"W:%d %@ il2:%d", gWinCount, gHostDesc, (int)gIl2];
        gDiag.textColor = [UIColor colorWithWhite:0.92 alpha:0.85];
        gDiag.font = [UIFont systemFontOfSize:9];
        [gHost addSubview:gDiag];

        UMPanel *p = [[UMPanel alloc] initWithFrame:CGRectMake((gHost.bounds.size.width - 300) / 2, 108, 300, 264)];
        __weak UMPanel *wp = p;
        p.onClose = ^{ wp.hidden = YES; };
        [gHost addSubview:p];
        gPanel = p;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!gVerified && gPanel.superview && gPanel.window) {
                gVerified = YES;
                gBadge.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.55 alpha:1];
            }
        });

        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) { aim_tick(); }];
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            gDiag.text = gDbgText;
        }];

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
        sleep(15);
        dispatch_sync(dispatch_get_main_queue(), ^{ il2_init(); });
        attach_all();
    });
}
