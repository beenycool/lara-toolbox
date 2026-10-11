//
//  AirTrollerBridge.m
//  lara
//
//  ObjC half of AirTroller. All Sharing.framework access goes through
//  NSClassFromString + -respondsToSelector:, nothing is linked by symbol, so a
//  different iOS build degrades to "unsupported" instead of failing to launch.
//

#import "AirTrollerBridge.h"
#import "lara-Bridging-Header.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>

#pragma mark - browser delegate (module private)

@interface AirTrollerBrowserDelegate : NSObject <AirTrollerBrowserEvents>

@property (nonatomic, copy, nullable) void (^onPeopleChanged)(void);
@property (nonatomic, assign) NSInteger eventCount;
@property (nonatomic, assign) NSInteger lastPeopleCount;

- (NSArray *)peopleSnapshot;

@end

@implementation AirTrollerBrowserDelegate {
    NSArray *_lastPeople;
}

- (void)browserDidUpdateMePeople:(id)me knownPeople:(id)known unknownPeople:(id)unknown {
    [self fire];
}

- (void)browserDidChangePeople:(id)people {
    [self fire];
}

- (void)browserDidUpdatePeople:(id)people {
    // This callback is the only place the node list is delivered: the framework
    // hands it to the delegate as an argument and never fills
    // -[SFAirDropBrowser people] on its own (updateDiscoveredPeople has no
    // internal caller). Stash it; the poll reads this copy.
    if ([people isKindOfClass:[NSArray class]]) {
        @synchronized (self) {
            _lastPeople = [(NSArray *)people copy];
            _lastPeopleCount = (NSInteger)_lastPeople.count;
        }
    }
    [self fire];
}

- (NSArray *)peopleSnapshot {
    @synchronized (self) {
        return _lastPeople;
    }
}

- (void)browser:(id)browser didInsertPersonAtIndex:(id)index {
    [self fire];
}

- (void)browser:(id)browser didDeletePersonAtIndex:(id)index {
    [self fire];
}

- (void)fire {
    @synchronized (self) {
        _eventCount = _eventCount + 1;
    }
    void (^block)(void) = self.onPeopleChanged;
    if (block != NULL) {
        block();
    }
}

@end

#pragma mark - bridge

@interface AirTrollerBridge ()

@property (nonatomic, strong, nullable) id<AirTrollerBrowserProtocol> browser;
@property (nonatomic, strong, nullable) AirTrollerBrowserDelegate *browserDelegate;

- (void)handlePeopleChanged;
- (NSDictionary *)detailsForNode:(id)node;

@end

@implementation AirTrollerBridge

#pragma mark life cycle

+ (instancetype)shared {
    static AirTrollerBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [AirTrollerBridge new];
    });
    return instance;
}

+ (BOOL)ensureFrameworkLoaded {
    static BOOL loaded = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(@"SFAirDropBrowser") != Nil) {
            loaded = YES;
            return;
        }
        // Normally Sharing is already resident (UIKit links it), but a
        // sideloaded build may reach this path first.
        void *handle = dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW);
        if (handle == NULL) {
            NSLog(@"[AirTroller] dlopen(Sharing) failed: %s", dlerror());
            return;
        }
        loaded = NSClassFromString(@"SFAirDropBrowser") != Nil;
    });
    return loaded;
}

+ (BOOL)isSupported {
    if (![self ensureFrameworkLoaded]) {
        return NO;
    }

    Class browserClass = NSClassFromString(@"SFAirDropBrowser");
    Class nodeClass = NSClassFromString(@"SFAirDropNode");
    if (browserClass == Nil || nodeClass == Nil) {
        return NO;
    }
    if (![browserClass instancesRespondToSelector:@selector(start)]) {
        return NO;
    }
    if (![nodeClass instancesRespondToSelector:@selector(startSendForBundleID:sessionID:items:description:previewImage:fromShareSheet:)]) {
        return NO;
    }
    if (![nodeClass instancesRespondToSelector:@selector(cancelSend)]) {
        return NO;
    }
    return YES;
}

#pragma mark diagnostics

