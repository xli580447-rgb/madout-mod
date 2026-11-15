//
//  bullettrack.mm — MadOut 2 (US) 21.30 全功能 dylib
//
//  功能表：
//    1. 子弹追踪      Shots::Add 改写每颗弹丸 dir → 静默命中（霰弹逐弹丸生效）
//    2. 自定义射速    100–700 RPM，只作用于本地玩家，内部 100ms 冷却被绕过
//    3. 扩容弹匣      Weapon.Bullets::get_Count 抬高 + MinusOne 不扣弹
//    4. 超大命中范围  IntersectionBone::ProcessShot 期间按倍数放大骨骼命中球半径
//    5. 坐标自瞄      Control::SetCamDirByWorldPoint（静默：开火瞬间瞄准、开完还原）
//    6. ESP           方框 / 18 段骨骼 / 距离 / 准心连线（UIKit 浮层，30fps）
//
//  版本锁定：UnityFramework 21.30（metadata v39）。换版本需重跑 dump 更新 RVA。
//  编译：Theos（见同目录 Makefile），链接 libsubstrate 提供 MSHookFunction。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <math.h>
#include <string.h>
#include <vector>
#include <mutex>
#include <time.h>

/* ============================== 钩子引擎 ==============================
   非越狱不能 mmap 可执行内存，所以 trampoline 预留在本 dylib 的 __TEXT 里，
   运行时用 vm_protect(VM_PROT_COPY) 改成可写、写完再改回可执行。
   越狱环境定义 USE_SUBSTRATE 时走 substrate。
*/
#ifdef USE_SUBSTRATE
extern "C" void MSHookFunction(void *symbol, void *replace, void **result);
#else
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>

__attribute__((used, aligned(16384), section("__TEXT,__tramp")))
static unsigned char g_trampArea[32768];
static size_t g_trampUsed = 0;

static bool bt_page_writable(void *addr, size_t len) {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)addr, len, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}
static void bt_page_exec(void *addr, size_t len) {
    vm_protect(mach_task_self(), (vm_address_t)addr, len, false,
               VM_PROT_READ | VM_PROT_EXECUTE);
}
static bool bt_insn_is_pcrel(uint32_t insn) {
    if ((insn & 0xFC000000u) == 0x14000000u) return true;  /* b / bl */
    if ((insn & 0x9F000000u) == 0x90000000u) return true;  /* adrp */
    if ((insn & 0x9F000000u) == 0x10000000u) return true;  /* adr */
    if ((insn & 0x3B000000u) == 0x18000000u) return true;  /* ldr literal */
    if ((insn & 0x7E000000u) == 0x34000000u) return true;  /* cbz / cbnz */
    return false;
}

/* 返回 trampoline（调用它 = 执行原函数），失败返回 NULL */
static void *bt_hook(void *target, void *replacement) {
    if (!target || !replacement) return NULL;
    uint32_t *t = (uint32_t *)target;
    uint32_t stolen[4];
    for (int i = 0; i < 4; i++) {
        stolen[i] = t[i];
        if (bt_insn_is_pcrel(stolen[i])) {
            NSLog(@"[BT] hook 0x%lx 失败：prologue 含 PC 相对指令 0x%08x",
                  (unsigned long)(uintptr_t)target, stolen[i]);
            return NULL;
        }
    }
    if (g_trampUsed + 64 > sizeof(g_trampArea)) return NULL;

    unsigned char *tramp = g_trampArea + g_trampUsed;
    g_trampUsed += 64;

    if (!bt_page_writable(g_trampArea, sizeof(g_trampArea))) {
        NSLog(@"[BT] trampoline 页不可写");
        return NULL;
    }
    uint32_t *w = (uint32_t *)tramp;
    w[0] = stolen[0]; w[1] = stolen[1]; w[2] = stolen[2]; w[3] = stolen[3];
    w[4] = 0x58000050u;   /* ldr x16, #8 */
    w[5] = 0xd61f0200u;   /* br  x16    */
    *(uint64_t *)&w[6] = (uint64_t)(uintptr_t)target + 16;

    if (!bt_page_writable(target, 16)) { NSLog(@"[BT] 目标页不可写"); return NULL; }
    uint32_t *p = (uint32_t *)target;
    p[0] = 0x58000050u;
    p[1] = 0xd61f0200u;
    *(uint64_t *)&p[2] = (uint64_t)(uintptr_t)replacement;

    sys_icache_invalidate(tramp, 32);
    sys_icache_invalidate(target, 16);
    bt_page_exec(g_trampArea, sizeof(g_trampArea));
    bt_page_exec(target, 16);
    return tramp;
}

static inline void MSHookFunction(void *symbol, void *replace, void **result) {
    void *tramp = bt_hook(symbol, replace);
    if (result) *result = tramp;
}
#endif

/* ============================== 数学 ============================== */

