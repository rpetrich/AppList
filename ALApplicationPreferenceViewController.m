#import "ALApplicationTableDataSource.h"

#import "ALApplicationList.h"
#import "ALValueCell.h"

#import "prefs.h"

#import <Preferences/Preferences.h>
#import <CaptainHook/CaptainHook.h>
#import <CoreFoundation/CoreFoundation.h>
#include <notify.h>
#include <objc/message.h>

@interface PSSpecifier (iOS5)
@property (retain, nonatomic) NSString *identifier;
@end

@interface PSListController (iOS4)
- (PSViewController *)controllerForSpecifier:(PSSpecifier *)specifier;
@end

@class ALPreferencesTableDataSource;

__attribute__((visibility("hidden")))
@interface ALApplicationPreferenceViewController : PSListController {
@private
	ALPreferencesTableDataSource *_dataSource;
	UITableView *_tableView;
	NSString *_navigationTitle;
    NSArray *descriptors;
	id settingsDefaultValue;
	NSString *settingsPath;
	NSString *preferencesKey;
	NSMutableDictionary *settings;
	NSString *settingsKeyPrefix;
	NSString *settingsChangeNotification;
	BOOL singleEnabledMode;
}

- (id)initForContentSize:(CGSize)size;

@property (nonatomic, retain) NSString *navigationTitle;
//@property (nonatomic, readonly) UITableView *tableView;
@property (nonatomic, readonly) ALApplicationTableDataSource *dataSource;

- (void)cellAtIndexPath:(NSIndexPath *)indexPath didChangeToValue:(id)newValue;
- (id)valueForCellAtIndexPath:(NSIndexPath *)indexPath;
- (id)valueTitleForCellAtIndexPath:(NSIndexPath *)indexPath;

@end

__attribute__((visibility("hidden")))
@interface ALPreferencesTableDataSource : ALApplicationTableDataSource<ALValueCellDelegate, UITableViewDelegate> {
@private
	ALApplicationPreferenceViewController *_controller;
}

- (id)initWithController:(ALApplicationPreferenceViewController *)controller;

@end

@interface PSViewController (OS32)
- (void)setSpecifier:(PSSpecifier *)specifier;
@end

@implementation ALApplicationPreferenceViewController

- (id)initForContentSize:(CGSize)size
{
	if ([PSViewController instancesRespondToSelector:@selector(initForContentSize:)])
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
		[_tableView setDelegate:_dataSource];
		[_tableView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
		_dataSource.tableView = _tableView;
	}
	return self;
}

- (void)dealloc
{
	if (settingsChangeNotification) {
		CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, (CFStringRef)settingsChangeNotification, NULL);
	}
	[_tableView setDelegate:nil];
	[_tableView setDataSource:nil];
	[_tableView release];
	_dataSource.tableView = nil;
	[_dataSource release];
	[settingsDefaultValue release];
	[settingsPath release];
	[preferencesKey release];
	[settingsKeyPrefix release];
	[settingsChangeNotification release];
	[_navigationTitle release];
	[super dealloc];
}

@synthesize /*tableView = _tableView,*/ dataSource = _dataSource, navigationTitle = _navigationTitle;

- (void)setNavigationTitle:(NSString *)navigationTitle
{
	[_navigationTitle autorelease];
	_navigationTitle = [navigationTitle retain];
	if ([self respondsToSelector:@selector(navigationItem)])
		[[self navigationItem] setTitle:_navigationTitle];
}

- (void)_updateSections
{
    NSInteger index = 0;
    for (NSDictionary *descriptor in descriptors) {
        NSString *predicateFormat = [descriptor objectForKey:ALSectionDescriptorVisibilityPredicateKey];
        if (!predicateFormat) {
        	index++;
        	continue;
        }
        NSPredicate *predicate = [NSPredicate predicateWithFormat:predicateFormat];
        BOOL visible = [predicate evaluateWithObject:settings];
        NSArray *existingDescriptors = [_dataSource sectionDescriptors];
        BOOL already = [existingDescriptors count] > index ? [existingDescriptors objectAtIndex:index] == descriptor : NO;
        if (visible) {
            if (!already) {
                [_dataSource insertSectionDescriptor:descriptor atIndex:index];
            }
            index++;
        } else {
            if (already) {
                [_dataSource removeSectionDescriptorAtIndex:index];
            }
        }
    }
}

