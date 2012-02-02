#import "ALApplicationList.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <SpringBoard/SpringBoard.h>
#import <CaptainHook/CaptainHook.h>
#import <AppSupport/AppSupport.h>

NSString *const ALIconLoadedNotification = @"ALIconLoadedNotification";
NSString *const ALDisplayIdentifierKey = @"ALDisplayIdentifier";
NSString *const ALIconSizeKey = @"ALIconSize";


@interface SBIconModel ()
- (SBApplicationIcon *)applicationIconForDisplayIdentifier:(NSString *)displayIdentifier;
@end

@interface UIImage (iOS40)
+ (UIImage *)imageWithCGImage:(CGImageRef)imageRef scale:(CGFloat)scale orientation:(int)orientation;
@end

@interface ALApplicationList ()

@property (nonatomic, readonly) CPDistributedMessagingCenter *messagingCenter;

@end

@interface ALApplicationListImpl : ALApplicationList {
}

@end

static ALApplicationList *sharedApplicationList;

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
		messagingCenter = [[CPDistributedMessagingCenter centerNamed:@"applist.springboardCenter"] retain];
		cachedIcons = [[NSMutableDictionary alloc] init];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
		[pool drain];
	}
	return self;
}

@synthesize messagingCenter;

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[cachedIcons release];
	[messagingCenter release];
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
	return [messagingCenter sendMessageAndReceiveReplyName:@"applications" userInfo:nil];
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate
{
	if (!predicate)
		return [self applications];
	NSData *data = [NSKeyedArchiver archivedDataWithRootObject:predicate];
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:data forKey:@"predicate"];
	return [messagingCenter sendMessageAndReceiveReplyName:@"_remoteApplicationsFilteredForMessage:userInfo:" userInfo:userInfo];
}

- (void)postNotificationWithUserInfo:(NSDictionary *)userInfo
{
	[[NSNotificationCenter defaultCenter] postNotificationName:ALIconLoadedNotification object:self userInfo:userInfo];
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	NSString *key = [displayIdentifier stringByAppendingFormat:@"#%f", iconSize];
	OSSpinLockLock(&spinLock);
	CGImageRef result = (CGImageRef)[cachedIcons objectForKey:key];
	if (result) {
		result = CGImageRetain(result);
		OSSpinLockUnlock(&spinLock);
		return result;
	}
	OSSpinLockUnlock(&spinLock);
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedInteger:iconSize], @"iconSize", displayIdentifier, @"displayIdentifier", nil];
	NSDictionary *serialized = [messagingCenter sendMessageAndReceiveReplyName:@"_remoteGetIconForMessage:userInfo:" userInfo:userInfo];
	NSData *data = [serialized objectForKey:@"result"];
	if (!data)
		return NULL;
	CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)data, NULL);
	result = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
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
	NSString *key = [displayIdentifier stringByAppendingFormat:@"#%f", iconSize];
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

- (id)init
{
	if ((self = [super init])) {
		CPDistributedMessagingCenter *center = [self messagingCenter];
		[center runServerOnCurrentThread];
		[center registerForMessageName:@"applications" target:self selector:@selector(applications)];
		[center registerForMessageName:@"_remoteApplicationsFilteredForMessage:userInfo:" target:self selector:@selector(_remoteApplicationsFilteredForMessage:userInfo:)];
		[center registerForMessageName:@"_remoteGetIconForMessage:userInfo:" target:self selector:@selector(_remoteGetIconForMessage:userInfo:)];
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

- (NSDictionary *)_remoteApplicationsFilteredForMessage:(NSString *)message userInfo:(NSDictionary *)userInfo
{
	NSPredicate *predicate = [NSKeyedUnarchiver unarchiveObjectWithData:[userInfo objectForKey:@"predicate"]];
	return [self applicationsFilteredUsingPredicate:predicate];
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

- (NSDictionary *)_remoteGetIconForMessage:(NSString *)message userInfo:(NSDictionary *)userInfo
{
	CGImageRef image = [self copyIconOfSize:[[userInfo objectForKey:@"iconSize"] unsignedIntegerValue] forDisplayIdentifier:[userInfo objectForKey:@"displayIdentifier"]];
	if (!image)
		return [NSDictionary dictionary];
	NSMutableData *result = [NSMutableData data];
	CGImageDestinationRef dest = CGImageDestinationCreateWithData((CFMutableDataRef)result, CFSTR("public.png"), 1, NULL);
	CGImageDestinationAddImage(dest, image, NULL);
	CGImageRelease(image);
	CGImageDestinationFinalize(dest);
	CFRelease(dest);
	return [NSDictionary dictionaryWithObject:result forKey:@"result"];
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
	image = getIconImage ? [icon getIconImage:1] : [icon icon];
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
	if (CHLoadLateClass(SBIconModel)) {
		CHLoadLateClass(SBApplicationController);
		sharedApplicationList = [[ALApplicationListImpl alloc] init];
	} else {
		sharedApplicationList = [[ALApplicationList alloc] init];
	}
}