+ (NSString *)probeSharingdReachability {
    // The SDK marks xpc_connection_create_mach_service unavailable on iOS, but
    // the symbol is present at runtime, so resolve it dynamically.
    typedef xpc_connection_t (*AirTrollerMachServiceFunction)(const char *, dispatch_queue_t, uint64_t);
    static AirTrollerMachServiceFunction createMachService = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createMachService = (AirTrollerMachServiceFunction)dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    });
    if (createMachService == NULL) {
        return @"xpc_connection_create_mach_service symbol missing";
    }

    xpc_connection_t connection = createMachService("com.apple.sharingd", NULL, 0);
    if (connection == NULL) {
        return @"xpc_connection_create_mach_service returned NULL";
    }

    // No message is sent: a sandbox/entitlement denial invalidates the
    // connection the moment it is resumed, so watching for that distinguishes
    // "blocked" from "reachable" without provoking sharingd.
    __block NSString *status = @"reachable (connection stayed valid)";
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_ERROR) {
            return;
        }
        if (event == XPC_ERROR_CONNECTION_INVALID) {
            status = @"connection invalid - sandbox/entitlement denied";
        } else if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
            status = @"connection interrupted";
        } else {
            const char *description = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
            status = [NSString stringWithFormat:@"xpc error: %s", description ?: "?"];
        }
        dispatch_semaphore_signal(semaphore);
    });

    xpc_connection_resume(connection);
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
    xpc_connection_cancel(connection);
    return status;
}

#pragma mark payload

