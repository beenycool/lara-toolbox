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

// Defined in kexploit/pe/sbx.m. Declared here to avoid dragging the kernel
// headers into the Sharing bridge.
extern int sbx_drop_sandbox(void);
extern int sbx_restore_sandbox(void);
extern void sbx_dump_sandbox(void);
extern int sbx_adopt_sandbox_from_pid(pid_t pid);
extern pid_t sbx_pidof(const char *name);

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

// -[SFAirDropBrowser updateDiscoveredPeople] messages _delegate with this
// selector and NO respondsToSelector: guard (verified at 0x1a8f25d54 on
// 23A5308g), so a delegate that does not implement it is killed with
// "unrecognized selector" on the first browser callback. This method exists to
// keep that from happening.
- (void)browserWillChangePeople:(id)people {
    [self fire];
}

- (void)browserDidUpdateMePeople:(id)me knownPeople:(id)known unknownPeople:(id)unknown {
    [self fire];
}

- (void)browserDidChangePeople:(id)people {
    [self fire];
}

// Delivered to _batchDelegate only (ivar 0x38), never to _delegate: Apple's own
// share sheet installs it with -setBatchDelegate:, and it is the only callback
// that carries the discovered node list. The browser does fill
// -[SFAirDropBrowser people] on every callback as well (updateDiscoveredPeople
// writes ivar 0x28), so the poll is a second, valid path.
- (void)browserDidUpdatePeople:(id)people {
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

// The real type encodings are v32@0:8@16q24 - the index is an NSInteger.
- (void)browser:(id)browser didInsertPersonAtIndex:(NSInteger)index {
    [self fire];
}

- (void)browser:(id)browser didDeletePersonAtIndex:(NSInteger)index {
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

#pragma mark - mach service probe state

// Heap-owned so an XPC event handler never dereferences stack variables: the
// final invocation error routinely arrives *after*
// +probeMachService:timeout: has already returned, which is what killed the app.
@interface AirTrollerMachProbe : NSObject

@property (nonatomic, strong, nullable) dispatch_semaphore_t semaphore;
@property (nonatomic, assign) NSInteger code;
@property (nonatomic, copy, nullable) NSString *detail;

@end

@implementation AirTrollerMachProbe
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

#pragma mark - mach service probe

+ (NSString *)probeMachService:(NSString *)name timeout:(double)seconds {
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

    xpc_connection_t connection = createMachService(name.UTF8String, NULL, 0);
    if (connection == NULL) {
        return @"create returned NULL";
    }

    AirTrollerMachProbe *probe = [AirTrollerMachProbe new];
    probe.semaphore = dispatch_semaphore_create(0);

    // No message is sent: a sandbox/entitlement denial invalidates the
    // connection the moment it is resumed, so watching for that distinguishes
    // "blocked" from "reachable" without provoking the daemon.
    __weak AirTrollerMachProbe *weakProbe = probe;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        AirTrollerMachProbe *strong = weakProbe;
        if (strong == nil || xpc_get_type(event) != XPC_TYPE_ERROR) {
            return; // fired after this method returned - nothing left to update
        }

        if (event == XPC_ERROR_CONNECTION_INVALID) {
            strong.code = 1;
            strong.detail = @"connection invalid - sandbox/entitlement denied";
        } else if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
            strong.code = 2;
            strong.detail = @"connection interrupted";
        } else {
            const char *description = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
            strong.code = 3;
            strong.detail = [NSString stringWithFormat:@"xpc error: %s", description ?: "?"];
        }
        dispatch_semaphore_signal(strong.semaphore);
    });

    xpc_connection_resume(connection);
    dispatch_semaphore_wait(probe.semaphore,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
    xpc_connection_cancel(connection);

    NSString *detail = probe.detail;
    return detail != nil ? detail : @"reachable (connection stayed valid)";
}

+ (NSString *)probeSharingdReachability {
    return [self probeMachService:@"com.apple.sharingd" timeout:1.5];
}

/// Probes several services so a control case separates "this process cannot do
/// any global mach lookup" from "this specific service is denied".
+ (NSString *)probeMachServices {
    NSArray<NSString *> *names = @[
        @"com.apple.sharingd",
        @"com.apple.sharingd.nsxpc",
        @"com.apple.sharingd.paireddevice",
        @"com.apple.streamingzipservice",
        @"com.apple.system.notification_center",
    ];

    NSMutableString *summary = [NSMutableString string];
    for (NSString *name in names) {
        [summary appendFormat:@"\n  %@ -> %@", name, [self probeMachService:name timeout:0.4]];
    }
    return summary;
}

