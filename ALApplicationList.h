#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <libkern/OSAtomic.h>

enum {
	ALApplicationIconSizeSmall = 29,
	ALApplicationIconSizeLarge = 59
};
typedef NSUInteger ALApplicationIconSize;

@class CPDistributedMessagingCenter;

@interface ALApplicationList : NSObject {
@private
	CPDistributedMessagingCenter *messagingCenter;
	NSMutableDictionary *cachedIcons;
	OSSpinLock spinLock;
}
+ (ALApplicationList *)sharedApplicationList;

@property (nonatomic, readonly) NSDictionary *applications;
- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate;

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier;
- (UIImage *)iconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier;
- (BOOL)hasCachedIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier;

@end

extern NSString *const ALIconLoadedNotification;
extern NSString *const ALDisplayIdentifierKey;
extern NSString *const ALIconSizeKey;