+ (nullable NSURL *)preparePayloadFile {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AirTroller-payload.txt"]];
    NSString *contents = [NSString stringWithFormat:@"AirTroller test payload (%@)\n", [NSDate date]];
    if (![contents writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        AirTrollerBridge.shared.lastError = @"could not write the AirTroller payload file";
        return nil;
    }
    return url;
}

#pragma mark discovery

- (BOOL)startDiscoveryWithBundleID:(NSString *)bundleID
                         sessionID:(NSString *)sessionID
                  urlsBeingShared:(NSArray<NSURL *> *)urls {
    if (![AirTrollerBridge isSupported]) {
        self.lastError = @"SFAirDropBrowser/SFAirDropNode unavailable on this build";
        return NO;
    }
    if (self.browser != nil) {
        return YES;
    }

    @synchronized (self) {
        if (self.browser != nil) {
            return YES;
        }

        Class browserClass = NSClassFromString(@"SFAirDropBrowser");
        id<AirTrollerBrowserProtocol> browser = (id<AirTrollerBrowserProtocol>)[[browserClass alloc] init];
        if (browser == nil) {
            self.lastError = @"-[SFAirDropBrowser init] returned nil";
            return NO;
        }

        if (bundleID.length > 0 && [browser respondsToSelector:@selector(setSendingAppBundleID:)]) {
            [browser setSendingAppBundleID:bundleID];
        }
        if (sessionID.length > 0 && [browser respondsToSelector:@selector(setSessionID:)]) {
            [browser setSessionID:sessionID];
        }
        if (urls.count > 0 && [browser respondsToSelector:@selector(setUrlsBeingShared:)]) {
            [browser setUrlsBeingShared:urls];
        }

        if (self.browserDelegate == nil) {
            self.browserDelegate = [AirTrollerBrowserDelegate new];
            __weak typeof(self) weakSelf = self;
            self.browserDelegate.onPeopleChanged = ^{
                [weakSelf handlePeopleChanged];
            };
        }
        if ([browser respondsToSelector:@selector(setDelegate:)]) {
            [browser setDelegate:self.browserDelegate];
        }

        self.browser = browser;

        if (![browser respondsToSelector:@selector(start)]) {
            self.browser = nil;
            self.lastError = @"-[SFAirDropBrowser start] missing";
            return NO;
        }

        [browser start];
    }

    self.lastError = @"";
    return YES;
}

- (void)stopDiscovery {
    @synchronized (self) {
        id<AirTrollerBrowserProtocol> browser = self.browser;
        if (browser == nil) {
            return;
        }
        if ([browser respondsToSelector:@selector(setDelegate:)]) {
            [browser setDelegate:nil];
        }
        if ([browser respondsToSelector:@selector(stop)]) {
            [browser stop];
        }
        self.browser = nil;
    }
}

- (BOOL)isDiscovering {
    return self.browser != nil;
}

- (NSInteger)delegateEventCount {
    return self.browserDelegate.eventCount;
}

- (NSInteger)lastPeopleCount {
    return self.browserDelegate.lastPeopleCount;
}

- (void)handlePeopleChanged {
    void (^block)(void) = self.onDiscoveryChanged;
    if (block != NULL) {
        block();
    }
}

#pragma mark snapshot

- (NSArray<NSDictionary *> *)targetSnapshot {
    NSMutableArray<NSDictionary *> *snapshot = [NSMutableArray array];

    @synchronized (self) {
        id<AirTrollerBrowserProtocol> browser = self.browser;
        if (browser == nil) {
            return snapshot;
        }
        if (![browser respondsToSelector:@selector(people)]) {
            return snapshot;
        }

        // The framework delivers discovered nodes to the delegate in
        // browserDidUpdatePeople: and does NOT populate -[SFAirDropBrowser people]
        // itself. Calling -updateDiscoveredPeople here runs a mutation off the
        // framework's own queue and crashes, so never call it — use the copy the
        // delegate captured, and only fall back to the getter if it is empty.
        NSArray *people = [self.browserDelegate peopleSnapshot];
        if (![people isKindOfClass:[NSArray class]] || people.count == 0) {
            NSArray *direct = [browser people];
            if ([direct isKindOfClass:[NSArray class]] && direct.count > 0) {
                people = direct;
            }
        }
        if (![people isKindOfClass:[NSArray class]]) {
            return snapshot;
        }

        for (id person in people) {
            if (![person respondsToSelector:@selector(cancelSend)]) {
                continue;
            }
            NSDictionary *details = [self detailsForNode:person];
            if (details != nil) {
                [snapshot addObject:details];
            }
        }
    }

    return snapshot;
}

- (NSDictionary *)detailsForNode:(id)node {
    if (node == nil) {
        return nil;
    }

    NSString *displayName = nil;
    NSString *realName = nil;
    NSString *identifier = nil;
    NSString *model = nil;
    NSString *handles = nil;
    BOOL disabled = NO;
    BOOL isMe = NO;

    @try {
        if ([node respondsToSelector:@selector(displayNameForLocale:)]) {
            displayName = [node displayNameForLocale:[NSLocale currentLocale]];
        }
    } @catch (NSException *exception) {
        displayName = nil;
    }

    if (displayName.length == 0 && [node respondsToSelector:@selector(displayName)]) {
        @try {
            displayName = [node displayName];
        } @catch (NSException *exception) {
            displayName = nil;
        }
    }

    @try {
        if ([node respondsToSelector:@selector(realName)]) {
            realName = [node realName];
        }
        if ([node respondsToSelector:@selector(nodeIdentifier)]) {
            id nodeID = [node nodeIdentifier];
            if ([nodeID isKindOfClass:[NSUUID class]]) {
                identifier = [(NSUUID *)nodeID UUIDString];
            } else if ([nodeID isKindOfClass:[NSString class]]) {
                identifier = (NSString *)nodeID;
            }
        }
        if ([node respondsToSelector:@selector(model)]) {
            model = [node model];
        }
        if ([node respondsToSelector:@selector(formattedHandles)]) {
            handles = [node formattedHandles];
        }
        if ([node respondsToSelector:@selector(isDisabled)]) {
            disabled = [node isDisabled];
        }
        if ([node respondsToSelector:@selector(isMe)]) {
            isMe = [node isMe];
        }
    } @catch (NSException *exception) {
        // keep whatever we already collected
    }

    if (identifier.length == 0) {
        identifier = [NSString stringWithFormat:@"ptr-%p", node];
    }

    return @{
        @"name": displayName.length > 0 ? displayName : @"(unnamed)",
        @"realname": realName != nil ? realName : @"",
        @"id": identifier,
        @"disabled": @(disabled),
        @"me": @(isMe),
        @"model": model != nil ? model : @"",
        @"handles": handles != nil ? handles : @"",
        @"node": node,
    };
}

#pragma mark send / cancel

- (BOOL)startSendToNode:(NSObject *)node
               bundleID:(NSString *)bundleID
              sessionID:(NSString *)sessionID
                  items:(NSArray<NSURL *> *)items
            description:(NSString *)description
           previewImage:(CGImageRef)previewImage
         fromShareSheet:(BOOL)fromShareSheet {
    SEL selector = @selector(startSendForBundleID:sessionID:items:description:previewImage:fromShareSheet:);

    if (node == nil || ![node respondsToSelector:selector]) {
        self.lastError = @"target is gone or the node selector is missing";
        return NO;
    }
    if (items.count == 0) {
        self.lastError = @"no items to send";
        return NO;
    }

    id<AirTrollerNodeProtocol> target = (id<AirTrollerNodeProtocol>)node;
    @try {
        [target startSendForBundleID:bundleID
                          sessionID:sessionID
                              items:items
                        description:description
                       previewImage:previewImage
                     fromShareSheet:fromShareSheet];
    } @catch (NSException *exception) {
        self.lastError = [NSString stringWithFormat:@"startSend raised %@", exception.reason ?: @"unknown"];
        return NO;
    }

    self.lastError = @"";
    return YES;
}

- (void)cancelSendToNode:(NSObject *)node {
    if (node == nil || ![node respondsToSelector:@selector(cancelSend)]) {
        return;
    }
    @try {
        [(id<AirTrollerNodeProtocol>)node cancelSend];
    } @catch (NSException *exception) {
        // nothing sensible to do, the operation is either gone or already dead
    }
}

#pragma mark operation events

- (void)replayOperationEvent:(NSInteger)event
                withResults:(id)results
                     onNode:(NSObject *)node {
    SEL selector = @selector(handleOperationCallback:event:withResults:);

    if (node == nil || ![node respondsToSelector:selector]) {
        return;
    }
    // The framework's own callback is (operation, event, results); with no live
    // SFOperationRef the first argument is only meaningful for event 2, which is
    // why replay skips it (see +safeReplayEvents).
    id payload = (results != nil) ? results : node;
    @try {
        [(id<AirTrollerNodeProtocol>)node handleOperationCallback:payload event:event withResults:payload];
    } @catch (NSException *exception) {
        // ignore
    }
}

#pragma mark event names

typedef CFStringRef (*AirTrollerEventNameFunction)(NSInteger);

+ (NSString *)eventNameFromFrameworkSymbol:(NSInteger)event {
    static AirTrollerEventNameFunction function = NULL;
    static BOOL resolved = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (AirTrollerEventNameFunction)dlsym(RTLD_DEFAULT, "_SFOperationEventToString");
        resolved = (function != NULL);
    });

    if (!resolved || function == NULL) {
        return nil;
    }

    CFStringRef name = function(event);
    if (name == NULL) {
        return nil;
    }
    return (__bridge NSString *)name;
}