struct Vec3 {
    float x, y, z;
    Vec3() : x(0), y(0), z(0) {}
    Vec3(float a, float b, float c) : x(a), y(b), z(c) {}
};
static inline Vec3 vadd(Vec3 a, Vec3 b) { return Vec3(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline Vec3 vsub(Vec3 a, Vec3 b) { return Vec3(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline Vec3 vmul(Vec3 a, float s) { return Vec3(a.x * s, a.y * s, a.z * s); }
static inline float vdot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline float vlen(Vec3 a) { return sqrtf(vdot(a, a)); }
static inline Vec3 vnorm(Vec3 a) { float l = vlen(a); return l > 1e-6f ? vmul(a, 1.0f / l) : Vec3(); }
static inline float vdist(Vec3 a, Vec3 b) { return vlen(vsub(a, b)); }

struct Ray { Vec3 origin; Vec3 direction; };

/* ============================== 21.30 RVA ============================== */

static const uint32_t RVA_DoShot           = 0x44CC22C;  // PlayerWeaponeBase::DoShot
static const uint32_t RVA_Shots_Add        = 0x459344C;  // Shots::Add
static const uint32_t RVA_Item_Update      = 0x45937C4;  // Shots.Item::Update
static const uint32_t RVA_Bone_ProcessShot = 0x45924AC;  // IntersectionBone::ProcessShot
static const uint32_t RVA_Bullets_MinusOne = 0x4599508;  // Weapon.Bullets::MinusOne
static const uint32_t RVA_Bullets_GetCount = 0x45994A0;  // Weapon.Bullets::get_Count
static const uint32_t RVA_CmdShot_Reliable = 0x48E6B2C;  // NetControlPlayer::Cmd_Shot_Reliable
static const uint32_t RVA_CmdShot_Unrel    = 0x48E6CC4;  // NetControlPlayer::Cmd_Shot_Unreliable

/* ============================== 21.30 字段偏移 ============================== */

static const size_t OFS_WEAPON_PLAYER  = 0x0C0;  // PlayerWeaponeBase.player
static const size_t OFS_LAST_SHOT_TIME = 0x028;  // WeaponView.last_time_shot
static const size_t OFS_CTRL_BODY_POS  = 0x194;  // Control.body_pos
static const size_t OFS_CTRL_BODY_LIN  = 0x1AC;  // Control.body_linear
static const size_t OFS_CTRL_LIVE      = 0x208;  // Control._live
static const size_t OFS_CTRL_ENEMY     = 0x498;  // Control.isMarkAsAnamyForCurUser
static const size_t OFS_CTRL_ANIMATOR  = 0x370;  // PlayerControl.animator
static const size_t OFS_BONE_RADIUS    = 0x098;  // IntersectionBone.radius
static const size_t OFS_ITEM_POS       = 0x030;  // Shots.Item.pos
static const size_t OFS_ITEM_DIR       = 0x03C;  // Shots.Item.dir
static const size_t OFS_ITEM_CAMDIR    = 0x048;  // Shots.Item.camDir
static const size_t OFS_ITEM_SPEED     = 0x054;  // Shots.Item.speed

/* ============================== il2cpp 桥 ============================== */

struct Il2CppApi {
    void *(*domain_get)();
    void *(*domain_get_assemblies)(void *, size_t *);
    void *(*assembly_get_image)(void *);
    const char *(*image_get_name)(void *);
    void *(*class_from_name)(void *, const char *, const char *);
    void *(*class_get_method_from_name)(void *, const char *, int);
    void *(*class_get_field_from_name)(void *, const char *);
    int (*field_get_offset)(void *);
    void (*field_static_get_value)(void *, void *);
    void *(*object_get_class)(void *);
    bool (*class_is_assignable_from)(void *, void *);
};

static Il2CppApi il2 = {};
static uintptr_t gBase = 0;
static bool gReady = false;

template <typename T> static void bindFn(T &slot, const char *name) {
    slot = (T)dlsym(RTLD_DEFAULT, name);
}

static void *findImage(const char *name) {
    if (!il2.domain_get) return nullptr;
    void *domain = il2.domain_get();
    if (!domain) return nullptr;
    size_t n = 0;
    void **asms = (void **)il2.domain_get_assemblies(domain, &n);
    if (!asms) return nullptr;
    for (size_t i = 0; i < n; i++) {
        if (!asms[i]) continue;
        void *img = il2.assembly_get_image(asms[i]);
        const char *in = img ? il2.image_get_name(img) : nullptr;
        if (in && strcmp(in, name) == 0) return img;
    }
    return nullptr;
}

static void *gAsmCSharp = nullptr;
static void *kControl = nullptr, *kPlayerControl = nullptr, *kShots = nullptr;
static void *kAnimator = nullptr, *kCamera = nullptr, *kTransform = nullptr, *kScreen = nullptr;
static void *mGetCurrentPlayer = nullptr;
static void *fControls = nullptr;

static void *methodPtr(void *methodInfo) { return methodInfo ? *(void **)methodInfo : nullptr; }

static void *resolveMethod(void *klass, const char *name, int argc) {
    if (!klass) return nullptr;
    return methodPtr(il2.class_get_method_from_name(klass, name, argc));
}

/* ============================== 配置 ============================== */

struct Config {
    bool  bulletTrack = true;    // 子弹追踪
    bool  patchAll    = false;   // 连 AI/载具武器一起改（默认关）
    bool  fireRate    = false;   // 自定义射速
    float rpm         = 700.0f;  // 100..700
    bool  extMag      = false;   // 扩容弹匣
    int   magSize     = 300;     // 弹匣容量
    bool  hitbox      = false;   // 超大命中范围
    float hitboxMul   = 4.0f;    // 命中球半径倍数 1..12
    bool  aim         = false;   // 坐标自瞄
    int   aimMode     = 1;       // 1=静默(开火瞬间) 2=持续跟随
    float aimFov      = 60.0f;
    float aimDist     = 300.0f;
    float aimHeight   = 0.0f;
    bool  esp         = false;
    bool  espSkeleton = false;
    bool  espDistance = true;
    float espMaxDist  = 300.0f;
    bool  drawMenu    = true;
};
static Config gCfg;

/* 运行统计：给菜单里的状态行用（真机没 Mac 也能看结果） */
struct BtStats {
    volatile int doShot, add, patched, bone, minusOne, getCount, cmdShot, itemUpdate, espN;
};
static BtStats gStats;

static uintptr_t resolveBase();   // 前置声明（statusText 里要用）

/* ============================== 状态 ============================== */

static void *gLocalPlayer = nullptr;
static double gLocalPlayerAt = 0;
static bool  gInLocalShot = false;
static bool  gCurrentItemMine = false;
static double gNextFireMs = 0;

static std::vector<void *> gMyItems;
static std::mutex gItemMutex;

static Vec3 gPendingAimDir;          // 本次开火要发往服务端的方向
static bool gHasPendingAim = false;

static double nowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void *currentPlayer() {
    if (gLocalPlayer && nowMs() - gLocalPlayerAt < 2000) return gLocalPlayer;
    if (!mGetCurrentPlayer) return nullptr;
    void *p = ((void *(*)(void *))mGetCurrentPlayer)(nullptr);
    if (p) { gLocalPlayer = p; gLocalPlayerAt = nowMs(); }
    return gLocalPlayer;
}

/* ============================== 目标 ============================== */

struct Target {
    void *ctrl = nullptr;
    Vec3 pos, vel;
    float dist = 0, angle = 0;
};

static void collectTargets(Vec3 origin, Vec3 camDir, std::vector<Target> &out, bool enemyOnly,
                           float fovDeg, float maxDist) {
    out.clear();
    if (!fControls || !kPlayerControl) return;
    void *list = nullptr;
    il2.field_static_get_value(fControls, &list);
    if (!list) return;

    void *items = *(void **)((char *)list + 0x10);   // List<T>._items
    int size = *(int *)((char *)list + 0x18);        // List<T>._size
    if (!items || size <= 0 || size > 4096) return;

    void *local = currentPlayer();
    for (int i = 0; i < size; i++) {
        void *c = *(void **)((char *)items + 0x20 + i * 8);
        if (!c || c == local) continue;
        void *klass = il2.object_get_class ? il2.object_get_class(c) : nullptr;
        if (!klass || !il2.class_is_assignable_from(kPlayerControl, klass)) continue;
        if (*(int *)((char *)c + OFS_CTRL_LIVE) <= 0) continue;
        if (enemyOnly && *(float *)((char *)c + OFS_CTRL_ENEMY) < 0.5f) continue;

        Vec3 pos = *(Vec3 *)((char *)c + OFS_CTRL_BODY_POS);
        pos.y += gCfg.aimHeight;
        float d = vdist(origin, pos);
        if (maxDist > 0 && d > maxDist) continue;
        if (d < 1.0f) continue;

        float ang = 0.0f;
        if (vlen(camDir) > 1e-6f) {
            float cosv = vdot(vnorm(camDir), vnorm(vsub(pos, origin)));
            cosv = fmaxf(-1.0f, fminf(1.0f, cosv));
            ang = acosf(cosv) * 180.0f / (float)M_PI;
            if (fovDeg > 0 && ang > fovDeg) continue;
        }
        Target t;
        t.ctrl = c;
        t.pos = pos;
        t.vel = *(Vec3 *)((char *)c + OFS_CTRL_BODY_LIN);
        t.dist = d;
        t.angle = ang;
        out.push_back(t);
    }
}

static bool bestTarget(Vec3 origin, Vec3 camDir, Target &out) {
    std::vector<Target> v;
    collectTargets(origin, camDir, v, true, gCfg.aimFov, gCfg.aimDist);
    if (v.empty()) collectTargets(origin, camDir, v, false, gCfg.aimFov, gCfg.aimDist);
    if (v.empty()) return false;
    Target *best = nullptr;
    for (auto &t : v) if (!best || t.angle < best->angle) best = &t;
    if (best) { out = *best; return true; }
    return false;
}

/* ============================== 相机 / 瞄准 ============================== */

typedef Vec3 (*GetCurCamDir_t)(void *);
typedef void (*SetCamDirVec_t)(void *, Vec3);
typedef void (*SetCamDirPoint_t)(void *, Vec3);

static GetCurCamDir_t pGetCurCamDir = nullptr;
static SetCamDirVec_t pSetCamDirByVector = nullptr;
static SetCamDirPoint_t pSetCamDirByWorldPoint = nullptr;

static Vec3 gSavedCamDir;
static bool gNeedRestore = false;

static void aimPoint(void *player, Vec3 point) {
    if (player && pSetCamDirByWorldPoint) pSetCamDirByWorldPoint(player, point);
}

/* ============================== 钩子：开火 ============================== */

typedef void (*DoShot_t)(void *);
static DoShot_t orig_DoShot = nullptr;

static void hook_DoShot(void *self) {
    gStats.doShot++;
    if (!self) { orig_DoShot(self); return; }
    void *player = *(void **)((char *)self + OFS_WEAPON_PLAYER);
    void *lp = currentPlayer();
    bool mine = (player && lp && player == lp);
    gInLocalShot = mine;

    if (mine && gCfg.fireRate) {
        double interval = 60000.0 / fmaxf(100.0f, fminf(700.0f, gCfg.rpm));
        if (nowMs() >= gNextFireMs) {
            gNextFireMs = nowMs() + interval;
            // 内部冷却：nTime - last_time_shot >= NeedFireTimeMS/1000 (100ms)。
            // 把上次开火时间推到远古 → 本帧必定通过；未到间隔就不动，交给游戏自己拦。
            *(float *)((char *)self + OFS_LAST_SHOT_TIME) = -1.0e6f;
        }
    }

    if (mine && gCfg.aim && gCfg.aimMode == 1 && pGetCurCamDir && pSetCamDirByWorldPoint) {
        Vec3 camDir = pGetCurCamDir(lp);
        Vec3 origin = *(Vec3 *)((char *)lp + OFS_CTRL_BODY_POS);
        Target t;
        if (bestTarget(origin, camDir, t)) {
            gSavedCamDir = camDir;
            gNeedRestore = true;
            aimPoint(lp, t.pos);
        }
    }

    orig_DoShot(self);

    if (gNeedRestore && pSetCamDirByVector) {
        pSetCamDirByVector(lp, gSavedCamDir);   // 静默：开完立刻还原视角
        gNeedRestore = false;
    }
    gInLocalShot = false;
}

/* ============================== 钩子：弹丸方向 ============================== */

typedef void *(*ShotsAdd_t)(void *, Vec3, Vec3, Vec3, float, float, int, int, float, bool, bool, float);
static ShotsAdd_t orig_ShotsAdd = nullptr;

static void rememberItem(void *item) {
    std::lock_guard<std::mutex> lk(gItemMutex);
    gMyItems.push_back(item);
    if (gMyItems.size() > 64) gMyItems.erase(gMyItems.begin());
}

static bool isMyItem(void *item) {
    if (!item) return false;
    std::lock_guard<std::mutex> lk(gItemMutex);
    for (void *p : gMyItems) if (p == item) return true;
    return false;
}

static void *hook_ShotsAdd(void *self, Vec3 pos, Vec3 dir, Vec3 camDir, float speed, float mass,
                           int who, int weaponType, float alphaDamage, bool first, bool nomark, float maxDist) {
    gStats.add++;
    void *item = orig_ShotsAdd(self, pos, dir, camDir, speed, mass, who, weaponType,
                               alphaDamage, first, nomark, maxDist);
    if (!item) return item;
    if (!gInLocalShot && !gCfg.patchAll) return item;

    rememberItem(item);           // 命中范围/归属判定要用，和是否改方向无关
    if (!gCfg.bulletTrack) return item;

    Target t;
    if (bestTarget(pos, camDir, t)) {
        Vec3 aim = t.pos;
        if (speed > 1.0f) aim = vadd(aim, vmul(t.vel, t.dist / speed));  // 提前量
        Vec3 nd = vnorm(vsub(aim, pos));
        *(Vec3 *)((char *)item + OFS_ITEM_DIR) = nd;
        // 同一次开火要发给服务端的 NetShotInfo 也记一份，见 hook_CmdShot
        gPendingAimDir = nd;
        gHasPendingAim = true;
    }
    return item;
}

/* ============================== 钩子：上行 shot 数据（保证服务端复算同一个方向） ============================== */

// NetShotInfo { Vector3 CameraDirection; Vector3 BaseDirection; Vector3 ShotPosition; ... }
static const size_t OFS_NSI_CAMDIR = 0x00;
static const size_t OFS_NSI_BASEDIR = 0x0C;

typedef void (*CmdShot_t)(void *, void *);
static CmdShot_t orig_CmdShotReliable = nullptr;
static CmdShot_t orig_CmdShotUnrel = nullptr;

static void patchShotInfo(void *info) {
    if (!info || !gHasPendingAim) return;
    *(Vec3 *)((char *)info + OFS_NSI_CAMDIR) = gPendingAimDir;
    *(Vec3 *)((char *)info + OFS_NSI_BASEDIR) = gPendingAimDir;
    gHasPendingAim = false;
}

static void hook_CmdShotReliable(void *self, void *info) {
    gStats.cmdShot++;
    patchShotInfo(info);
    orig_CmdShotReliable(self, info);
}

static void hook_CmdShotUnrel(void *self, void *info) {
    gStats.cmdShot++;
    patchShotInfo(info);
    orig_CmdShotUnrel(self, info);
}

/* ============================== 钩子：弹丸归属 ============================== */

typedef void (*ItemUpdate_t)(void *);
static ItemUpdate_t orig_ItemUpdate = nullptr;

static void hook_ItemUpdate(void *self) {
    gStats.itemUpdate++;
    gCurrentItemMine = isMyItem(self);
    orig_ItemUpdate(self);
    gCurrentItemMine = false;
}

/* ============================== 钩子：碰撞箱（命中球半径） ============================== */

typedef bool (*BoneProcessShot_t)(void *, Ray *, void *);
static BoneProcessShot_t orig_BoneProcessShot = nullptr;

static bool hook_BoneProcessShot(void *self, Ray *ray, void *shot) {
    gStats.bone++;
    if (!gCfg.hitbox || !gCurrentItemMine || !self) {
        return orig_BoneProcessShot(self, ray, shot);
    }
    float *radius = (float *)((char *)self + OFS_BONE_RADIUS);
    float old = *radius;
    *radius = old * fmaxf(1.0f, gCfg.hitboxMul);
    bool hit = orig_BoneProcessShot(self, ray, shot);
    *radius = old;
    return hit;
}

/* ============================== 钩子：弹药 ============================== */

typedef void (*MinusOne_t)(void *);
typedef int (*GetCount_t)(void *);
static MinusOne_t orig_MinusOne = nullptr;
static GetCount_t orig_GetCount = nullptr;

static void hook_MinusOne(void *self) {
    gStats.minusOne++;
    if (gCfg.extMag) return;      // 不扣弹
    orig_MinusOne(self);
}

static int hook_GetCount(void *self) {
    gStats.getCount++;
    int c = orig_GetCount(self);
    if (gCfg.extMag && c < gCfg.magSize) return gCfg.magSize;
    return c;
}

/* ============================== 世界 → 屏幕 ============================== */

typedef Vec3 (*W2S_t)(void *, Vec3);
typedef void *(*GetMainCam_t)(void *);
typedef Vec3 (*GetPos_t)(void *);
typedef int (*GetInt_t)(void *);

static W2S_t pW2S = nullptr;
static GetMainCam_t pGetMainCam = nullptr;
static GetPos_t pGetPos = nullptr;
static void *(*pGetBone)(void *, int) = nullptr;
static GetInt_t pScreenW = nullptr, pScreenH = nullptr;

static void *mainCamera() { return pGetMainCam ? pGetMainCam(nullptr) : nullptr; }

// 返回归一化坐标 [0,1]，原点左下（Unity 屏幕空间），由调用方换算成视图坐标
static bool projectNorm(Vec3 world, CGPoint &out) {
    void *cam = mainCamera();
    if (!cam || !pW2S || !pScreenW || !pScreenH) return false;
    Vec3 s = pW2S(cam, world);
    if (s.z < 0.1f) return false;
    int sw = pScreenW(nullptr), sh = pScreenH(nullptr);
    if (sw <= 0 || sh <= 0) return false;
    out = CGPointMake(s.x / (float)sw, s.y / (float)sh);
    return true;
}

/* ============================== ESP ============================== */

static const int kSkeletonPairs[][2] = {
    {10, 9}, {9, 8}, {8, 7}, {7, 0},
    {9, 11}, {11, 13}, {13, 15}, {15, 17},
    {9, 12}, {12, 14}, {14, 16}, {16, 18},
    {0, 1}, {1, 3}, {3, 5},
    {0, 2}, {2, 4}, {4, 6},
};

@interface BTESPView : UIView
@end

@implementation BTESPView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return NO; }

- (void)drawRect:(CGRect)rect {
    if (!gReady || (!gCfg.esp && !gCfg.espSkeleton)) return;
    void *lp = currentPlayer();
    if (!lp) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    Vec3 origin = *(Vec3 *)((char *)lp + OFS_CTRL_BODY_POS);

    std::vector<Target> v;
    collectTargets(origin, Vec3(), v, false, -1.0f, gCfg.espMaxDist);

    gStats.espN = (int)v.size();

    for (auto &t : v) {
        void *anim = *(void **)((char *)t.ctrl + OFS_CTRL_ANIMATOR);
        Vec3 head = vadd(t.pos, Vec3(0, 0.85f, 0));
        Vec3 foot = vsub(t.pos, Vec3(0, 0.95f, 0));
        if (anim && pGetBone && pGetPos) {
            void *trH = pGetBone(anim, 10);   // Head
            void *trF = pGetBone(anim, 5);    // LeftFoot
            if (trH) head = pGetPos(trH);
            if (trF) foot = vsub(pGetPos(trF), Vec3(0, 0.1f, 0));
        }

        CGPoint nH, nF;
        if (!projectNorm(head, nH) || !projectNorm(foot, nF)) continue;
        CGPoint pH = CGPointMake(nH.x * W, (1.0f - nH.y) * H);
        CGPoint pF = CGPointMake(nF.x * W, (1.0f - nF.y) * H);

        CGFloat bh = fabs(pF.y - pH.y);
        if (bh < 6 || bh > H * 1.5f) continue;
        CGFloat bw = bh * 0.5f;
        CGRect box = CGRectMake(pH.x - bw * 0.5f, pH.y, bw, bh);

        if (gCfg.esp) {
            CGContextSetLineWidth(ctx, 1.5f);
            CGContextSetRGBStrokeColor(ctx, 1.0f, 0.25f, 0.25f, 1.0f);
            CGContextStrokeRect(ctx, box);

            CGContextSetLineWidth(ctx, 1.0f);
            CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, 0.22f);
            CGContextMoveToPoint(ctx, W * 0.5f, H);
            CGContextAddLineToPoint(ctx, CGRectGetMidX(box), CGRectGetMaxY(box));
            CGContextStrokePath(ctx);
        }

        if (gCfg.espSkeleton && anim && pGetBone && pGetPos) {
            CGContextSetLineWidth(ctx, 1.2f);
            CGContextSetRGBStrokeColor(ctx, 0.2f, 1.0f, 0.4f, 0.9f);
            for (auto &pair : kSkeletonPairs) {
                void *a = pGetBone(anim, pair[0]);
                void *b = pGetBone(anim, pair[1]);
                if (!a || !b) continue;
                CGPoint na, nb;
                if (!projectNorm(pGetPos(a), na) || !projectNorm(pGetPos(b), nb)) continue;
                CGContextMoveToPoint(ctx, na.x * W, (1.0f - na.y) * H);
                CGContextAddLineToPoint(ctx, nb.x * W, (1.0f - nb.y) * H);
                CGContextStrokePath(ctx);
            }
        }

        if (gCfg.esp && gCfg.espDistance) {
            NSString *txt = [NSString stringWithFormat:@"%.0fm", t.dist];
            [txt drawAtPoint:CGPointMake(CGRectGetMidX(box) - 12, pH.y - 15)
              withAttributes:@{NSFontAttributeName : [UIFont boldSystemFontOfSize:10],
                               NSForegroundColorAttributeName : [UIColor yellowColor]}];
        }
    }
}
@end

/* ============================== 菜单 ============================== */

@interface BTMenu : UIView
- (void)buildUI;
+ (NSString *)statusText;
@end

@implementation BTMenu {
    UILabel *_title;
}

static UISlider *mkSlider(UIView *parent, NSString *title, float min, float max, float value,
                          SEL action, id target, CGFloat y) {
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(12, y, 256, 15)];
    lab.textColor = [UIColor whiteColor];
    lab.font = [UIFont systemFontOfSize:10.5f];
    lab.text = [NSString stringWithFormat:@"%@: %.0f", title, value];
    [parent addSubview:lab];

    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 15, 256, 20)];
    s.minimumValue = min;
    s.maximumValue = max;
    s.value = value;
    [s addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    [parent addSubview:s];
    return s;
}

