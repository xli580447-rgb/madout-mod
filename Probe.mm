// Probe.dylib —— 只做一件事：证明注入的 dylib 能不能在游戏里活下来
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

static UILabel *gLabel = nil;

static void probe_log(NSString *s) {
    NSLog(@"[PROBE] %@", s);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bt_probe.log"];
    FILE *f = fopen(path.UTF8String, "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

__attribute__((constructor)) static void probe_entry(void) {
    probe_log(@"probe dylib loaded");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        probe_log(@"creating window");
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 500;
        w.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.35];
        UIViewController *vc = [UIViewController new];
        w.rootViewController = vc;

        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 320, 120)];
        l.numberOfLines = 0;
        l.textColor = [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:1];
        l.font = [UIFont boldSystemFontOfSize:20];
        l.text = @"PROBE OK\n注入成功";
        [vc.view addSubview:l];
        gLabel = l;
        [w makeKeyAndVisible];
        probe_log(@"window shown");
    });
}