+ (NSString *)nameForOperationEvent:(NSInteger)event {
    NSString *fromFramework = [self eventNameFromFrameworkSymbol:event];
    if (fromFramework.length > 0) {
        return fromFramework;
    }

    // Decoded from PTR_cf_NewOperation_1e7a850a8 (the table _SFOperationEventToString
    // indexes) in the iOS 26.0 Sharing binary.
    static NSArray<NSString *> *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @[
            @"",              // 0
            @"NewOperation",  // 1
            @"AskUser",       // 2
            @"WaitForAnswer", // 3
            @"Cancelled",     // 4
            @"Started",       // 5
            @"Preprocess",    // 6
            @"Progress",      // 7
            @"Postprocess",   // 8
            @"Finished",      // 9
            @"ErrorOccured",  // 10 (framework misspelling, keep it)
            @"Connecting",    // 11
            @"Information",   // 12
            @"Conflict",      // 13
            @"Blocked",       // 14
            @"Converting",    // 15
        ];
    });

    if (event >= 1 && (NSUInteger)event < table.count) {
        return table[event];
    }
    return @"Unknown";
}

+ (NSArray<NSNumber *> *)safeReplayEvents {
    // 2 / "AskUser" resumes an SFOperationRef through _SFOperationResume(); with
    // no live operation that is a crash, so it is never replayed.
    NSMutableArray<NSNumber *> *events = [NSMutableArray array];
    for (NSInteger event = 0; event <= 16; event++) {
        if (event == 2) {
            continue;
        }
        [events addObject:@(event)];
    }
    return events;
}

@end
