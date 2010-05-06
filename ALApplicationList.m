#import "ALApplicationList.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <SpringBoard/SpringBoard.h>
#import <CaptainHook/CaptainHook.h>
#import <AppSupport/AppSupport.h>

@interface ALApplicationList ()

@property (nonatomic, readonly) CPDistributedMessagingCenter *messagingCenter;

@end

@interface ALApplicationListImpl : ALApplicationList {
}

@end

static ALApplicationList *sharedApplicationList;

@implementation ALApplicationList

+ (id)sharedApplicationList
{
	return sharedApplicationList;
}

- (id)init
{
	if ((self = [super init])) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		messagingCenter = [[CPDistributedMessagingCenter centerNamed:@"applist.springboardCenter"] retain];
		[pool drain];
	}
	return self;
}

@synthesize messagingCenter;

- (void)dealloc
{
	[messagingCenter release];
	[super dealloc];
}

- (NSDictionary *)applications
{
	return [messagingCenter sendMessageAndReceiveReplyName:@"applications" userInfo:nil];
}

- (NSDictionary *)userApplications
{
	return [messagingCenter sendMessageAndReceiveReplyName:@"userApplications" userInfo:nil];
}

- (NSDictionary *)systemApplications
{
	return [messagingCenter sendMessageAndReceiveReplyName:@"systemApplications" userInfo:nil];
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedInteger:iconSize], @"iconSize", displayIdentifier, @"displayIdentifier", nil];
	NSDictionary *serialized = [messagingCenter sendMessageAndReceiveReplyName:@"_remoteGetIconForMessage:userInfo:" userInfo:userInfo];
	NSData *data = [serialized objectForKey:@"result"];
	if (!data)
		return NULL;
	CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)data, NULL);
	CGImageRef result = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
	CFRelease(imageSource);
	return result;
}

- (UIImage *)iconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	CGImageRef image = [self copyIconOfSize:iconSize forDisplayIdentifier:displayIdentifier];
	if (!image)
		return nil;
	UIImage *result = [UIImage imageWithCGImage:image];
	CGImageRelease(image);
	return result;
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
		[center registerForMessageName:@"userApplications" target:self selector:@selector(userApplications)];
		[center registerForMessageName:@"systemApplications" target:self selector:@selector(systemApplications)];
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

- (NSDictionary *)userApplications
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	for (SBApplication *app in [CHSharedInstance(SBApplicationController) allApplications])
		if (![app isSystemApplication])
			[result setObject:[app displayName] forKey:[app displayIdentifier]];
	return result;
}

- (NSDictionary *)systemApplications
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	for (SBApplication *app in [CHSharedInstance(SBApplicationController) allApplications])
		if ([app isSystemApplication])
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
	SBIcon *icon = [CHSharedInstance(SBIconModel) iconForDisplayIdentifier:displayIdentifier];
	BOOL getIconImage = [icon respondsToSelector:@selector(getIconImage:)];
	SBApplication *app = [CHSharedInstance(SBApplicationController) applicationWithDisplayIdentifier:displayIdentifier];
	UIImage *image;
	if (iconSize <= ALApplicationIconSizeSmall) {
		image = getIconImage ? [icon getIconImage:0] : [icon smallIcon];
		if (image)
			goto finish;
		image = [UIImage imageWithContentsOfFile:[app pathForSmallIcon]];
		if (image)
			goto finish;
	}
	image = getIconImage ? [icon getIconImage:1] : [icon icon];
	if (image)
		goto finish;
	image = [UIImage imageWithContentsOfFile:[app pathForIcon]];
finish:
	return CGImageRetain([image CGImage]);
}

@end


CHConstructor {
	CHAutoreleasePoolForScope();
	CHLoadLateClass(SBIconModel);
	CHLoadLateClass(SBApplicationController);
	if (CHClass(SBApplicationController))
		sharedApplicationList = [[ALApplicationListImpl alloc] init];
	else
		sharedApplicationList = [[ALApplicationList alloc] init];
}