static UISwitch *mkSwitch(UIView *parent, NSString *title, BOOL on, SEL action, id target, CGFloat y) {
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(216, y, 51, 31)];
    sw.on = on;
    [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    [parent addSubview:sw];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(12, y + 6, 200, 18)];
    lab.text = title;
    lab.textColor = [UIColor whiteColor];
    lab.font = [UIFont systemFontOfSize:12];
    [parent addSubview:lab];
    return sw;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.08f alpha:0.93f];
        self.layer.cornerRadius = 12;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0.35f alpha:1].CGColor;
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    CGFloat W = self.bounds.size.width;
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 34, W, self.bounds.size.height - 34)];
    scroll.contentSize = CGSizeMake(W, 620);
    scroll.showsVerticalScrollIndicator = YES;
    [self addSubview:scroll];

    _title = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, W - 24, 22)];
    _title.text = @"MadOut2 21.30  ·  YG";
    _title.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.5 alpha:1];
    _title.font = [UIFont boldSystemFontOfSize:13];
    _title.userInteractionEnabled = YES;
    [self addSubview:_title];
    [_title addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];

    CGFloat y = 4;
    mkSwitch(scroll, @"子弹追踪", gCfg.bulletTrack, @selector(onBulletTrack:), self, y); y += 36;
    mkSwitch(scroll, @"自定义射速", gCfg.fireRate, @selector(onFireRate:), self, y); y += 36;
    mkSlider(scroll, @"射速 RPM (100-700)", 100, 700, gCfg.rpm, @selector(onRpm:), self, y); y += 52;
    mkSwitch(scroll, @"扩容弹匣", gCfg.extMag, @selector(onMag:), self, y); y += 36;
    mkSlider(scroll, @"弹匣容量", 30, 999, (float)gCfg.magSize, @selector(onMagSize:), self, y); y += 52;
    mkSwitch(scroll, @"超大命中范围", gCfg.hitbox, @selector(onHitbox:), self, y); y += 36;
    mkSlider(scroll, @"碰撞箱倍数", 1, 12, gCfg.hitboxMul, @selector(onHitboxMul:), self, y); y += 52;
    mkSwitch(scroll, @"坐标自瞄", gCfg.aim, @selector(onAim:), self, y); y += 36;
    mkSlider(scroll, @"自瞄 FOV", 10, 180, gCfg.aimFov, @selector(onAimFov:), self, y); y += 52;
    mkSlider(scroll, @"自瞄距离", 20, 600, gCfg.aimDist, @selector(onAimDist:), self, y); y += 52;
    mkSwitch(scroll, @"人物方框", gCfg.esp, @selector(onEsp:), self, y); y += 36;
    mkSwitch(scroll, @"骨骼", gCfg.espSkeleton, @selector(onSkel:), self, y); y += 36;
    mkSwitch(scroll, @"距离显示", gCfg.espDistance, @selector(onDist:), self, y); y += 36;

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(12, y, W - 24, 74)];
    st.numberOfLines = 0;
    st.tag = 901;
    st.font = [UIFont systemFontOfSize:9];
    st.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    st.text = @"状态读取中…";
    [scroll addSubview:st];
    y += 78;

    UIButton *cp = [UIButton buttonWithType:UIButtonTypeSystem];
    cp.frame = CGRectMake(12, y, W - 24, 30);
    [cp setTitle:@"复制状态" forState:UIControlStateNormal];
    [cp addTarget:self action:@selector(copyStatus) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:cp];
    y += 36;

    scroll.contentSize = CGSizeMake(W, y + 10);
}