+ (NSString *)diagnoseSharingd {
    // Mach probes only: the sandbox walk is a separate step so that a crash
    // there can never take the probe results down with it.
    NSMutableString *summary = [NSMutableString string];
    [summary appendString:[self probeMachServices]];
    [summary appendFormat:@"\n  sharingd (full probe) -> %@", [self probeSharingdReachability]];
    return summary;
}

/// Walks this process's sandbox into the log. Returns a short status string.
+ (NSString *)dumpSandbox {
    sbx_dump_sandbox();
    return @"sandbox dumped to the log above";
}

#pragma mark reachability (borrowed sandbox window)

// Sharing.framework connects to com.apple.sharingd with
// xpc_connection_create_mach_service(..., flags 0) and the sandbox is consulted
// at connection creation. For a sideloaded app the profile has no
// (allow mach-lookup ...) rule for that name, and the entitlement that would
// grant it lives in the provisioning profile, which SideStore cannot produce.
//
// So the only way in is to borrow a profile that has the rule, for exactly the
// call that creates the connection: -[SFAirDropBrowser start] for discovery and
// each -startSendForBundleID:... for a send (every SFOperation creates its own
// connection at -Resume). The borrowed pointer is restored in a @finally, the
// donor is a system process that cannot exit mid-call, and the sandbox object is
// deliberately NOT refcount-bumped: the kext audit could not prove +0 is a
// refcount, and a skipped bump is exactly how the old code produced a dangling
// pointer.
static NSRecursiveLock *gReachLock = nil;
static NSString *gDonorName = nil;
static BOOL gReachableNormally = NO;
static BOOL gProbedNormally = NO;
static BOOL gDonorSearchFailed = NO;

+ (void)airtrollerReachSetup {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gReachLock = [NSRecursiveLock new];
    });
}

/// Ordered candidates: the share sheet process hosts the AirDrop UI, SpringBoard
/// hosts the cover-sheet share UI, sharingd itself normally registers the service
/// rather than looking it up.
+ (NSArray<NSString *> *)donorCandidates {
    return @[ @"ShareSheet", @"SpringBoard", @"sharingd" ];
}

+ (pid_t)firstReachableDonor {
    [self airtrollerReachSetup];

    if (gDonorName != nil) {
        pid_t pid = sbx_pidof(gDonorName.UTF8String);
        if (pid != 0) {
            return pid;
        }
        gDonorName = nil;
    }

    for (NSString *name in [self donorCandidates]) {
        pid_t pid = sbx_pidof(name.UTF8String);
        if (pid == 0) {
            continue;
        }
        if (sbx_adopt_sandbox_from_pid(pid) != 0) {
            continue;
        }
        NSString *probe = nil;
        @try {
            probe = [self probeMachService:@"com.apple.sharingd" timeout:0.6];
        } @finally {
            sbx_restore_sandbox();
        }
        if ([probe hasPrefix:@"reachable"]) {
            gDonorName = name;
            gDonorSearchFailed = NO;
            return pid;
        }
    }
    gDonorSearchFailed = YES;
    return 0;
}

/// Runs `block` with a sandbox that may reach sharingd, when one is needed.
+ (void)withBorrowedReachability:(dispatch_block_t)block {
    if (block == nil) {
        return;
    }
    [self airtrollerReachSetup];
    [gReachLock lock];
    @try {
        if (!gProbedNormally) {
            gProbedNormally = YES;
            gReachableNormally =
                [[self probeMachService:@"com.apple.sharingd" timeout:0.4] hasPrefix:@"reachable"];
        }
        if (gReachableNormally) {
            block();
            return;
        }

        // A failed search already cost three probe timeouts; don't repeat it on
        // every send. +adoptionLadder clears the flag when the user asks again.
        if (gDonorSearchFailed) {
            block();
            return;
        }

        pid_t donor = [self firstReachableDonor];
        if (donor == 0 || sbx_adopt_sandbox_from_pid(donor) != 0) {
            block();      // no donor: let the framework report the failure
            return;
        }
        @try {
            block();
        } @finally {
            sbx_restore_sandbox();
        }
    } @finally {
        [gReachLock unlock];
    }
}

#pragma mark sandbox adoption

