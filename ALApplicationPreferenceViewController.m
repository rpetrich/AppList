#import "ALApplicationTableDataSource.h"

#import "ALApplicationList.h"
#import "ALValueCell.h"

#import <Preferences/Preferences.h>

#include <notify.h>

__attribute__((visibility("hidden")))
@interface ALApplicationPreferenceViewController : PSViewController<UITableViewDelegate> {
@private
	ALApplicationTableDataSource *_dataSource;
	UITableView *_tableView;
	NSString *_navigationTitle;
	id settingsDefaultValue;
	NSString *settingsPath;
	NSMutableDictionary *settings;
	NSString *settingsKeyPrefix;
	NSString *settingsChangeNotification;
}

- (id)initForContentSize:(CGSize)size;

@property (nonatomic, retain) NSString *navigationTitle;
@property (nonatomic, readonly) UITableView *tableView;
@property (nonatomic, readonly) ALApplicationTableDataSource *dataSource;

- (void)cellAtIndexPath:(NSIndexPath *)indexPath didChangeToValue:(id)newValue;
- (id)valueForCellAtIndexPath:(NSIndexPath *)indexPath;

@end

__attribute__((visibility("hidden")))
@interface ALPreferencesTableDataSource : ALApplicationTableDataSource<ALValueCellDelegate> {
@private
	ALApplicationPreferenceViewController *_controller;
}

- (id)initWithController:(ALApplicationPreferenceViewController *)controller;

@end

@implementation ALPreferencesTableDataSource

- (id)initWithController:(ALApplicationPreferenceViewController *)controller
{
	if ((self = [super init])) {
		_controller = controller;
	}
	return self;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	id cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
	if ([cell isKindOfClass:[ALValueCell class]]) {
		[cell setDelegate:self];
		[cell loadValue:[_controller valueForCellAtIndexPath:indexPath]];
	}
	return cell;
}

- (void)valueCell:(ALValueCell *)valueCell didChangeToValue:(id)newValue
{
	[_controller cellAtIndexPath:[self.tableView indexPathForCell:valueCell] didChangeToValue:newValue];
}

@end

@interface PSViewController (OS32)
- (void)setSpecifier:(PSSpecifier *)specifier;
@end

@implementation ALApplicationPreferenceViewController