- (void)copyStatus {
    NSString *t = [BTMenu statusText];
    [UIPasteboard generalPasteboard].string = t;
    _title.text = @"已复制 · MadOut2 21.30";
}

+ (NSString *)statusText {
    uintptr_t base = resolveBase();
    return [NSString stringWithFormat:
        @"base: %@\nhooks: %d/8  il2cpp: %@\nDoShot %d · Add %d · 改写 %d\n命中球 %d · 弹匣 %d/%d · 上行 %d\nESP %d 人",
        base ? [NSString stringWithFormat:@"0x%lx", (unsigned long)base] : @"未就绪",
        gHooked ? 8 : 0,
        gReady ? @"ok" : @"未初始化",
        gStats.doShot, gStats.add, gStats.patched,
        gStats.bone, gStats.minusOne, gStats.getCount, gStats.cmdShot,
        gStats.espN];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.superview];
}

- (void)onBulletTrack:(UISwitch *)s { gCfg.bulletTrack = s.on; }
- (void)onFireRate:(UISwitch *)s { gCfg.fireRate = s.on; }
- (void)onRpm:(UISlider *)s { gCfg.rpm = s.value; }
- (void)onMag:(UISwitch *)s { gCfg.extMag = s.on; }
- (void)onMagSize:(UISlider *)s { gCfg.magSize = (int)s.value; }
- (void)onHitbox:(UISwitch *)s { gCfg.hitbox = s.on; }
- (void)onHitboxMul:(UISlider *)s { gCfg.hitboxMul = s.value; }
- (void)onAim:(UISwitch *)s { gCfg.aim = s.on; }
- (void)onAimFov:(UISlider *)s { gCfg.aimFov = s.value; }
- (void)onAimDist:(UISlider *)s { gCfg.aimDist = s.value; }
- (void)onEsp:(UISwitch *)s { gCfg.esp = s.on; }
- (void)onSkel:(UISwitch *)s { gCfg.espSkeleton = s.on; }
- (void)onDist:(UISwitch *)s { gCfg.espDistance = s.on; }