+ (pid_t)pidOfProcess:(NSString *)name {
    if (name.length == 0) {
        return 0;
    }
    return sbx_pidof(name.UTF8String);
}

// Borrows a valid sandbox object from another process and probes inside the
// window. The pointer is ALWAYS restored: the old version left the borrow
// installed when it "did not help", which is how a foreign cred survives long
// enough to become a dangling pointer.
+ (NSString *)attemptSandboxAdoptionWithPID:(pid_t)pid {
    [self airtrollerReachSetup];
    [gReachLock lock];
    NSString *report = nil;
    @try {
        NSString *before = [self probeMachService:@"com.apple.sharingd" timeout:0.6];
        if ([before hasPrefix:@"reachable"]) {
            gReachableNormally = YES;
            report = [NSString stringWithFormat:@"already reachable (%@)", before];
            return report;
        }

        if (sbx_adopt_sandbox_from_pid(pid) != 0) {
            report = [NSString stringWithFormat:@"refused: pid %d did not pass the sandbox layout gate", pid];
            return report;
        }

        NSString *after = nil;
        @try {
            after = [self probeMachService:@"com.apple.sharingd" timeout:1.0];
        } @finally {
            sbx_restore_sandbox();
        }
        report = [NSString stringWithFormat:@"%@ after a one-shot borrow from pid %d (restored)",
                  after, pid];
    } @finally {
        [gReachLock unlock];
    }
    return report ?: @"adoption failed";
}

/// Tries the donor ladder in order. Each candidate is a windowed borrow, so a
/// wrong donor costs one probe and leaves no state behind.
+ (NSString *)adoptionLadder {
    gDonorSearchFailed = NO;
    NSMutableString *out = [NSMutableString string];
    for (NSString *name in [self donorCandidates]) {
        pid_t pid = sbx_pidof(name.UTF8String);
        if (pid == 0) {
            [out appendFormat:@"\n  %@: not running", name];
            continue;
        }
        [out appendFormat:@"\n  %@ (pid %d): %@", name, pid,
                          [self attemptSandboxAdoptionWithPID:pid]];
    }
    return out;
}

+ (NSString *)attemptSharingdSandboxBypass {
    NSString *before = [self probeSharingdReachability];
    if ([before hasPrefix:@"reachable"]) {
        return [NSString stringWithFormat:@"already reachable (%@)", before];
    }

    if (sbx_drop_sandbox() != 0) {
        return @"could not drop the sandbox";
    }

    NSString *after = [self probeSharingdReachability];
    if ([after hasPrefix:@"reachable"]) {
        return [NSString stringWithFormat:@"SUCCESS - sharingd reachable after dropping the sandbox (%@)", after];
    }

    sbx_restore_sandbox();
    return [NSString stringWithFormat:@"still blocked after dropping the sandbox (%@); sandbox restored", after];
}

#pragma mark payload

