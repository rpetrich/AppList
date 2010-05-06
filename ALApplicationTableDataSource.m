#import "ALApplicationTableDataSource.h"

#import "ALApplicationList.h"

#import <UIKit/UIKit2.h>
#import <CoreGraphics/CoreGraphics.h>

static NSInteger DictionaryTextComparator(id a, id b, void *context)
{
	return [[(NSDictionary *)context objectForKey:a] localizedCaseInsensitiveCompare:[(NSDictionary *)context objectForKey:b]];
}

@implementation ALApplicationTableDataSource

+ (id)dataSource
{
	return [[[self alloc] init] autorelease];
}

- (id)init
{
	if ((self = [super init])) {
		appList = [[ALApplicationList sharedApplicationList] retain];
		NSDictionary *systemApps = [appList systemApplications];
		displayIdentifiers[0] = [[[systemApps allKeys] sortedArrayUsingFunction:DictionaryTextComparator context:systemApps] retain];
		NSMutableArray *namesTemp = [[NSMutableArray alloc] init];
		for (NSString *displayId in displayIdentifiers[0])
			[namesTemp addObject:[systemApps objectForKey:displayId]];
		displayNames[0] = [namesTemp copy];
		NSDictionary *userApps = [appList userApplications];
		displayIdentifiers[1] = [[[userApps allKeys] sortedArrayUsingFunction:DictionaryTextComparator context:userApps] retain];
		[namesTemp removeAllObjects];
		for (NSString *displayId in displayIdentifiers[1])
			[namesTemp addObject:[userApps objectForKey:displayId]];
		displayNames[1] = [namesTemp copy];
		[namesTemp release];
		cellClass = [UITableViewCell class];
	}
	return self;
}

- (void)dealloc
{
	[displayIdentifiers[0] release];
	[displayIdentifiers[1] release];
	[displayNames[0] release];
	[displayNames[1] release];
	[appList release];
	[super dealloc];
}

@synthesize iconSize, cellClass;

- (NSString *)displayIdentifierForIndexPath:(NSIndexPath *)indexPath
{
	return [displayIdentifiers[[indexPath section]] objectAtIndex:[indexPath row]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	return (section == 0) ? @"System Applications" : @"User Applications";
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section
{
	return [displayIdentifiers[section] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"applicationCell"] ?: [[[cellClass alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"applicationCell"] autorelease];
	NSUInteger section = [indexPath section];
	NSUInteger row = [indexPath row];
	cell.textLabel.text = [displayNames[section] objectAtIndex:row];
	if (iconSize.width <= 0.0f || iconSize.height <= 0.0f)
		cell.imageView.image = nil;
	else {
		NSUInteger max = (iconSize.width > iconSize.height) ? iconSize.width : iconSize.height;
		UIImage *originalImage = [appList iconOfSize:max forDisplayIdentifier:[displayIdentifiers[section] objectAtIndex:row]];
		cell.imageView.image = [originalImage _imageScaledToSize:iconSize interpolationQuality:kCGInterpolationDefault];
	}
	return cell;
}

@end
