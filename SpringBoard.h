#import <Foundation/Foundation.h>

@interface SBIcon : NSObject
- (UIImage *)getIconImage:(NSInteger)format;
- (UIImage *)icon;
- (UIImage *)smallIcon;
@end

@interface SBApplicationIcon : SBIcon
@end


@interface SBIconModel : NSObject
+ (id)sharedInstance;
- (SBIcon *)iconForDisplayIdentifier:(NSString *)displayIdentifier;
- (SBApplicationIcon *)applicationIconForDisplayIdentifier:(NSString *)displayIdentifier;
@end

@interface SBIconModel (iOS8)
- (SBApplicationIcon *)applicationIconForBundleIdentifier:(NSString *)bundleIdentifier;
@end


@interface SBIconViewMap : NSObject {
	SBIconModel *_model;
	// ...
}
+ (SBIconViewMap *)switcherMap;
+ (SBIconViewMap *)homescreenMap;
- (SBIconModel *)iconModel;
@end


@interface SBApplication : NSObject
@property (nonatomic, readonly) NSString *displayIdentifier;
@property (nonatomic, readonly) NSString *displayName;
- (NSString *)pathForIcon;
- (NSString *)pathForSmallIcon;
- (NSArray *)tags;
@end

@interface SBApplicationInfo : NSObject
- (BOOL)hasHiddenTag;
@end

@interface SBApplication (iOS10)
- (SBApplicationInfo *)info;
@end

@interface SBApplicationController : NSObject
- (NSArray *)allApplications;
@end

@interface SBIconController : NSObject
+ (id)sharedInstance;
@end

@interface SBIconController (iOS93)
- (SBIconViewMap *)homescreenIconViewMap;
@end
