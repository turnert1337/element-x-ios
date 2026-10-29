//
// TJ fork: Duo runtime bootstrap for upstream's UI-test mock fixtures (Debug simulator only).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// `UI_TESTS_SCREEN=<fixture>` makes Application.init build UITestsAppCoordinator, which never calls
// AppHooks.setUp(), so the TJ Duo runtime (probe + fold-proxy driver) would never start. This +load only
// registers a did-finish-launching observer and calls the Swift entry point by name (no generated header).
// It does nothing unless UI_TESTS_SCREEN is set, and it is compiled out of device and Release builds.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if DEBUG && TARGET_OS_SIMULATOR

@protocol TJDuoBootstrapping
+ (void)tjStartForMockSession;
@end

@interface TJDuoBootstrapLoader : NSObject
@end

@implementation TJDuoBootstrapLoader

+ (void)load {
    if (NSProcessInfo.processInfo.environment[@"UI_TESTS_SCREEN"] == nil) {
        return;
    }
    __block id token = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                                       object:nil
                                                                        queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:token];
        Class bootstrap = NSClassFromString(@"TJDuoBootstrap");
        if ([bootstrap respondsToSelector:@selector(tjStartForMockSession)]) {
            [(Class<TJDuoBootstrapping>)bootstrap tjStartForMockSession];
        }
    }];
}

@end

#endif
