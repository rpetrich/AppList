#import "ALApplicationTableDataSource.h"

#import "ALApplicationList.h"

#import <UIKit/UIKit2.h>
#import <CoreGraphics/CoreGraphics.h>

const NSString *ALSectionDescriptorTitleKey = @"title";
const NSString *ALSectionDescriptorPredicateKey = @"predicate";
const NSString *ALSectionDescriptorCellClassNameKey = @"cell-class-name";
const NSString *ALSectionDescriptorIconSizeKey = @"icon-size";

static NSInteger DictionaryTextComparator(id a, id b, void *context)
{
	return [[(NSDictionary *)context objectForKey:a] localizedCaseInsensitiveCompare:[(NSDictionary *)context objectForKey:b]];
}

@implementation ALApplicationTableDataSource

+ (NSArray *)standardSectionDescriptors
{
	NSNumber *iconSize = [NSNumber numberWithUnsignedInteger:ALApplicationIconSizeSmall];
	return [NSArray arrayWithObjects:
		[NSDictionary dictionaryWithObjectsAndKeys:
			@"System Applications", ALSectionDescriptorTitleKey,
			@"isSystemApplication = TRUE", ALSectionDescriptorPredicateKey,
			@"UITableViewCell", ALSectionDescriptorCellClassNameKey,
			iconSize, ALSectionDescriptorIconSizeKey,
		nil],
		[NSDictionary dictionaryWithObjectsAndKeys:
			@"User Applications", ALSectionDescriptorTitleKey,
			@"isSystemApplication = FALSE", ALSectionDescriptorPredicateKey,
			@"UITableViewCell", ALSectionDescriptorCellClassNameKey,
			iconSize, ALSectionDescriptorIconSizeKey,
		nil],
	nil];
}

+ (id)dataSource
{
	return [[[self alloc] init] autorelease];
}

- (id)init
{
	if ((self = [super init])) {
		appList = [[ALApplicationList sharedApplicationList] retain];
		_displayIdentifiers = [[NSMutableArray alloc] init];
		_displayNames = [[NSMutableArray alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_displayIdentifiers release];
	[_displayNames release];
	[appList release];
	[super dealloc];
}

@synthesize sectionDescriptors = _sectionDescriptors;

- (void)setSectionDescriptors:(NSArray *)sectionDescriptors
{
	[_displayIdentifiers removeAllObjects];
	[_displayNames removeAllObjects];
	for (NSDictionary *descriptor in sectionDescriptors) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSString *predicateText = [descriptor objectForKey:ALSectionDescriptorPredicateKey];
		NSDictionary *applications;
		if (predicateText)
			applications = [appList applicationsFilteredUsingPredicate:[NSPredicate predicateWithFormat:predicateText]];
		else
			applications = [appList applications];
		NSArray *displayIdentifiers = [[applications allKeys] sortedArrayUsingFunction:DictionaryTextComparator context:applications];
		[_displayIdentifiers addObject:displayIdentifiers];
		NSMutableArray *displayNames = [[NSMutableArray alloc] init];
		for (NSString *displayId in displayIdentifiers)
			[displayNames addObject:[applications objectForKey:displayId]];
		[_displayNames addObject:displayNames];
		[displayNames release];
		[pool release];
	}
	[_sectionDescriptors release];
	_sectionDescriptors = [sectionDescriptors copy];
}

- (NSString *)displayIdentifierForIndexPath:(NSIndexPath *)indexPath
{
	return [[_displayIdentifiers objectAtIndex:[indexPath section]] objectAtIndex:[indexPath row]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return [_sectionDescriptors count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	return [[_sectionDescriptors objectAtIndex:section] objectForKey:ALSectionDescriptorTitleKey];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section
{
	return [[_displayIdentifiers objectAtIndex:section] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSUInteger section = [indexPath section];
	NSUInteger row = [indexPath row];
	NSDictionary *sectionDescriptor = [_sectionDescriptors objectAtIndex:section];
	NSString *cellClassName = [sectionDescriptor objectForKey:ALSectionDescriptorCellClassNameKey] ?: @"UITableViewCell";
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellClassName] ?: [[[NSClassFromString(cellClassName) alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellClassName] autorelease];
	cell.textLabel.text = [[_displayNames objectAtIndex:section] objectAtIndex:row];
	CGFloat iconSize = [[sectionDescriptor objectForKey:ALSectionDescriptorIconSizeKey] floatValue];
	if (iconSize <= 0.0f)
		cell.imageView.image = nil;
	else {
		UIImage *image = [appList iconOfSize:iconSize forDisplayIdentifier:[[_displayIdentifiers objectAtIndex:section] objectAtIndex:row]];
		CGSize currentSize = [image size];
		if (currentSize.width != iconSize || currentSize.height != iconSize) {
			CGRect rect;
			rect.origin.x = 0.0f;
			rect.origin.y = 0.0f;
			rect.size.width = iconSize;
			rect.size.height = iconSize;
			UIGraphicsBeginImageContext(rect.size);
			[image drawInRect:rect];
			image = UIGraphicsGetImageFromCurrentImageContext();
			UIGraphicsEndImageContext();
		}
		cell.imageView.image = image;
	}
	return cell;
}

@end
