#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// HealthKit 会用 NSException 打断非法授权请求；Swift 捕不到，必须走 ObjC @try/@catch。
FOUNDATION_EXPORT NSException *_Nullable RCObjCCatchException(void (^NS_NOESCAPE block)(void));

NS_ASSUME_NONNULL_END
