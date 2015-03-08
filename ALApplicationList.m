#import "ALApplicationList-private.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <SpringBoard/SpringBoard.h>
#import <CaptainHook/CaptainHook.h>
#import <dlfcn.h>

#define ROCKETBOOTSTRAP_LOAD_DYNAMIC
#import "LightMessaging/LightMessaging.h"

CHDeclareClass(SBApplicationController);
CHDeclareClass(SBIconModel);
CHDeclareClass(SBIconViewMap);

@interface SBIconViewMap : NSObject {
	SBIconModel *_model;
	// ...
}
+ (SBIconViewMap *)switcherMap;
+ (SBIconViewMap *)homescreenMap;
- (SBIconModel *)iconModel;
@end

@interface UIImage (Private)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier roleIdentifier:(NSString *)roleIdentifier format:(int)format scale:(CGFloat)scale;
@end


NSString *const ALIconLoadedNotification = @"ALIconLoadedNotification";
NSString *const ALDisplayIdentifierKey = @"ALDisplayIdentifier";
NSString *const ALIconSizeKey = @"ALIconSize";

enum {
	ALMessageIdGetApplications,
	ALMessageIdIconForSize,
	ALMessageIdValueForKey,
	ALMessageIdValueForKeyPath,
	ALMessageIdGetApplicationCount
};

static LMConnection connection = {
	MACH_PORT_NULL,
	"applist.datasource"
};

@interface SBIconModel ()
- (SBApplicationIcon *)applicationIconForDisplayIdentifier:(NSString *)displayIdentifier;
@end

@interface SBIconModel (iOS8)
- (SBApplicationIcon *)applicationIconForBundleIdentifier:(NSString *)bundleIdentifier;
@end

__attribute__((visibility("hidden")))
@interface ALApplicationListImpl : ALApplicationList
@end

static ALApplicationList *sharedApplicationList;

typedef enum {
	LADirectAPINone,
	LADirectAPIApplicationIconImageForBundleIdentifier,
	LADirectAPIApplicationIconImageForBundleIdentifierRoleIdentifier,
} LADirectAPI;
static LADirectAPI supportedDirectAPI;

@implementation ALApplicationList

+ (void)initialize
{
	if (self == [ALApplicationList class] && !CHClass(SBIconModel)) {
		sharedApplicationList = [[self alloc] init];
	}
}

+ (ALApplicationList *)sharedApplicationList
{
	return sharedApplicationList;
}

extern CFTypeRef MGCopyAnswer(CFStringRef query) __attribute__((weak_import));

static BOOL IsIpad(void)
{
	BOOL result = NO;
	if (&MGCopyAnswer != NULL) {
		CFNumberRef answer = MGCopyAnswer(CFSTR("ipad"));
		if (answer) {
			result = [(id)answer boolValue];
			CFRelease(answer);
		}
	}
	return result;
}

- (id)init
{
	if ((self = [super init])) {
		if (sharedApplicationList) {
			[self release];
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Only one instance of ALApplicationList is permitted at a time! Use [ALApplicationList sharedApplicationList] instead." userInfo:nil];
		}
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		cachedIcons = [[NSMutableDictionary alloc] init];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
		[pool drain];
		if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
			// Workaround iOS 7's fake retina mode bugs on iPad
			if ((kCFCoreFoundationVersionNumber < 800.00) || ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) || !IsIpad())
				supportedDirectAPI = LADirectAPIApplicationIconImageForBundleIdentifier;
		} else if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:roleIdentifier:format:scale:)]) {
			supportedDirectAPI = LADirectAPIApplicationIconImageForBundleIdentifierRoleIdentifier;
		}
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[cachedIcons release];
	[super dealloc];
}

- (NSInteger)applicationCount
{
	LMResponseBuffer buffer;
	if (LMConnectionSendTwoWay(&connection, ALMessageIdGetApplicationCount, NULL, 0, &buffer))
		return 0;
	return LMResponseConsumeInteger(&buffer);
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<ALApplicationList: %p applicationCount=%ld>", self, (long)self.applicationCount];
}

- (void)didReceiveMemoryWarning
{
	OSSpinLockLock(&spinLock);
	[cachedIcons removeAllObjects];
	OSSpinLockUnlock(&spinLock);
}