- (id)initForContentSize:(CGSize)size
{
	if ([[PSViewController class] instancesRespondToSelector:@selector(initForContentSize:)])
		self = [super initForContentSize:size];
	else
		self = [super init];
	if (self) {
		CGRect frame;
		frame.origin = CGPointZero;
		frame.size = size;
		_tableView = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
		_dataSource = [[ALPreferencesTableDataSource alloc] initWithController:self];
		[_tableView setDataSource:_dataSource];
		[_tableView setDelegate:self];
		[_tableView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
		_dataSource.tableView = _tableView;
	}
	return self;
}

- (void)dealloc
{
	[_tableView setDelegate:nil];
	[_tableView setDataSource:nil];
	[_tableView release];
	_dataSource.tableView = nil;
	[_dataSource release];
	[settingsDefaultValue release];
	[settingsPath release];
	[settingsKeyPrefix release];
	[settingsChangeNotification release];
	[_navigationTitle release];
	[super dealloc];
}

@synthesize tableView = _tableView, dataSource = _dataSource, navigationTitle = _navigationTitle;

- (void)setNavigationTitle:(NSString *)navigationTitle
{
	[_navigationTitle autorelease];
	_navigationTitle = [navigationTitle retain];
	if ([self respondsToSelector:@selector(navigationItem)])
		[[self navigationItem] setTitle:_navigationTitle];
}

- (void)loadFromSpecifier:(PSSpecifier *)specifier
{
	[self setNavigationTitle:[specifier propertyForKey:@"ALNavigationTitle"] ?: [specifier name]];
	NSArray *descriptors = [specifier propertyForKey:@"ALSectionDescriptors"];
	if (!descriptors) {
		NSNumber *iconSize = [NSNumber numberWithUnsignedInteger:ALApplicationIconSizeSmall];
		descriptors = [NSArray arrayWithObjects:
			[NSDictionary dictionaryWithObjectsAndKeys:
				@"System Applications", ALSectionDescriptorTitleKey,
				@"isSystemApplication = TRUE", ALSectionDescriptorPredicateKey,
				@"ALSwitchCell", ALSectionDescriptorCellClassNameKey,
				iconSize, ALSectionDescriptorIconSizeKey,
			nil],
			[NSDictionary dictionaryWithObjectsAndKeys:
				@"User Applications", ALSectionDescriptorTitleKey,
				@"isSystemApplication = FALSE", ALSectionDescriptorPredicateKey,
				@"ALSwitchCell", ALSectionDescriptorCellClassNameKey,
				iconSize, ALSectionDescriptorIconSizeKey,
			nil],
		nil];
	}
	[_dataSource setSectionDescriptors:descriptors];
	[settingsDefaultValue release];
	settingsDefaultValue = [[specifier propertyForKey:@"ALSettingsDefaultValue"] retain];
	[settingsPath release];
	settingsPath = [[specifier propertyForKey:@"ALSettingsPath"] retain];
	[settingsKeyPrefix release];
	settingsKeyPrefix = [[specifier propertyForKey:@"ALSettingsKeyPrefix"] ?: @"ALValue-" retain];
	settings = [[NSMutableDictionary alloc] initWithContentsOfFile:settingsPath] ?: [[NSMutableDictionary alloc] init];
	[settingsChangeNotification release];
	settingsChangeNotification = [[specifier propertyForKey:@"ALChangeNotification"] retain];
	[_tableView setAllowsSelection:[[specifier propertyForKey:@"ALAllowsSelection"] boolValue]];
	[_tableView reloadData];
}

- (void)setSpecifier:(PSSpecifier *)specifier
{
	[self loadFromSpecifier:specifier];
	[super setSpecifier:specifier];
}

- (void)viewWillBecomeVisible:(void *)source
{
	if (source)
		[self loadFromSpecifier:(PSSpecifier *)source];
	[super viewWillBecomeVisible:source];
}

- (UIView *)view
{
	return _tableView;
}

- (CGSize)contentSize
{
	return [_tableView frame].size;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	id cell = [_tableView cellForRowAtIndexPath:indexPath];
	if ([cell respondsToSelector:@selector(didSelect)])
		[cell didSelect];
	id cellDescriptor = [_dataSource displayIdentifierForIndexPath:indexPath];
	if ([cellDescriptor isKindOfClass:[NSDictionary class]]) {
		SEL action = NSSelectorFromString([[cellDescriptor objectForKey:@"action"] stringByAppendingString:@"FromCellDescriptor:"]);
		if ([self respondsToSelector:action])
			objc_msgSend(self, action, cellDescriptor);
	}
	[_tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)cellAtIndexPath:(NSIndexPath *)indexPath didChangeToValue:(id)newValue
{
	NSString *displayIdentifier = [_dataSource displayIdentifierForIndexPath:indexPath];
	NSString *key = [settingsKeyPrefix stringByAppendingString:displayIdentifier];
	[settings setObject:newValue forKey:key];
	if (settingsPath)
		[settings writeToFile:settingsPath atomically:YES];
	if (settingsChangeNotification)
		notify_post([settingsChangeNotification UTF8String]);
}

- (id)valueForCellAtIndexPath:(NSIndexPath *)indexPath
{
	NSString *displayIdentifier = [_dataSource displayIdentifierForIndexPath:indexPath];
	NSString *key = [settingsKeyPrefix stringByAppendingString:displayIdentifier];
	return [settings objectForKey:key] ?: settingsDefaultValue;
}

- (void)pushController:(id<PSBaseView>)controller
{
	[super pushController:controller];
	[controller setParentController:self];
}

- (void)launchURLFromCellDescriptor:(NSDictionary *)cellDescriptor
{
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:[cellDescriptor objectForKey:@"url"]]];
}

@end
