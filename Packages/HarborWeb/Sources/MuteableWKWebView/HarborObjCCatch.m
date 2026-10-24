// Licensed under GPL-3.0. See LICENSE.
//
//  HarborObjCCatch.m
//  MuteableWKWebView
//

#import "HarborObjCCatch.h"

NSString * _Nullable HarborCatchObjCException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""];
    }
}