- (NSDictionary *)applications
{
	return [self applicationsFilteredUsingPredicate:nil];
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate
{
	LMResponseBuffer buffer;
	if (LMConnectionSendTwoWayData(&connection, ALMessageIdGetApplications, (CFDataRef)[NSKeyedArchiver archivedDataWithRootObject:predicate], &buffer))
		return nil;
	id result = LMResponseConsumePropertyList(&buffer);
	return [result isKindOfClass:[NSDictionary class]] ? result : nil;
}

static NSInteger DictionaryTextComparator(id a, id b, void *context)
{
	return [[(NSDictionary *)context objectForKey:a] localizedCaseInsensitiveCompare:[(NSDictionary *)context objectForKey:b]];
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate onlyVisible:(BOOL)onlyVisible titleSortedIdentifiers:(NSArray **)outSortedByTitle
{
	NSDictionary *result = [self applicationsFilteredUsingPredicate:predicate];
	if (onlyVisible) {
		// Filter out hidden apps
		NSMutableDictionary *copy = [[result mutableCopy] autorelease];
		[copy removeObjectsForKeys:[self _hiddenDisplayIdentifiers]];
		result = copy;
	}
	if (outSortedByTitle) {
		// Generate a sorted list of apps
		*outSortedByTitle = [[result allKeys] sortedArrayUsingFunction:DictionaryTextComparator context:result];
	}
	return result;
}

- (id)valueForKeyPath:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	if (!keyPath || !displayIdentifier)
		return nil;
	LMResponseBuffer buffer;
	if (LMConnectionSendTwoWayPropertyList(&connection, ALMessageIdValueForKeyPath, [NSDictionary dictionaryWithObjectsAndKeys:keyPath, @"key", displayIdentifier, @"displayIdentifier", nil], &buffer))
		return nil;
	return LMResponseConsumePropertyList(&buffer);
}

- (id)valueForKey:(NSString *)key forDisplayIdentifier:(NSString *)displayIdentifier
{
	if (!key || !displayIdentifier)
		return nil;
	LMResponseBuffer buffer;
	if (LMConnectionSendTwoWayPropertyList(&connection, ALMessageIdValueForKey, [NSDictionary dictionaryWithObjectsAndKeys:key, @"key", displayIdentifier, @"displayIdentifier", nil], &buffer))
		return nil;
	return LMResponseConsumePropertyList(&buffer);
}

static NSArray *hiddenDisplayIdentifiers;

- (NSArray *)_hiddenDisplayIdentifiers
{
	OSSpinLockLock(&spinLock);
	NSArray *result = hiddenDisplayIdentifiers;
	if (!result) {
		result = [[NSArray alloc] initWithObjects:
			@"com.apple.AdSheet",
			@"com.apple.AdSheetPhone",
			@"com.apple.AdSheetPad",
			@"com.apple.DataActivation",
			@"com.apple.DemoApp",
			@"com.apple.Diagnostics",
			@"com.apple.fieldtest",
			@"com.apple.iosdiagnostics",
			@"com.apple.iphoneos.iPodOut",
			@"com.apple.TrustMe",
			@"com.apple.WebSheet",
			@"com.apple.springboard",
			@"com.apple.purplebuddy",
			@"com.apple.datadetectors.DDActionsService",
			@"com.apple.FacebookAccountMigrationDialog",
			@"com.apple.iad.iAdOptOut",
			@"com.apple.ios.StoreKitUIService",
			@"com.apple.TextInput.kbd",
			@"com.apple.MailCompositionService",
			@"com.apple.mobilesms.compose",
			@"com.apple.quicklook.quicklookd",
			@"com.apple.ShoeboxUIService",
			@"com.apple.social.remoteui.SocialUIService",
			@"com.apple.WebViewService",
			@"com.apple.gamecenter.GameCenterUIService",
			@"com.apple.appleaccount.AACredentialRecoveryDialog",
			@"com.apple.CompassCalibrationViewService",
			@"com.apple.WebContentFilter.remoteUI.WebContentAnalysisUI",
			@"com.apple.PassbookUIService",
			@"com.apple.uikit.PrintStatus",
			@"com.apple.Copilot",
			@"com.apple.MusicUIService",
			@"com.apple.AccountAuthenticationDialog",
			@"com.apple.MobileReplayer",
			@"com.apple.SiriViewService",
			@"com.apple.TencentWeiboAccountMigrationDialog",
			// iOS 8
			@"com.apple.AskPermissionUI",
			@"com.apple.CoreAuthUI",
			@"com.apple.family",
			@"com.apple.mobileme.fmip1",
			@"com.apple.GameController",
			@"com.apple.HealthPrivacyService",
			@"com.apple.InCallService",
			@"com.apple.mobilesms.notification",
			@"com.apple.PhotosViewService",
			@"com.apple.PreBoard",
			@"com.apple.PrintKit.Print-Center",
			@"com.apple.share",
			@"com.apple.SharedWebCredentialViewService",
			@"com.apple.webapp",
			@"com.apple.webapp1",
			nil];
		hiddenDisplayIdentifiers = result;
	}
	OSSpinLockUnlock(&spinLock);
	return result;
}

- (BOOL)applicationWithDisplayIdentifierIsHidden:(NSString *)displayIdentifier
{
	return [[self _hiddenDisplayIdentifiers] containsObject:displayIdentifier];
}

- (void)postNotificationWithUserInfo:(NSDictionary *)userInfo
{
	[[NSNotificationCenter defaultCenter] postNotificationName:ALIconLoadedNotification object:self userInfo:userInfo];
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	if (iconSize <= 0)
		return NULL;
	NSString *key = [displayIdentifier stringByAppendingFormat:@"#%f", (CGFloat)iconSize];
	OSSpinLockLock(&spinLock);
	CGImageRef result = (CGImageRef)[cachedIcons objectForKey:key];
	if (result) {
		result = CGImageRetain(result);
		OSSpinLockUnlock(&spinLock);
		return result;
	}
	OSSpinLockUnlock(&spinLock);
	if (iconSize == ALApplicationIconSizeSmall) {
		switch (supportedDirectAPI) {
			case LADirectAPINone:
				break;
			case LADirectAPIApplicationIconImageForBundleIdentifier:
				result = [UIImage _applicationIconImageForBundleIdentifier:displayIdentifier format:0 scale:[UIScreen mainScreen].scale].CGImage;
				if (result)
					goto skip;
				break;
			case LADirectAPIApplicationIconImageForBundleIdentifierRoleIdentifier:
				result = [UIImage _applicationIconImageForBundleIdentifier:displayIdentifier roleIdentifier:nil format:0 scale:[UIScreen mainScreen].scale].CGImage;
				if (result)
					goto skip;
				break;
		}
	}
	LMResponseBuffer buffer;
	if (LMConnectionSendTwoWayPropertyList(&connection, ALMessageIdIconForSize, [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedInteger:iconSize], @"iconSize", displayIdentifier, @"displayIdentifier", nil], &buffer))
		return NULL;
	result = [LMResponseConsumeImage(&buffer) CGImage];
	if (!result)
		return NULL;
skip:
	OSSpinLockLock(&spinLock);
	[cachedIcons setObject:(id)result forKey:key];
	OSSpinLockUnlock(&spinLock);
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
	                          [NSNumber numberWithInteger:iconSize], ALIconSizeKey,
	                          displayIdentifier, ALDisplayIdentifierKey,
	                          nil];
	if ([NSThread isMainThread])
		[self postNotificationWithUserInfo:userInfo];
	else
		[self performSelectorOnMainThread:@selector(postNotificationWithUserInfo:) withObject:userInfo waitUntilDone:YES];
	return CGImageRetain(result);
}