- (void)settingsChanged
{
	[settings release];
	BOOL skipOnDiskRead = NO;
	if (preferencesKey) {
		CFPreferencesAppSynchronize((CFStringRef)preferencesKey);
		CFArrayRef keys = CFPreferencesCopyKeyList((CFStringRef)preferencesKey, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		if (keys) {
			if (CFArrayGetCount(keys)) {
				CFDictionaryRef dict = CFPreferencesCopyMultiple(keys, (CFStringRef)preferencesKey, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
				if (dict) {
					settings = [(NSDictionary *)dict mutableCopy];
					skipOnDiskRead = YES;
					CFRelease(dict);
				}
			}
			CFRelease(keys);
		}
	}
	if (!skipOnDiskRead) {
		settings = [[NSMutableDictionary alloc] initWithContentsOfFile:settingsPath] ?: [[NSMutableDictionary alloc] init];
	}
	[_tableView reloadData];
}

static void SettingsChangedNotificationFired(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	[(ALApplicationPreferenceViewController *)observer settingsChanged];
}

- (void)loadFromSpecifier:(PSSpecifier *)specifier
{
	[self setNavigationTitle:[specifier propertyForKey:@"ALNavigationTitle"] ?: [specifier name]];
	singleEnabledMode = [[specifier propertyForKey:@"ALSingleEnabledMode"] boolValue];

    [descriptors release];
	descriptors = [specifier propertyForKey:@"ALSectionDescriptors"];
	if (descriptors == nil) {
		NSString *defaultCellClass = singleEnabledMode ? @"ALCheckCell" : @"ALSwitchCell";
		NSNumber *iconSize = [NSNumber numberWithUnsignedInteger:ALApplicationIconSizeSmall];
		descriptors = [NSArray arrayWithObjects:
			[NSDictionary dictionaryWithObjectsAndKeys:
				@"System Applications", ALSectionDescriptorTitleKey,
				@"isSystemApplication = TRUE", ALSectionDescriptorPredicateKey,
				defaultCellClass, ALSectionDescriptorCellClassNameKey,
				iconSize, ALSectionDescriptorIconSizeKey,
				(id)kCFBooleanTrue, ALSectionDescriptorSuppressHiddenAppsKey,
			nil],
			[NSDictionary dictionaryWithObjectsAndKeys:
				@"User Applications", ALSectionDescriptorTitleKey,
				@"isSystemApplication = FALSE", ALSectionDescriptorPredicateKey,
				defaultCellClass, ALSectionDescriptorCellClassNameKey,
				iconSize, ALSectionDescriptorIconSizeKey,
				(id)kCFBooleanTrue, ALSectionDescriptorSuppressHiddenAppsKey,
			nil],
		nil];
	}
	[_dataSource setSectionDescriptors:descriptors];
    [descriptors retain];

	NSString *bundlePath = [specifier propertyForKey:@"ALLocalizationBundle"];
	_dataSource.localizationBundle = bundlePath ? [NSBundle bundleWithPath:bundlePath] : nil;

	[settingsDefaultValue release];
	settingsDefaultValue = [[specifier propertyForKey:@"ALSettingsDefaultValue"] retain];

	[settingsPath release];
	settingsPath = [[specifier propertyForKey:@"ALSettingsPath"] retain];
	[preferencesKey release];
	if ((kCFCoreFoundationVersionNumber >= 1000) && [settingsPath hasPrefix:@"/var/mobile/Library/Preferences/"] && [settingsPath hasSuffix:@".plist"]) {
		preferencesKey = [[[settingsPath lastPathComponent] stringByDeletingPathExtension] retain];
	} else {
		preferencesKey = nil;
	}

	[settingsKeyPrefix release];
	settingsKeyPrefix = [[specifier propertyForKey:singleEnabledMode ? @"ALSettingsKey" : @"ALSettingsKeyPrefix"] ?: @"ALValue-" retain];

	settings = [[NSMutableDictionary alloc] initWithContentsOfFile:settingsPath] ?: [[NSMutableDictionary alloc] init];

	if (settingsChangeNotification) {
		CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, (CFStringRef)settingsChangeNotification, NULL);
		[settingsChangeNotification release];
	}
	settingsChangeNotification = [specifier propertyForKey:@"ALChangeNotification"];
	if (settingsChangeNotification) {
		[settingsChangeNotification retain];
		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, SettingsChangedNotificationFired, (CFStringRef)settingsChangeNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	}

	id temp = [specifier propertyForKey:@"ALAllowsSelection"];
	[_tableView setAllowsSelection:temp ? [temp boolValue] : singleEnabledMode];

    [self _updateSections];
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

- (void)setTitle:(NSString *)title
{
	[super setTitle:[self navigationTitle]];
}

- (UIView *)view
{
	UIView *result = [super view];
	if (!_tableView.superview) {
		_tableView.frame = result.bounds;
		[_tableView setScrollsToTop:YES];
		[result addSubview:_tableView];
		if ([result respondsToSelector:@selector(setScrollsToTop:)]) {
			[(UIScrollView *)result setScrollsToTop:NO];
		}
		if ([result respondsToSelector:@selector(setScrollEnabled:)]) {
			[(UIScrollView *)result setScrollEnabled:NO];
		}
#ifdef __IPHONE_7_0
		UIViewController *vc = (UIViewController *)self;
		if ([self respondsToSelector:@selector(setAutomaticallyAdjustsScrollViewInsets:)]) {
			[vc setAutomaticallyAdjustsScrollViewInsets:NO];
		}
#endif
	}
	return result;
}

#ifdef __IPHONE_7_0
static UIEdgeInsets EdgeInsetsForViewController(UIViewController *vc)
{
	UIEdgeInsets result;
	if ([vc respondsToSelector:@selector(topLayoutGuide)]) {
		result.top = vc.topLayoutGuide.length;
		result.bottom = vc.bottomLayoutGuide.length;
	} else {
		result.top = 0.0f;
		result.bottom = 0.0f;
	}
	result.left = 0.0f;
	result.right = 0.0f;
	return result;
}
- (void)viewDidLayoutSubviews
{
	UIEdgeInsets insets = EdgeInsetsForViewController((UIViewController *)self);
	_tableView.contentInset = insets;
	_tableView.scrollIndicatorInsets = insets;
}
#endif

- (CGSize)contentSize
{
	return [_tableView frame].size;
}

- (void)cellAtIndexPath:(NSIndexPath *)indexPath didChangeToValue:(id)newValue
{
	id cellDescriptor = [_dataSource cellDescriptorForIndexPath:indexPath];
	if ([cellDescriptor isKindOfClass:[NSDictionary class]]) {
		NSString *key = [cellDescriptor objectForKey:@"ALSettingsKey"];
		[settings setObject:newValue forKey:key];
		if (preferencesKey) {
			CFPreferencesSetAppValue((CFStringRef)key, newValue, (CFStringRef)preferencesKey);
		}
	} else if (singleEnabledMode) {
		if ([newValue boolValue]) {
			[settings setObject:cellDescriptor forKey:settingsKeyPrefix];
			if (preferencesKey)
				CFPreferencesSetAppValue((CFStringRef)settingsKeyPrefix, (CFPropertyListRef)cellDescriptor, (CFStringRef)preferencesKey);
			for (NSIndexPath *otherIndexPath in [_tableView indexPathsForVisibleRows]) {
				if (![otherIndexPath isEqual:indexPath]) {
					ALValueCell *otherCell = (ALValueCell *)[_tableView cellForRowAtIndexPath:otherIndexPath];
					if ([otherCell respondsToSelector:@selector(loadValue:withTitle:)]) {
						[otherCell loadValue:(id)kCFBooleanFalse withTitle:[self valueTitleForCellAtIndexPath:otherIndexPath]];
					}
				}
			}
		} else if ([[settings objectForKey:settingsKeyPrefix] isEqual:cellDescriptor]) {
			[settings removeObjectForKey:settingsKeyPrefix];
			if (preferencesKey)
				CFPreferencesSetAppValue((CFStringRef)settingsKeyPrefix, NULL, (CFStringRef)preferencesKey);
		}
	} else {
		NSString *key = [settingsKeyPrefix stringByAppendingString:cellDescriptor ?: @""];
		[settings setObject:newValue forKey:key];
		if (preferencesKey)
			CFPreferencesSetAppValue((CFStringRef)key, newValue, (CFStringRef)preferencesKey);
	}
	if (settingsPath)
		[settings writeToFile:settingsPath atomically:YES];
	if (preferencesKey)
		CFPreferencesAppSynchronize((CFStringRef)preferencesKey);
	if (settingsChangeNotification) {
		CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, (CFStringRef)settingsChangeNotification, NULL);
		notify_post([settingsChangeNotification UTF8String]);
		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, SettingsChangedNotificationFired, (CFStringRef)settingsChangeNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	}
    [self _updateSections];
}

- (id)valueForCellAtIndexPath:(NSIndexPath *)indexPath
{
	id cellDescriptor = [_dataSource cellDescriptorForIndexPath:indexPath];
	if ([cellDescriptor isKindOfClass:[NSDictionary class]]) {
		return [settings objectForKey:[cellDescriptor objectForKey:@"ALSettingsKey"]] ?: [cellDescriptor objectForKey:@"ALSettingsDefaultValue"];
	}
	if (singleEnabledMode) {
		return [[settings objectForKey:settingsKeyPrefix] isEqualToString:cellDescriptor] ? (id)kCFBooleanTrue : (id)kCFBooleanFalse;
	} else {
		NSString *key = [settingsKeyPrefix stringByAppendingString:cellDescriptor ?: @""];
		return [settings objectForKey:key] ?: settingsDefaultValue;
	}
}

- (id)valueTitleForCellAtIndexPath:(NSIndexPath *)indexPath
{
	id cellDescriptor = [_dataSource cellDescriptorForIndexPath:indexPath];
	if ([cellDescriptor isKindOfClass:[NSDictionary class]]) {
		id value = [[settings objectForKey:[cellDescriptor objectForKey:@"ALSettingsKey"]] ?: [cellDescriptor objectForKey:@"ALSettingsDefaultValue"] description];
		NSArray *validValues = [cellDescriptor objectForKey:@"validValues"] ?: [settings objectForKey:@"validValues"];
		NSInteger index = [validValues indexOfObject:value];
		if (index == NSNotFound)
			return nil;
		NSArray *validTitles = [cellDescriptor objectForKey:@"validTitles"] ?: [settings objectForKey:@"validTitles"];
		if (index >= [validTitles count])
			return nil;
		return [validTitles objectAtIndex:index];
	}
	id value;
	if (singleEnabledMode) {
		value = [[settings objectForKey:settingsKeyPrefix] isEqualToString:cellDescriptor] ? @"1" : @"0";
	} else {
		NSString *key = [settingsKeyPrefix stringByAppendingString:cellDescriptor ?: @""];
		value = [[settings objectForKey:key] ?: settingsDefaultValue description];
	}
	NSDictionary *sectionDescriptor = [descriptors objectAtIndex:indexPath.section];
	NSArray *validValues = [sectionDescriptor objectForKey:@"validValues"] ?: [settings objectForKey:@"validValues"];
	NSInteger index = [validValues indexOfObject:value];
	if (index == NSNotFound)
		return nil;
	NSArray *validTitles = [sectionDescriptor objectForKey:@"validTitles"] ?: [settings objectForKey:@"validTitles"];
	if (index >= [validTitles count])
		return nil;
	return [validTitles objectAtIndex:index];
}

- (void)pushController:(id<PSBaseView>)controller
{
	[super pushController:controller];
	[controller setParentController:self];
}

static id RecursivelyApplyMacro(id input, NSString *macro, NSString *value);

static NSDictionary *RecursivelyApplyMacroDictionary(NSDictionary *input, NSString *macro, NSString *value) {
	NSMutableDictionary *result = nil;
	for (id key in input) {
		id object = [input objectForKey:key];
		id newObject = RecursivelyApplyMacro(object, macro, value);
		if (object != newObject) {
			if (!result) {
				result = [[input mutableCopy] autorelease];
			}
			[result setObject:newObject forKey:key];
		}
	}
	return result ?: input;
}

static NSArray *RecursivelyApplyMacroArray(NSArray *input, NSString *macro, NSString *value) {
	NSMutableArray *result = nil;
	NSInteger i = 0;
	for (id object in input) {
		id newObject = RecursivelyApplyMacro(object, macro, value);
		if (object != newObject) {
			if (!result) {
				result = [[input mutableCopy] autorelease];
			}
			[result replaceObjectAtIndex:i withObject:newObject];
		}
		i++;
	}
	return result ?: input;
}

static NSString *RecursivelyApplyMacroString(NSString *input, NSString *macro, NSString *value) {
	id result = [input stringByReplacingOccurrencesOfString:macro withString:value];
	return [result isEqualToString:input] ? input : result;
}

static id RecursivelyApplyMacro(id input, NSString *macro, NSString *value) {
	if ([input isKindOfClass:[NSString class]])
		return RecursivelyApplyMacroString(input, macro, value);
	if ([input isKindOfClass:[NSDictionary class]])
		return RecursivelyApplyMacroDictionary(input, macro, value);
	if ([input isKindOfClass:[NSArray class]])
		return RecursivelyApplyMacroArray(input, macro, value);
	return input;
}

- (id)appliedValueForKey:(NSString *)key inCellDescriptor:(id)cellDescriptor sectionDescriptor:(NSDictionary *)sectionDescriptor
{
	if ([cellDescriptor isKindOfClass:[NSDictionary class]]) {
		return [cellDescriptor objectForKey:key];
	}
	if ([cellDescriptor isKindOfClass:[NSString class]]) {
		NSString *macro = [sectionDescriptor objectForKey:@"display-identifier-macro"];
		id result = RecursivelyApplyMacro([sectionDescriptor objectForKey:key], macro, cellDescriptor);
		NSLog(@" = %@", result);
		return result;
	}
	return nil;
}

- (PSSpecifier *)specifierForIndexPath:(NSIndexPath *)indexPath
{
	NSInteger section = indexPath.section;
	[_dataSource waitUntilDate:nil forContentInSectionAtIndex:section];
	id cellDescriptor = [_dataSource cellDescriptorForIndexPath:indexPath];
	if (!cellDescriptor) {
		NSLog(@"AppList: no cell descriptor for cell!");
		return nil;
	}
	NSDictionary *sectionDescriptor = [_dataSource.sectionDescriptors objectAtIndex:section];
	NSDictionary *entry = [self appliedValueForKey:@"entry" inCellDescriptor:cellDescriptor sectionDescriptor:sectionDescriptor];
	if (!entry) {
		NSLog(@"AppList: entry key missing!");
		return nil;
	}
	NSString *title;
	if ([cellDescriptor isKindOfClass:[NSString class]]) {
		title = [[ALApplicationList sharedApplicationList] valueForKey:@"displayName" forDisplayIdentifier:cellDescriptor];
	} else {
		title = [cellDescriptor objectForKey:@"text"];
	}
	NSArray *specifiers = [self specifiersFromEntry:entry sourcePreferenceLoaderBundlePath:self.specifier.preferenceLoaderBundle.bundlePath title:[title length] ? title : @" "];
	if ([specifiers count] == 0) {
		NSLog(@"AppList: preferenceloader failed to load specifier!");
		return nil;
	}
	PSSpecifier *specifier = [specifiers objectAtIndex:0];
	if ([specifier respondsToSelector:@selector(setIdentifier:)]) {
		[specifier setIdentifier:[NSString stringWithFormat:@"applist:%ld,%ld", (long)section, (long)indexPath.row]];
	}
	return specifier;
}

- (void)showPreferencesFromCellDescriptor:(id)cellDescriptor sectionDescriptor:(NSDictionary *)sectionDescriptor indexPath:(NSIndexPath *)indexPath
{
	PSSpecifier *specifier = [self specifierForIndexPath:indexPath];
	if (specifier) {
		[self pushController:[self controllerForSpecifier:specifier]];
	}
}

- (void)launchURLFromCellDescriptor:(id)cellDescriptor sectionDescriptor:(NSDictionary *)sectionDescriptor
{
	NSString *url = [self appliedValueForKey:@"url" inCellDescriptor:cellDescriptor sectionDescriptor:sectionDescriptor];
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
}

/*- (UIPreferencesTable *)table
{
	return nil;
}*/

- (PSSpecifier *)specifierForID:(NSString *)identifier
{
	if ([identifier hasPrefix:@"applist:"]) {
		NSArray *components = [[identifier substringFromIndex:8] componentsSeparatedByString:@","];
		if ([components count] == 2) {
			NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[[components objectAtIndex:1] integerValue] inSection:[[components objectAtIndex:0] integerValue]];
			PSSpecifier *result = [self specifierForIndexPath:indexPath];
			if (result) {
				return result;
			}
		}
	}
	return [super specifierForID:identifier];
}

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
		[(ALValueCell *)cell setDelegate:self];
		[(ALValueCell *)cell loadValue:[_controller valueForCellAtIndexPath:indexPath] withTitle:[_controller valueTitleForCellAtIndexPath:indexPath]];
	}
	return cell;
}