@end

/* ============================== 浮层 ============================== */

@interface BTWindow : UIWindow
@end
@implementation BTWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;   // 空白处放行给游戏
    return v;
}
@end

@interface BTOverlay : NSObject
@property(nonatomic, strong) BTWindow *window;
@property(nonatomic, strong) BTESPView *esp;
@property(nonatomic, strong) BTMenu *menu;
@property(nonatomic, strong) CADisplayLink *link;
@end

@implementation BTOverlay

+ (instancetype)shared {
    static BTOverlay *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [BTOverlay new]; });
    return o;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect b = [UIScreen mainScreen].bounds;
        BTWindow *w = [[BTWindow alloc] initWithFrame:b];
        w.windowLevel = UIWindowLevelAlert + 100;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [UIViewController new];
        w.rootViewController.view.backgroundColor = [UIColor clearColor];
        self.window = w;

        self.esp = [[BTESPView alloc] initWithFrame:b];
        self.esp.backgroundColor = [UIColor clearColor];
        self.esp.opaque = NO;
        [w.rootViewController.view addSubview:self.esp];

        self.menu = [[BTMenu alloc] initWithFrame:CGRectMake(16, 60, 284, 400)];
        self.menu.hidden = !gCfg.drawMenu;
        [w.rootViewController.view addSubview:self.menu];

        UIButton *toggle = [UIButton buttonWithType:UIButtonTypeSystem];
        toggle.frame = CGRectMake(b.size.width - 54, 100, 44, 44);
        [toggle setTitle:@"BT" forState:UIControlStateNormal];
        toggle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45f];
        toggle.layer.cornerRadius = 22;
        [toggle addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
        [w.rootViewController.view addSubview:toggle];

        [w makeKeyAndVisible];

        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        self.link.preferredFramesPerSecond = 30;
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}