- (UIImage *)iconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	CGImageRef image = [self copyIconOfSize:iconSize forDisplayIdentifier:displayIdentifier];
	if (!image)
		return nil;
	UIImage *result;
	if ([UIImage respondsToSelector:@selector(imageWithCGImage:scale:orientation:)]) {
		CGFloat scale = (CGImageGetWidth(image) + CGImageGetHeight(image)) / (CGFloat)(iconSize + iconSize);
		result = [UIImage imageWithCGImage:image scale:scale orientation:0];
	} else {
		result = [UIImage imageWithCGImage:image];
	}
	CGImageRelease(image);
	return result;
}

- (BOOL)hasCachedIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	NSString *key = [displayIdentifier stringByAppendingFormat:@"#%f", (CGFloat)iconSize];
	OSSpinLockLock(&spinLock);
	id result = [cachedIcons objectForKey:key];
	OSSpinLockUnlock(&spinLock);
	return result != nil;
}

@end

@implementation ALApplicationListImpl

static void processMessage(SInt32 messageId, mach_port_t replyPort, CFDataRef data)
{
	switch (messageId) {
		case ALMessageIdGetApplications: {
			NSDictionary *result;
			if (data && CFDataGetLength(data)) {
				NSPredicate *predicate = [NSKeyedUnarchiver unarchiveObjectWithData:(NSData *)data];
				@try {
					result = [predicate isKindOfClass:[NSPredicate class]] ? [sharedApplicationList applicationsFilteredUsingPredicate:predicate] : [sharedApplicationList applications];
				}
				@catch (NSException *exception) {
					NSLog(@"AppList: In call to applicationsFilteredUsingPredicate:%@ trapped %@", predicate, exception);
					break;
				}
			} else {
				result = [sharedApplicationList applications];
			}
			LMSendPropertyListReply(replyPort, result);
			return;
		}
		case ALMessageIdIconForSize: {
			if (!data)
				break;
			NSDictionary *params = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
			if (![params isKindOfClass:[NSDictionary class]])
				break;
			id iconSize = [params objectForKey:@"iconSize"];
			if (![iconSize respondsToSelector:@selector(floatValue)])
				break;
			NSString *displayIdentifier = [params objectForKey:@"displayIdentifier"];
			if (![displayIdentifier isKindOfClass:[NSString class]])
				break;
			CGImageRef result = [sharedApplicationList copyIconOfSize:[iconSize floatValue] forDisplayIdentifier:displayIdentifier];
			if (result) {
				LMSendImageReply(replyPort, [UIImage imageWithCGImage:result]);
				CGImageRelease(result);
				return;
			}
			break;
		}
		case ALMessageIdValueForKeyPath:
		case ALMessageIdValueForKey: {
			if (!data)
				break;
			NSDictionary *params = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
			if (![params isKindOfClass:[NSDictionary class]])
				break;
			NSString *key = [params objectForKey:@"key"];
			Class stringClass = [NSString class];
			if (![key isKindOfClass:stringClass])
				break;
			NSString *displayIdentifier = [params objectForKey:@"displayIdentifier"];
			if (![displayIdentifier isKindOfClass:stringClass])
				break;
			id result;
			@try {
				result = messageId == ALMessageIdValueForKeyPath ? [sharedApplicationList valueForKeyPath:key forDisplayIdentifier:displayIdentifier] : [sharedApplicationList valueForKey:key forDisplayIdentifier:displayIdentifier];
			}
			@catch (NSException *exception) {
				NSLog(@"AppList: In call to valueForKey%s:%@ forDisplayIdentifier:%@ trapped %@", messageId == ALMessageIdValueForKeyPath ? "Path" : "", key, displayIdentifier, exception);
				break;
			}
			LMSendPropertyListReply(replyPort, result);
			return;
		}
		case ALMessageIdGetApplicationCount: {
			LMSendIntegerReply(replyPort, [sharedApplicationList applicationCount]);
			return;
		}
	}
	LMSendReply(replyPort, NULL, 0);
}