- (void)valueCell:(ALValueCell *)valueCell didChangeToValue:(id)newValue
{
	[_controller cellAtIndexPath:[self.tableView indexPathForCell:valueCell] didChangeToValue:newValue];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	id cell = [tableView cellForRowAtIndexPath:indexPath];
	if ([cell respondsToSelector:@selector(didSelect)])
		[cell didSelect];
	id cellDescriptor = [self cellDescriptorForIndexPath:indexPath];
	if (cellDescriptor) {
		NSDictionary *sectionDescriptor = [self.sectionDescriptors objectAtIndex:indexPath.section];
		NSString *stringAction = [_controller appliedValueForKey:@"action" inCellDescriptor:cellDescriptor sectionDescriptor:sectionDescriptor];
		SEL action = NSSelectorFromString([stringAction stringByAppendingString:@"FromCellDescriptor:sectionDescriptor:indexPath:"]);
		if ([_controller respondsToSelector:action]) {
			((void (*)(ALApplicationPreferenceViewController *, SEL, id, NSDictionary *, NSIndexPath *))objc_msgSend)(_controller, action, cellDescriptor, sectionDescriptor, indexPath);
		} else {
			action = NSSelectorFromString([stringAction stringByAppendingString:@"FromCellDescriptor:sectionDescriptor:"]);
			if ([_controller respondsToSelector:action]) {
				((void (*)(ALApplicationPreferenceViewController *, SEL, id, NSDictionary *))objc_msgSend)(_controller, action, cellDescriptor, sectionDescriptor);
			} else {
				action = NSSelectorFromString([stringAction stringByAppendingString:@"FromCellDescriptor:"]);
				if ([_controller respondsToSelector:action]) {
					((void (*)(ALApplicationPreferenceViewController *, SEL, id))objc_msgSend)(_controller, action, cellDescriptor);
				}
			}
		}
	}
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
