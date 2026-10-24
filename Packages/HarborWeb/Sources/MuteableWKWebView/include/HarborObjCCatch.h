// Licensed under GPL-3.0. See LICENSE.
//
//  HarborObjCCatch.h
//  MuteableWKWebView
//
//  Swift cannot catch an Objective-C exception. One that unwinds through Swift async frames leaves
//  the main actor's executor pointing at a dead stack frame, and from then on no main-actor task
//  runs: the app looks idle and never answers. Code that calls private AppKit or WebKit methods
//  (which may throw on input they did not expect) runs its call inside this instead.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, returning nil, or the exception's name and reason when it threw one.
FOUNDATION_EXPORT NSString * _Nullable HarborCatchObjCException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