static void machPortCallback(CFMachPortRef port, void *bytes, CFIndex size, void *info)
{
	LMMessage *request = bytes;
	if (size < sizeof(LMMessage)) {
		LMSendReply(request->head.msgh_remote_port, NULL, 0);
		LMResponseBufferFree(bytes);
		return;
	}
	// Send Response
	const void *data = LMMessageGetData(request);
	size_t length = LMMessageGetDataLength(request);
	mach_port_t replyPort = request->head.msgh_remote_port;
	CFDataRef cfdata = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, data ?: &data, length, kCFAllocatorNull);
	processMessage(request->head.msgh_id, replyPort, cfdata);
	if (cfdata)
		CFRelease(cfdata);
	LMResponseBufferFree(bytes);
}

- (id)init
{
	if ((self = [super init])) {
		kern_return_t err = LMStartService(connection.serverName, CFRunLoopGetCurrent(), machPortCallback);
		if (err) {
			NSLog(@"AppList: Unable to register mach server with error %x", err);
		}
	}
	return self;
}

static SBApplicationController *appController(void);
static SBApplication *applicationWithDisplayIdentifier(NSString *displayIdentifier);

- (NSDictionary *)applications
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	for (SBApplication *app in [appController() allApplications])
		[result setObject:[[app displayName] description] forKey:[[app displayIdentifier] description]];
	return result;
}

- (NSInteger)applicationCount
{
	return [[appController() allApplications] count];
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	NSArray *apps = [appController() allApplications];
	if (predicate)
		apps = [apps filteredArrayUsingPredicate:predicate];
	for (SBApplication *app in apps)
		[result setObject:[[app displayName] description] forKey:[[app displayIdentifier] description]];
	return result;
}