- (void)onToggle {
    gCfg.drawMenu = !gCfg.drawMenu;
    self.menu.hidden = !gCfg.drawMenu;
}

- (void)tick {
    [self.esp setNeedsDisplay];

    static NSTimeInterval lastUi = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastUi > 0.5) {
        lastUi = now;
        UILabel *st = (UILabel *)[self.menu viewWithTag:901];
        if (st && !self.menu.hidden) st.text = [BTMenu statusText];
    }
    if (gCfg.aim && gCfg.aimMode == 2 && gReady) {          // 持续跟随模式
        void *lp = currentPlayer();
        if (lp && pGetCurCamDir) {
            Vec3 origin = *(Vec3 *)((char *)lp + OFS_CTRL_BODY_POS);
            Target t;
            if (bestTarget(origin, pGetCurCamDir(lp), t)) aimPoint(lp, t.pos);
        }
    }
}

@end

/* ============================== 启动 ============================== */

static bool gHooked = false;

/* dylib 由主程序在启动早期加载，此时 UnityFramework 往往还没进内存。
   这里先 dlsym+dladdr，失败再主动 dlopen 一次；仍然失败就返回 0，由上层重试。 */
static uintptr_t resolveBase() {
    if (gBase) return gBase;
    void *sym = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    if (sym) {
        Dl_info info;
        if (dladdr(sym, &info) && info.dli_fbase) return (gBase = (uintptr_t)info.dli_fbase);
    }
    static const char *cands[] = {
        "@executable_path/Frameworks/UnityFramework.framework/UnityFramework",
        "Frameworks/UnityFramework.framework/UnityFramework",
        "UnityFramework.framework/UnityFramework",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        void *h = dlopen(cands[i], RTLD_LAZY | RTLD_NOLOAD);
        if (!h) h = dlopen(cands[i], RTLD_LAZY);
        if (!h) continue;
        Dl_info info;
        void *s2 = dlsym(h, "il2cpp_domain_get");
        if (s2 && dladdr(s2, &info) && info.dli_fbase) return (gBase = (uintptr_t)info.dli_fbase);
    }
    return 0;
}

