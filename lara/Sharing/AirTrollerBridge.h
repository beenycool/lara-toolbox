//
//  AirTrollerBridge.h
//  lara
//
//  ObjC bridge for the AirTroller feature.
//
//  Everything in here talks to the *private* Sharing.framework classes
//  SFAirDropBrowser / SFAirDropNode with late-bound runtime lookups only:
//  no Sharing symbol is referenced, so a build where the class moved or a
//  selector was renamed still links and just reports "unsupported".
//
//  Reverse engineered on iPhone14,6 / iOS 26.0 (23A5308g), Mach-O
//  "Sharing": see docs/dev/airtroller-integration.md
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - runtime shapes of the private classes

/*!
    Compile-time "shape" of -[SFAirDropNode ...]. The real class never conforms
    to this protocol; it exists purely so the multi argument selector
    -startSendForBundleID:sessionID:items:description:previewImage:fromShareSheet:
    (7 arguments, too many for a comfortable Swift objc_msgSend cast) can be
    type checked here.
 */
@protocol AirTrollerNodeProtocol <NSObject>
@required
- (NSString *)displayName;
- (NSString *)realName;
- (NSString *)displayNameForLocale:(NSLocale *)locale;
- (BOOL)isDisabled;
- (BOOL)isMe;
- (nullable id)nodeIdentifier;
- (nullable NSString *)model;
- (nullable NSArray *)formattedHandles;
- (void)startSendForBundleID:(nullable NSString *)bundleID
                   sessionID:(nullable NSString *)sessionID
                       items:(NSArray *)items
                 description:(nullable NSString *)description
                previewImage:(nullable CGImageRef)previewImage
              fromShareSheet:(BOOL)fromShareSheet;
- (void)cancelSend;
- (void)handleOperationCallback:(nullable id)operation
                         event:(NSInteger)event
                   withResults:(nullable NSDictionary *)results;
@end

/*! Shape of -[SFAirDropBrowser ...]. Every method is @optional on purpose: the
    wrapper guards each call with -respondsToSelector: before using it. */
@protocol AirTrollerBrowserProtocol <NSObject>
@optional
- (void)start;
- (void)stop;
- (void)pause;
- (void)resume;
- (void)setSendingAppBundleID:(NSString *)bundleID;
- (void)setSessionID:(NSString *)sessionID;
- (void)setUrlsBeingShared:(NSArray *)urls;
- (void)setDelegate:(id)delegate;
- (NSArray *)people;
- (NSDictionary *)nodeIDToNode;
@end

/*!
    Best-effort mirror of the *optional* <SFAirDropBrowserDelegate> callbacks.
    Only the selector names that actually exist in the Sharing binary are
    implemented (browser:didInsertPersonAtIndex:, browser:didDeletePersonAtIndex:,
    browserDidChangePeople:, browserDidUpdateMePeople:knownPeople:unknownPeople:,
    browserDidUpdatePeople:). browserDidUpdatePeople: carries the discovered node
    list as its argument — it is the data source the share sheet itself uses.
 */
@protocol AirTrollerBrowserEvents <NSObject>
@optional
- (void)browserDidUpdateMePeople:(id)me knownPeople:(id)known unknownPeople:(id)unknown;
- (void)browserDidChangePeople:(id)people;
- (void)browserDidUpdatePeople:(id)people;
- (void)browser:(id)browser didInsertPersonAtIndex:(id)index;
- (void)browser:(id)browser didDeletePersonAtIndex:(id)index;
@end

#pragma mark - bridge

@interface AirTrollerBridge : NSObject

/// Fired on the browser callback queue whenever discovered people change.
@property (nonatomic, copy, nullable) void (^onDiscoveryChanged)(void);

@property (class, readonly, strong) AirTrollerBridge *shared;

/// Sharing.framework reachable + SFAirDropNode/-SFAirDropBrowser present.
+ (BOOL)isSupported;

/// Late-loads Sharing.framework (dlopen) if it is not resident yet.
+ (BOOL)ensureFrameworkLoaded;

/// Writes the small throw-away file that is handed to the target as items:.
+ (nullable NSURL *)preparePayloadFile;

/// Human readable reason for the last failed bridge call (nil when nothing failed).
@property (nonatomic, copy, nullable) NSString *lastError;

/// Diagnostics: how many times the framework's browser delegate callbacks fired,
/// and the node count in the most recent browserDidUpdatePeople:. If events stays
/// 0 while browsing, discovery is not reaching the framework at all.
@property (nonatomic, readonly) NSInteger delegateEventCount;
@property (nonatomic, readonly) NSInteger lastPeopleCount;

/// Name of an SFOperation event, e.g. 5 -> "Started".
/// Prefers the framework's own _SFOperationEventToString when it resolves.
+ (NSString *)nameForOperationEvent:(NSInteger)event;

/// Events that can be replayed synthetically without a real SFOperationRef.
/// (2/"AskUser" is excluded: it calls _SFOperationResume() on whatever we pass.)
+ (NSArray<NSNumber *> *)safeReplayEvents;

/// Starts the AirDrop browser (discovery). Safe to call more than once.
- (BOOL)startDiscoveryWithBundleID:(nullable NSString *)bundleID
                         sessionID:(nullable NSString *)sessionID
                  urlsBeingShared:(nullable NSArray<NSURL *> *)urls;

- (void)stopDiscovery;
- (BOOL)isDiscovering;

/// Dictionary per discovered node: name, realname, id, disabled, me, model, handles, node.
- (NSArray<NSDictionary *> *)targetSnapshot;

/// -[SFAirDropNode startSendForBundleID:sessionID:items:description:previewImage:fromShareSheet:]
- (BOOL)startSendToNode:(nullable NSObject *)node
               bundleID:(nullable NSString *)bundleID
              sessionID:(nullable NSString *)sessionID
                  items:(NSArray<NSURL *> *)items
            description:(nullable NSString *)description
           previewImage:(nullable CGImageRef)previewImage
         fromShareSheet:(BOOL)fromShareSheet;

/// -[SFAirDropNode cancelSend]
- (void)cancelSendToNode:(nullable NSObject *)node;

/// Delivers one synthetic event into -[SFAirDropNode handleOperationCallback:event:withResults:]
- (void)replayOperationEvent:(NSInteger)event
                withResults:(nullable id)results
                     onNode:(nullable NSObject *)node;

@end

NS_ASSUME_NONNULL_END