- (id)valueForKeyPath:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	return [applicationWithDisplayIdentifier(displayIdentifier) valueForKeyPath:keyPath];
}

- (id)valueForKey:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	return [applicationWithDisplayIdentifier(displayIdentifier) valueForKey:keyPath];
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	SBIcon *icon;
	SBIconModel *iconModel = [CHClass(SBIconViewMap) instancesRespondToSelector:@selector(iconModel)] ? [[CHClass(SBIconViewMap) homescreenMap] iconModel] : CHSharedInstance(SBIconModel);
	if ([iconModel respondsToSelector:@selector(applicationIconForDisplayIdentifier:)])
		icon = [iconModel applicationIconForDisplayIdentifier:displayIdentifier];
	else if ([iconModel respondsToSelector:@selector(applicationIconForBundleIdentifier:)])
		icon = [iconModel applicationIconForBundleIdentifier:displayIdentifier];
	else if ([iconModel respondsToSelector:@selector(iconForDisplayIdentifier:)])
		icon = [iconModel iconForDisplayIdentifier:displayIdentifier];
	else
		return NULL;
	BOOL getIconImage = [icon respondsToSelector:@selector(getIconImage:)];
	SBApplication *app = applicationWithDisplayIdentifier(displayIdentifier);
	UIImage *image;
	if (iconSize <= ALApplicationIconSizeSmall) {
		image = getIconImage ? [icon getIconImage:0] : [icon smallIcon];
		if (image)
			goto finish;
		if ([app respondsToSelector:@selector(pathForSmallIcon)]) {
			image = [UIImage imageWithContentsOfFile:[app pathForSmallIcon]];
			if (image)
				goto finish;
		}
	}
	image = getIconImage ? [icon getIconImage:(kCFCoreFoundationVersionNumber >= 675.0) ? 2 : 1] : [icon icon];
	if (image)
		goto finish;
	if ([app respondsToSelector:@selector(pathForIcon)])
		image = [UIImage imageWithContentsOfFile:[app pathForIcon]];
	if (!image)
		return NULL;
finish:
	return CGImageRetain([image CGImage]);
}

@end

static inline void CloneMethod(Class victim, SEL sourceMethodName, SEL destMethodName)
{
	if (victim) {
		unsigned int count = 0;
		Method *methods = class_copyMethodList(victim, &count);
		Method sourceMethod = NULL;
		Method destMethod = NULL;
		if (methods) {
			for (unsigned int i = 0; i < count; i++) {
				SEL methodName = method_getName(methods[i]);
				if (methodName == sourceMethodName)
					sourceMethod = methods[i];
				else if (methodName == destMethodName)
					destMethod = methods[i];
			}
			if (sourceMethod && !destMethod) {
				class_addMethod(victim, destMethodName, method_getImplementation(sourceMethod), method_getTypeEncoding(sourceMethod));
			}
			free(methods);
		}
	}
}

static SEL applicationWithDisplayIdentifierSEL;

static SBApplicationController *appController(void)
{
	static SBApplicationController *cached;
	SBApplicationController *result = cached;
	if (!result) {
		// Load the proper selector to fetch an app by its bundle identifier
		if ([result respondsToSelector:@selector(applicationWithDisplayIdentifier:)]) {
			applicationWithDisplayIdentifierSEL = @selector(applicationWithDisplayIdentifier:);
		} else {
			applicationWithDisplayIdentifierSEL = @selector(applicationWithBundleIdentifier:);
		}
		result = cached = CHSharedInstance(SBApplicationController);
	}
	return result;
}

static SBApplication *applicationWithDisplayIdentifier(NSString *displayIdentifier)
{
	return ((SBApplication *(*)(SBApplicationController *, SEL, NSString *))objc_msgSend)(appController(), applicationWithDisplayIdentifierSEL, displayIdentifier);
}

CHConstructor
{
	CHAutoreleasePoolForScope();
	if (CHLoadLateClass(SBIconModel)) {
		CHLoadLateClass(SBIconViewMap);
		CHLoadLateClass(SBApplicationController);
		// Add a displayIdentifier property if one doesn't exist to maintain compatibility with plists that use predicates on displayIdentifier
		CloneMethod(objc_getClass("SBApplication"), @selector(bundleIdentifier), @selector(displayIdentifier));
		sharedApplicationList = [[ALApplicationListImpl alloc] init];
	}
}
