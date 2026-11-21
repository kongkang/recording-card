#import "RCObjCCatch.h"

NSException *_Nullable RCObjCCatchException(void (^NS_NOESCAPE block)(void)) {
  @try {
    block();
    return nil;
  } @catch (NSException *exception) {
    return exception;
  }
}
