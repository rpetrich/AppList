#import "ALApplicationList.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <SpringBoard/SpringBoard.h>
#import <CaptainHook/CaptainHook.h>
#import <dlfcn.h>

NSString *const ALIconLoadedNotification = @"ALIconLoadedNotification";
NSString *const ALDisplayIdentifierKey = @"ALDisplayIdentifier";
NSString *const ALIconSizeKey = @"ALIconSize";

enum {
	ALMessageIdGetApplications,
	ALMessageIdIconForSize,
	ALMessageIdValueForKey,
	ALMessageIdValueForKeyPath
};

static CFMessagePortRef messagePort;
static inline CFDataRef SendMessage(SInt32 messageId, CFDataRef data)
{
	if (!CFMessagePortIsValid(messagePort))
		messagePort = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("applist.datasource"));
	CFDataRef outData = NULL;
	CFMessagePortSendRequest(messagePort, messageId, data, 45.0, 45.0, CFSTR("applist.waiting-on-datasource"), &outData);
	return outData;
}

@interface SBIconModel ()
- (SBApplicationIcon *)applicationIconForDisplayIdentifier:(NSString *)displayIdentifier;
@end

@interface UIImage (iOS40)
+ (UIImage *)imageWithCGImage:(CGImageRef)imageRef scale:(CGFloat)scale orientation:(int)orientation;
@end

__attribute__((visibility("hidden")))
@interface ALApplicationListImpl : ALApplicationList
@end

static ALApplicationList *sharedApplicationList;

// Can't late-bind and still support iOS3.0 :(
static bool (*_CGImageDestinationFinalize)(CGImageDestinationRef idst);
static CGImageDestinationRef (*_CGImageDestinationCreateWithData)(CFMutableDataRef data, CFStringRef type, size_t count, CFDictionaryRef options);
static void (*_CGImageDestinationAddImage)(CGImageDestinationRef idst, CGImageRef image, CFDictionaryRef properties);
static CGImageSourceRef (*_CGImageSourceCreateWithData)(CFDataRef data, CFDictionaryRef options);
static CGImageRef (*_CGImageSourceCreateImageAtIndex)(CGImageSourceRef isrc, size_t index, CFDictionaryRef options);


@implementation ALApplicationList

+ (ALApplicationList *)sharedApplicationList
{
	return sharedApplicationList;
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
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[cachedIcons release];
	[super dealloc];
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
	CFDataRef data = SendMessage(ALMessageIdGetApplications, (CFDataRef)[NSKeyedArchiver archivedDataWithRootObject:predicate]);
	if (data) {
		NSDictionary *result = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
		CFRelease(data);
		if ([result isKindOfClass:[NSDictionary class]]) {
			return result;
		}
	}
	return nil;
}

- (id)valueForKeyPath:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	NSData *inputData = [NSPropertyListSerialization dataFromPropertyList:[NSDictionary dictionaryWithObjectsAndKeys:keyPath, @"key", displayIdentifier, @"displayIdentifier", nil] format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
	CFDataRef data = SendMessage(ALMessageIdValueForKeyPath, (CFDataRef)inputData);
	if (data) {
		id result = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
		CFRelease(data);
		return result;
	}
	return nil;
}

- (id)valueForKey:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	NSData *inputData = [NSPropertyListSerialization dataFromPropertyList:[NSDictionary dictionaryWithObjectsAndKeys:keyPath, @"key", displayIdentifier, @"displayIdentifier", nil] format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
	CFDataRef data = SendMessage(ALMessageIdValueForKey, (CFDataRef)inputData);
	if (data) {
		id result = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
		CFRelease(data);
		return result;
	}
	return nil;
}

- (void)postNotificationWithUserInfo:(NSDictionary *)userInfo
{
	[[NSNotificationCenter defaultCenter] postNotificationName:ALIconLoadedNotification object:self userInfo:userInfo];
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	NSString *key = [displayIdentifier stringByAppendingFormat:@"#%f", (CGFloat)iconSize];
	OSSpinLockLock(&spinLock);
	CGImageRef result = (CGImageRef)[cachedIcons objectForKey:key];
	if (result) {
		result = CGImageRetain(result);
		OSSpinLockUnlock(&spinLock);
		return result;
	}
	OSSpinLockUnlock(&spinLock);
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedInteger:iconSize], @"iconSize", displayIdentifier, @"displayIdentifier", nil];
	CFDataRef data = SendMessage(ALMessageIdIconForSize, (CFDataRef)[NSPropertyListSerialization dataFromPropertyList:userInfo format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL]);
	if (!data)
		return NULL;
	CGImageSourceRef imageSource = _CGImageSourceCreateWithData(data, NULL);
	result = _CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
	CFRelease(data);
	if (result) {
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
	}
	CFRelease(imageSource);
	return result;
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

CHDeclareClass(SBApplicationController);
CHDeclareClass(SBIconModel);