static bool installHooks() {
    if (gHooked) return true;
    if (!resolveBase()) return false;

    MSHookFunction((void *)(gBase + RVA_DoShot), (void *)hook_DoShot, (void **)&orig_DoShot);
    MSHookFunction((void *)(gBase + RVA_Shots_Add), (void *)hook_ShotsAdd, (void **)&orig_ShotsAdd);
    MSHookFunction((void *)(gBase + RVA_Item_Update), (void *)hook_ItemUpdate, (void **)&orig_ItemUpdate);
    MSHookFunction((void *)(gBase + RVA_Bone_ProcessShot), (void *)hook_BoneProcessShot, (void **)&orig_BoneProcessShot);
    MSHookFunction((void *)(gBase + RVA_Bullets_MinusOne), (void *)hook_MinusOne, (void **)&orig_MinusOne);
    MSHookFunction((void *)(gBase + RVA_Bullets_GetCount), (void *)hook_GetCount, (void **)&orig_GetCount);
    MSHookFunction((void *)(gBase + RVA_CmdShot_Reliable), (void *)hook_CmdShotReliable, (void **)&orig_CmdShotReliable);
    MSHookFunction((void *)(gBase + RVA_CmdShot_Unrel), (void *)hook_CmdShotUnrel, (void **)&orig_CmdShotUnrel);

    gHooked = true;
    return true;
}

