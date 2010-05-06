#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

enum {
	ALApplicationIconSizeSmall = 29,
	ALApplicationIconSizeLarge = 59
};
typedef NSUInteger ALApplicationIconSize;

@class CPDistributedMessagingCenter;

@interface ALApplicationList : NSObject {
@private
	CPDistributedMessagingCenter *messagingCenter;
}
+ (id)sharedApplicationList;

@property (nonatomic, readonly) NSDictionary *applications;

@property (nonatomic, readonly) NSDictionary *userApplications;
@property (nonatomic, readonly) NSDictionary *systemApplications;

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier;
- (UIImage *)iconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier;

@end

