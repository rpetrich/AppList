#import <UIKit/UIKit.h>

@class ALApplicationList;

@interface ALApplicationTableDataSource : NSObject <UITableViewDataSource> {
@private
	ALApplicationList *appList;
	NSArray *_sectionDescriptors;
	NSMutableArray *_displayIdentifiers;
	NSMutableArray *_displayNames;
}

+ (NSArray *)standardSectionDescriptors;

+ (id)dataSource;
- (id)init;

@property (nonatomic, copy) NSArray *sectionDescriptors;

- (NSString *)displayIdentifierForIndexPath:(NSIndexPath *)indexPath;

@end

extern const NSString *ALSectionDescriptorTitleKey;
extern const NSString *ALSectionDescriptorPredicateKey;
extern const NSString *ALSectionDescriptorCellClassNameKey;
extern const NSString *ALSectionDescriptorIconSizeKey;
