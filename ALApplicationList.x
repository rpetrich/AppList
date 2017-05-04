#import "ALApplicationList-private.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <CaptainHook/CaptainHook.h>
#import <dlfcn.h>

#define ROCKETBOOTSTRAP_LOAD_DYNAMIC
#import "LightMessaging/LightMessaging.h"
#import "unfair_lock.h"

#import "SpringBoard.h"

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
	ALMessageIdGetApplicationCount,
	ALMessageIdGetVisibleApplications
};

static LMConnection connection = {
	MACH_PORT_NULL,
	"applist.datasource"
};
static NSMutableDictionary *cachedIcons;
static unfair_lock spinLock;

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
	if (self == [ALApplicationList class] && !%c(SBIconModel)) {
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

#if 0
- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[cachedIcons release];
	[super dealloc];
}
#endif

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
	unfair_lock_lock(&spinLock);
	NSDictionary *oldCachedIcons = cachedIcons;
	cachedIcons = nil;
	unfair_lock_unlock(&spinLock);
	[oldCachedIcons release];
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
	LMResponseBuffer buffer;
	if (LMConnectionSendTwoWayData(&connection, onlyVisible ? ALMessageIdGetVisibleApplications : ALMessageIdGetApplications, (CFDataRef)[NSKeyedArchiver archivedDataWithRootObject:predicate], &buffer))
		return nil;
	NSDictionary *result = LMResponseConsumePropertyList(&buffer);
	if (![result isKindOfClass:[NSDictionary class]])
		return nil;
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
	unfair_lock_lock(&spinLock);
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
	unfair_lock_unlock(&spinLock);
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
	unfair_lock_lock(&spinLock);
	CGImageRef result = (CGImageRef)[cachedIcons objectForKey:key];
	if (result) {
		result = CGImageRetain(result);
		unfair_lock_unlock(&spinLock);
		return result;
	}
	unfair_lock_unlock(&spinLock);
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
	unfair_lock_lock(&spinLock);
	if (!cachedIcons) {
		cachedIcons = [[NSMutableDictionary alloc] init];
	}
	[cachedIcons setObject:(id)result forKey:key];
	unfair_lock_unlock(&spinLock);
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
	                          [NSNumber numberWithInteger:iconSize], ALIconSizeKey,
	                          displayIdentifier, ALDisplayIdentifierKey,
	                          nil];
	if ([NSThread isMainThread])
		[self performSelector:@selector(postNotificationWithUserInfo:) withObject:userInfo afterDelay:0.0];
	else
		[self performSelectorOnMainThread:@selector(postNotificationWithUserInfo:) withObject:userInfo waitUntilDone:NO];
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
	unfair_lock_lock(&spinLock);
	id result = [cachedIcons objectForKey:key];
	unfair_lock_unlock(&spinLock);
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
		case ALMessageIdGetVisibleApplications: {
			NSDictionary *result;
			if (data && CFDataGetLength(data)) {
				NSPredicate *predicate = [NSKeyedUnarchiver unarchiveObjectWithData:(NSData *)data];
				@try {
					result = [predicate isKindOfClass:[NSPredicate class]] ? [sharedApplicationList applicationsFilteredUsingPredicate:predicate onlyVisible:YES titleSortedIdentifiers:NULL] : [sharedApplicationList applications];
				}
				@catch (NSException *exception) {
					NSLog(@"AppList: In call to applicationsFilteredUsingPredicate:%@ onlyVisible:YES titleSortedIdentifiers:NULL trapped %@", predicate, exception);
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

static inline NSMutableDictionary *dictionaryOfApplicationsList(id<NSFastEnumeration> applications)
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	for (SBApplication *app in applications) {
		NSString *displayName = [[app displayName] description];
		if (displayName) {
			NSString *displayIdentifier = [[app displayIdentifier] description];
			if (displayIdentifier) {
				[result setObject:displayName forKey:displayIdentifier];
			}
		}
	}
	return result;
}

- (NSDictionary *)applications
{
	return dictionaryOfApplicationsList([appController() allApplications]);
}

- (NSInteger)applicationCount
{
	return [[appController() allApplications] count];
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate
{
	NSArray *apps = [appController() allApplications];
	if (predicate)
		apps = [apps filteredArrayUsingPredicate:predicate];
	return dictionaryOfApplicationsList(apps);
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate onlyVisible:(BOOL)onlyVisible titleSortedIdentifiers:(NSArray **)outSortedByTitle
{
	NSArray *apps = [appController() allApplications];
	if (predicate)
		apps = [apps filteredArrayUsingPredicate:predicate];
	NSMutableDictionary *result;
	if (onlyVisible) {
		if (kCFCoreFoundationVersionNumber > 1000) {
			result = dictionaryOfApplicationsList([apps filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"not tags contains 'hidden'"]]);
		} else {
			result = dictionaryOfApplicationsList(apps);
			[result removeObjectsForKeys:[self _hiddenDisplayIdentifiers]];
		}
	} else {
		result = dictionaryOfApplicationsList(apps);
	}
	if (outSortedByTitle) {
		// Generate a sorted list of apps
		*outSortedByTitle = [[result allKeys] sortedArrayUsingFunction:DictionaryTextComparator context:result];
	}
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

static SBIconModel *homescreenIconModel(void)
{
	static SBIconModel *iconModel;
	if (!iconModel) {
		if ([%c(SBIconViewMap) instancesRespondToSelector:@selector(iconModel)]) {
			SBIconViewMap *viewMap;
			if ([%c(SBIconViewMap) respondsToSelector:@selector(homescreenMap)]) {
				viewMap = [%c(SBIconViewMap) homescreenMap];
			} else {
				viewMap = [(SBIconController *)[%c(SBIconController) sharedInstance] homescreenIconViewMap];
			}
			iconModel = [viewMap iconModel];
		} else {
			iconModel = (SBIconModel *)[%c(SBIconModel) sharedInstance];
		}
		iconModel = [iconModel retain];
	}
	return iconModel;
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	if (![NSThread isMainThread]) {
		return [super copyIconOfSize:iconSize forDisplayIdentifier:displayIdentifier];
	}
	SBIcon *icon;
	SBIconModel *iconModel = homescreenIconModel();
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

static inline BOOL CloneMethod(Class victim, SEL sourceMethodName, SEL destMethodName)
{
	BOOL result = NO;
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
				result = YES;
			}
			free(methods);
		}
	}
	return result;
}


static SEL applicationWithDisplayIdentifierSEL;

static SBApplicationController *appController(void)
{
	static SBApplicationController *cached;
	SBApplicationController *result = cached;
	if (!result) {
		result = cached = (SBApplicationController *)[%c(SBApplicationController) sharedInstance];
		// Load the proper selector to fetch an app by its bundle identifier
		if ([result respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
			applicationWithDisplayIdentifierSEL = @selector(applicationWithBundleIdentifier:);
		} else {
			applicationWithDisplayIdentifierSEL = @selector(applicationWithDisplayIdentifier:);
		}
	}
	return result;
}

static SBApplication *applicationWithDisplayIdentifier(NSString *displayIdentifier)
{
	return ((SBApplication *(*)(SBApplicationController *, SEL, NSString *))objc_msgSend)(appController(), applicationWithDisplayIdentifierSEL, displayIdentifier);
}

%group SBApplicationHooks

%hook SBApplication

+ (BOOL)resolveInstanceMethod:(SEL)selector
{
	if (selector == @selector(displayIdentifier)) {
		if (CloneMethod(%c(SBApplication), @selector(bundleIdentifier), @selector(displayIdentifier))) {
			NSLog(@"AppList: Added -[SBApplication displayIdentifier] for compatibility purposes");
			return YES;
		}
	}
	return %orig();
}

%end

%end

// Workaround tweaks that mistakenly call applicationWithDisplayIdentifier:
static BOOL cloned;

%group SBApplicationControllerHooks

%hook SBApplicationController

- (BOOL)respondsToSelector:(SEL)selector
{
	if (selector == @selector(applicationWithDisplayIdentifier:)) {
		BOOL result = %orig();
		return cloned ? NO : result;
	}
	return %orig();
}

+ (BOOL)instancesRespondToSelector:(SEL)selector
{
	if (selector == @selector(applicationWithDisplayIdentifier:)) {
		BOOL result = %orig();
		return cloned ? NO : result;
	}
	return %orig();
}

+ (BOOL)resolveInstanceMethod:(SEL)selector
{
	if (selector == @selector(applicationWithDisplayIdentifier:)) {
		if (CloneMethod(self, @selector(applicationWithBundleIdentifier:), @selector(applicationWithDisplayIdentifier:))) {
			NSLog(@"AppList: Added -[SBApplicationController applicationWithDisplayIdentifier:] for compatibility purposes");
			cloned = YES;
			return YES;
		}
	}
	return %orig();
}

%end

%end

%ctor
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	if (%c(SBIconModel)) {
		// Add a displayIdentifier property if one doesn't exist to maintain compatibility with plists that use predicates on displayIdentifier
		if (kCFCoreFoundationVersionNumber > 1000) {
			%init(SBApplicationHooks);
			// Only add applicationWithDisplayIdentifier: on iOS 8
			if (kCFCoreFoundationVersionNumber < 1240) {
				%init(SBApplicationControllerHooks);
			}
		}
		sharedApplicationList = [[ALApplicationListImpl alloc] init];
	}
	[pool drain];
}