@interface SBIcon ()

- (UIImage *)getIconImage:(NSInteger)sizeIndex;

@end

@implementation ALApplicationListImpl

static CFDataRef messageServerCallback(CFMessagePortRef local, SInt32 messageId, CFDataRef data, void *info)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSData *resultData = nil;
	switch (messageId) {
		case ALMessageIdGetApplications: {
			NSPredicate *predicate = [NSKeyedUnarchiver unarchiveObjectWithData:(NSData *)data];
			NSDictionary *result = [predicate isKindOfClass:[NSPredicate class]] ? [sharedApplicationList applicationsFilteredUsingPredicate:predicate] : [sharedApplicationList applications];
			resultData = [NSPropertyListSerialization dataFromPropertyList:result format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
			break;
		}
		case ALMessageIdIconForSize: {
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
				resultData = [NSMutableData data];
				CGImageDestinationRef dest = _CGImageDestinationCreateWithData((CFMutableDataRef)resultData, CFSTR("public.png"), 1, NULL);
				_CGImageDestinationAddImage(dest, result, NULL);
				CGImageRelease(result);
				_CGImageDestinationFinalize(dest);
				CFRelease(dest);
			}
			break;
		}
		case ALMessageIdValueForKeyPath:
		case ALMessageIdValueForKey: {
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
			id result = messageId == ALMessageIdValueForKeyPath ? [sharedApplicationList valueForKeyPath:key forDisplayIdentifier:displayIdentifier] : [sharedApplicationList valueForKey:key forDisplayIdentifier:displayIdentifier];
			resultData = [NSPropertyListSerialization dataFromPropertyList:result format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
			break;
		}
	}
	resultData = [resultData retain];
	[pool drain];
	return (CFDataRef)resultData;
}

- (id)init
{
	if ((self = [super init])) {
		messagePort = CFMessagePortCreateLocal(kCFAllocatorDefault, CFSTR("applist.datasource"), messageServerCallback, NULL, NULL);
		CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, messagePort, 0);
		CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
	}
	return self;
}

- (NSDictionary *)applications
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	for (SBApplication *app in [CHSharedInstance(SBApplicationController) allApplications])
		[result setObject:[app displayName] forKey:[app displayIdentifier]];
	return result;
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	NSArray *apps = [CHSharedInstance(SBApplicationController) allApplications];
	if (predicate)
		apps = [apps filteredArrayUsingPredicate:predicate];
	for (SBApplication *app in apps)
		[result setObject:[app displayName] forKey:[app displayIdentifier]];
	return result;
}

- (id)valueForKeyPath:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	SBApplication *app = [CHSharedInstance(SBApplicationController) applicationWithDisplayIdentifier:displayIdentifier];
	return [app valueForKeyPath:keyPath];
}

- (id)valueForKey:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	SBApplication *app = [CHSharedInstance(SBApplicationController) applicationWithDisplayIdentifier:displayIdentifier];
	return [app valueForKey:keyPath];
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	SBIcon *icon;
	SBIconModel *iconModel = CHSharedInstance(SBIconModel);
	if ([iconModel respondsToSelector:@selector(applicationIconForDisplayIdentifier:)])
		icon = [iconModel applicationIconForDisplayIdentifier:displayIdentifier];
	else if ([iconModel respondsToSelector:@selector(iconForDisplayIdentifier:)])
		icon = [iconModel iconForDisplayIdentifier:displayIdentifier];
	else
		return NULL;
	BOOL getIconImage = [icon respondsToSelector:@selector(getIconImage:)];
	SBApplication *app = [CHSharedInstance(SBApplicationController) applicationWithDisplayIdentifier:displayIdentifier];
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


CHConstructor
{
	CHAutoreleasePoolForScope();
	void *handle = dlopen("/System/Library/Frameworks/ImageIO.framework/ImageIO", RTLD_LAZY) ?: dlopen("/System/Library/PrivateFrameworks/ImageIO.framework/ImageIO", RTLD_LAZY);
	if (!handle)
		return;
	if (CHLoadLateClass(SBIconModel)) {
		CHLoadLateClass(SBApplicationController);
		_CGImageDestinationCreateWithData = dlsym(handle, "CGImageDestinationCreateWithData");
		_CGImageDestinationAddImage = dlsym(handle, "CGImageDestinationAddImage");
		_CGImageDestinationFinalize = dlsym(handle, "CGImageDestinationFinalize");
		sharedApplicationList = [[ALApplicationListImpl alloc] init];
	} else {
		_CGImageSourceCreateWithData = dlsym(handle, "CGImageSourceCreateWithData");
		_CGImageSourceCreateImageAtIndex = dlsym(handle, "CGImageSourceCreateImageAtIndex");
		messagePort = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("applist.datasource"));
		sharedApplicationList = [[ALApplicationList alloc] init];
	}
}