+ (nullable NSURL *)preparePayloadFile {
    // A picture, not a text file: the target's prompt shows the item preview,
    // and the original AirTroller sent an image for exactly that reason.
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AirTroller-payload.png"]];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(256, 256) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor blackColor] setFill];
        UIRectFill(CGRectMake(0, 0, 256, 256));
        [[UIColor systemOrangeColor] setFill];
        UIRectFill(CGRectMake(24, 24, 208, 208));
        [[UIColor blackColor] setFill];
        UIRectFill(CGRectMake(56, 56, 144, 144));
    }];
    NSData *png = UIImagePNGRepresentation(image);
    if (png == nil || ![png writeToURL:url atomically:YES]) {
        AirTrollerBridge.shared.lastError = @"could not write the AirTroller payload PNG";
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
        // Apple's own share sheet installs only -setBatchDelegate: (its
        // SFAirDropActivityViewController never sets -delegate). The batch
        // delegate is the only channel that receives the people list, and the
        // plain delegate is messaged browserWillChangePeople: with no guard, so
        // using it would crash on the first callback.
        if ([browser respondsToSelector:@selector(setBatchDelegate:)]) {
            [browser setBatchDelegate:self.browserDelegate];
        }

        self.browser = browser;

        if (![browser respondsToSelector:@selector(start)]) {
            self.browser = nil;
            self.lastError = @"-[SFAirDropBrowser start] missing";
            return NO;
        }

        // -start creates the XPC connection to com.apple.sharingd, and the
        // sandbox is consulted at connection creation. Borrow a reachable
        // profile for exactly that call, then restore it immediately.
        [AirTrollerBridge withBorrowedReachability:^{
            [browser start];
        }];
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
        if ([browser respondsToSelector:@selector(setBatchDelegate:)]) {
            [browser setBatchDelegate:nil];
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
            id raw = [node formattedHandles];
            if ([raw isKindOfClass:[NSArray class]]) {
                handles = [(NSArray *)raw componentsJoinedByString:@", "];
            } else if ([raw isKindOfClass:[NSString class]]) {
                handles = raw;
            }
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

// startSend/cancelSend take no locks, and the framework delivers its own
// operation callbacks - including its own event-4/9/10 cancelSend - on
// __dispatch_main_q. Calling them from the AirTroller worker races that
// callback: two cancelSends can interleave between the load and the clear of
// _sender and double-release the operation. Every node call goes through here.
static void AirTrollerOnMainSync(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

+ (Ivar)airtrollerSenderIvar {
    static Ivar ivar = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class nodeClass = NSClassFromString(@"SFAirDropNode");
        ivar = nodeClass != Nil ? class_getInstanceVariable(nodeClass, "_sender") : NULL;
    });
    return ivar;
}

+ (BOOL)nodeHasLiveOperation:(NSObject *)node {
    Ivar ivar = [self airtrollerSenderIvar];
    if (node == nil || ivar == NULL) {
        return NO;
    }
    uint8_t *base = (uint8_t *)(__bridge void *)node + ivar_getOffset(ivar);
    return *(void **)base != NULL;
}

+ (NSInteger)lastOperationEventForNode:(NSObject *)node {
    // __SFOperationNotifyClient stores the event number at op+0xb0 before it
    // invokes the client callback, so the node's live _sender exposes the event
    // machine even though SFAirDropNode owns the callback.
    Ivar ivar = [self airtrollerSenderIvar];
    if (node == nil || ivar == NULL) {
        return -1;
    }
    uint8_t *base = (uint8_t *)(__bridge void *)node + ivar_getOffset(ivar);
    void *operation = *(void **)base;
    if (operation == NULL) {
        return -1;
    }
    uint32_t event = *(uint32_t *)((uint8_t *)operation + 0xb0);
    return (NSInteger)event;
}

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

    __block BOOL started = NO;
    __block NSString *failure = nil;

    AirTrollerOnMainSync(^{
        id<AirTrollerNodeProtocol> target = (id<AirTrollerNodeProtocol>)node;
        @try {
            // The framework silently refuses a send while _sender is non-NULL
            // (cbnz at 0x1a8f29bf4), and a cycle interrupted during its trigger
            // window can leave one behind. cancelSend is a no-op on NULL, so
            // this recovery is free.
            [target cancelSend];

            [AirTrollerBridge withBorrowedReachability:^{
                [target startSendForBundleID:bundleID
                                   sessionID:sessionID
                                       items:items
                                 description:description
                                previewImage:previewImage
                              fromShareSheet:fromShareSheet];
            }];

            started = [AirTrollerBridge nodeHasLiveOperation:node];
            if (!started) {
                failure = @"startSend left no live operation";
            }
        } @catch (NSException *exception) {
            failure = [NSString stringWithFormat:@"startSend raised %@", exception.reason ?: @"unknown"];
        }
    });

    self.lastError = started ? @"" : (failure ?: @"startSend did not start");
    return started;
}

- (void)cancelSendToNode:(NSObject *)node {
    if (node == nil || ![node respondsToSelector:@selector(cancelSend)]) {
        return;
    }
    AirTrollerOnMainSync(^{
        @try {
            [(id<AirTrollerNodeProtocol>)node cancelSend];
        } @catch (NSException *exception) {
            // nothing sensible to do, the operation is either gone or already dead
        }
    });
}

#pragma mark operation events

- (void)replayOperationEvent:(NSInteger)event
                withResults:(id)results
                     onNode:(NSObject *)node {
    SEL selector = @selector(handleOperationCallback:event:withResults:);

    if (node == nil || ![node respondsToSelector:selector]) {
        return;
    }
    // Event 2 (AskUser) calls _SFOperationResume(first argument): with no live
    // SFOperationRef that writes a pthread mutex over the node's
    // _endpointUUID/_realName block and then sends an XPC message through
    // _derivedIntentIdentifier. There is no safe synthetic value, so refuse it
    // here as well as in +safeReplayEvents.
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
