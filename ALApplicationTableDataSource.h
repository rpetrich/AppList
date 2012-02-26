#import <UIKit/UIKit.h>
#import <libkern/OSAtomic.h>

@class ALApplicationList;

@interface ALApplicationTableDataSource : NSObject <UITableViewDataSource> {
@private
	ALApplicationList *appList;
	NSArray *_sectionDescriptors;
	NSMutableArray *_displayIdentifiers;
	NSMutableArray *_displayNames;
	NSMutableArray *_iconsToLoad;
	OSSpinLock spinLock;
	UITableView *_tableView;
	UIImage *_defaultImage;
	NSBundle *_localizationBundle;
}

+ (NSArray *)standardSectionDescriptors;

+ (id)dataSource;
- (id)init;

@property (nonatomic, copy) NSArray *sectionDescriptors;
@property (nonatomic, retain) UITableView *tableView;
@property (nonatomic, retain) NSBundle *localizationBundle;

- (NSString *)displayIdentifierForIndexPath:(NSIndexPath *)indexPath;

@end

extern const NSString *ALSectionDescriptorTitleKey;
extern const NSString *ALSectionDescriptorFooterTitleKey;
extern const NSString *ALSectionDescriptorPredicateKey;
extern const NSString *ALSectionDescriptorCellClassNameKey;
extern const NSString *ALSectionDescriptorIconSizeKey;
extern const NSString *ALSectionDescriptorSuppressHiddenAppsKey;

extern const NSString *ALItemDescriptorTextKey;
extern const NSString *ALItemDescriptorDetailTextKey;
extern const NSString *ALItemDescriptorImageKey;
