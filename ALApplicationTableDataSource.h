#import <UIKit/UIKit.h>

@class ALApplicationList;

@interface ALApplicationTableDataSource : NSObject <UITableViewDataSource> {
@private
	ALApplicationList *appList;
	NSArray *displayIdentifiers[2];
	NSArray *displayNames[2];
	CGSize iconSize;
	Class cellClass;
}

+ (id)dataSource;

- (id)init;

@property (nonatomic, assign) CGSize iconSize;
@property (nonatomic, assign) Class cellClass;

- (NSString *)displayIdentifierForIndexPath:(NSIndexPath *)indexPath;

@end