static bool initIl2cpp() {
    bindFn(il2.domain_get, "il2cpp_domain_get");
    bindFn(il2.domain_get_assemblies, "il2cpp_domain_get_assemblies");
    bindFn(il2.assembly_get_image, "il2cpp_assembly_get_image");
    bindFn(il2.image_get_name, "il2cpp_image_get_name");
    bindFn(il2.class_from_name, "il2cpp_class_from_name");
    bindFn(il2.class_get_method_from_name, "il2cpp_class_get_method_from_name");
    bindFn(il2.class_get_field_from_name, "il2cpp_class_get_field_from_name");
    bindFn(il2.field_get_offset, "il2cpp_field_get_offset");
    bindFn(il2.field_static_get_value, "il2cpp_field_static_get_value");
    bindFn(il2.object_get_class, "il2cpp_object_get_class");
    bindFn(il2.class_is_assignable_from, "il2cpp_class_is_assignable_from");
    if (!il2.domain_get || !il2.domain_get_assemblies) return false;

    gAsmCSharp = findImage("Assembly-CSharp.dll");
    if (!gAsmCSharp) return false;

    kControl = il2.class_from_name(gAsmCSharp, "", "Control");
    kPlayerControl = il2.class_from_name(gAsmCSharp, "", "PlayerControl");
    kShots = il2.class_from_name(gAsmCSharp, "", "Shots");
    if (!kControl || !kPlayerControl) return false;

    void *unity = findImage("UnityEngine.CoreModule.dll");
    if (unity) {
        kCamera = il2.class_from_name(unity, "UnityEngine", "Camera");
        kTransform = il2.class_from_name(unity, "UnityEngine", "Transform");
        kAnimator = il2.class_from_name(unity, "UnityEngine", "Animator");
        kScreen = il2.class_from_name(unity, "UnityEngine", "Screen");
    }

    fControls = il2.class_get_field_from_name(kControl, "controls");
    mGetCurrentPlayer = resolveMethod(kPlayerControl, "get_CurrentPlayer", 0);

    pGetCurCamDir = (GetCurCamDir_t)resolveMethod(kControl, "get_CurCamDir", 0);
    pSetCamDirByVector = (SetCamDirVec_t)resolveMethod(kControl, "SetCamDirByVector", 1);
    pSetCamDirByWorldPoint = (SetCamDirPoint_t)resolveMethod(kControl, "SetCamDirByWorldPoint", 1);

    if (kCamera) {
        pGetMainCam = (GetMainCam_t)resolveMethod(kCamera, "get_main", 0);
        pW2S = (W2S_t)resolveMethod(kCamera, "WorldToScreenPoint", 1);
    }
    if (kTransform) pGetPos = (GetPos_t)resolveMethod(kTransform, "get_position", 0);
    if (kAnimator) pGetBone = (void *(*)(void *, int))resolveMethod(kAnimator, "GetBoneTransform", 1);
    if (kScreen) {
        pScreenW = (GetInt_t)resolveMethod(kScreen, "get_width", 0);
        pScreenH = (GetInt_t)resolveMethod(kScreen, "get_height", 0);
    }

    gReady = true;
    return true;
}

static void bt_bootstrap() {
    /* 先等 UnityFramework 进内存再把钩子挂上（早期加载时它还不在） */
    for (int i = 0; i < 600 && !gHooked; i++) {
        if (installHooks()) break;
        usleep(200 * 1000);
    }
    for (int i = 0; i < 600 && !gReady; i++) {   // 最多等 60s，等 IL2CPP 域起来
        if (initIl2cpp()) break;
        usleep(250 * 1000);
    }
    [[BTOverlay shared] start];
}

__attribute__((constructor)) static void bt_entry() {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        bt_bootstrap();
    });
}
