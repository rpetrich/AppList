#import "ALApplicationTableDataSource.h"

#import "ALApplicationList-private.h"

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

const NSString *ALSectionDescriptorTitleKey = @"title";
const NSString *ALSectionDescriptorFooterTitleKey = @"footer-title";
const NSString *ALSectionDescriptorPredicateKey = @"predicate";
const NSString *ALSectionDescriptorCellClassNameKey = @"cell-class-name";
const NSString *ALSectionDescriptorIconSizeKey = @"icon-size";
const NSString *ALSectionDescriptorItemsKey = @"items";
const NSString *ALSectionDescriptorSuppressHiddenAppsKey = @"suppress-hidden-apps";
const NSString *ALSectionDescriptorVisibilityPredicateKey = @"visibility-predicate";

const NSString *ALItemDescriptorTextKey = @"text";
const NSString *ALItemDescriptorDetailTextKey = @"detail-text";
const NSString *ALItemDescriptorImageKey = @"image";

@interface ALApplicationLoadingTableViewCell : UITableViewCell
@end

@implementation ALApplicationLoadingTableViewCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
		self.backgroundColor = [UIColor clearColor];
		UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
		CGSize cellSize = self.bounds.size;
		CGRect frame = spinner.frame;
		frame.origin.x = (cellSize.width - frame.size.width) * 0.5f;
		frame.origin.y = (cellSize.height - frame.size.height) * 0.5f;
		spinner.frame = frame;
		spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
		[spinner startAnimating];
		[self addSubview:spinner];
		[spinner release];
		self.backgroundView = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
	}
	return self;
}

@end

__attribute__((visibility("hidden")))
@interface ALApplicationTableDataSourceSection : NSObject {
@private
	ALApplicationTableDataSource *_dataSource;
	NSDictionary *_descriptor;
	NSArray *_displayNames;
	NSArray *_displayIdentifiers;
	CGFloat iconSize;
	BOOL isStaticSection;
	NSInteger loadingState;
	CFTimeInterval loadStartTime;
	NSCondition *loadCondition;
}

@property (nonatomic, readonly) NSDictionary *descriptor;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *footerTitle;

- (void)loadContent;

@end

@interface ALApplicationTableDataSource ()
- (void)sectionRequestedSectionReload:(ALApplicationTableDataSourceSection *)section animated:(BOOL)animated;
@end

static NSMutableArray *iconsToLoad;
static OSSpinLock spinLock;
static UIImage *defaultImage;

@implementation ALApplicationTableDataSourceSection

+ (void)initialize
{
	if (self == [ALApplicationTableDataSourceSection class]) {
		defaultImage = [[[ALApplicationList sharedApplicationList] iconOfSize:ALApplicationIconSizeSmall forDisplayIdentifier:@"com.apple.WebSheet"] retain];
	}
}

+ (void)loadIconsFromBackground
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	OSSpinLockLock(&spinLock);
	ALApplicationList *appList = [ALApplicationList sharedApplicationList];
	while ([iconsToLoad count]) {
		NSDictionary *userInfo = [[iconsToLoad objectAtIndex:0] retain];
		[iconsToLoad removeObjectAtIndex:0];
		OSSpinLockUnlock(&spinLock);
		CGImageRelease([appList copyIconOfSize:[[userInfo objectForKey:ALIconSizeKey] integerValue] forDisplayIdentifier:[userInfo objectForKey:ALDisplayIdentifierKey]]);
		[userInfo release];
		[pool drain];
		pool = [[NSAutoreleasePool alloc] init];
		OSSpinLockLock(&spinLock);
	}
	[iconsToLoad release];
	iconsToLoad = nil;
	OSSpinLockUnlock(&spinLock);
	[pool drain];
}

- (id)initWithDescriptor:(NSDictionary *)descriptor dataSource:(ALApplicationTableDataSource *)dataSource loadsAsynchronously:(BOOL)loadsAsynchronously
{
	if ((self = [super init])) {
		_dataSource = dataSource;
		_descriptor = [descriptor copy];
		NSArray *items = [_descriptor objectForKey:@"items"];
		if ([items isKindOfClass:[NSArray class]]) {
			_displayNames = [items copy];
			isStaticSection = YES;
		} else {
			if (loadsAsynchronously) {
				loadingState = 1;
				loadStartTime = CACurrentMediaTime();
				[self performSelectorInBackground:@selector(loadContent) withObject:nil];
				loadCondition = [[NSCondition alloc] init];
			} else {
				[self loadContent];
			}
		}
	}
	return self;
}

- (void)dealloc
{
	[loadCondition release];
	[_displayIdentifiers release];
	[_displayNames release];
	[_descriptor release];
	[super dealloc];
}

- (void)potentialLoadFail
{
	if ([ALApplicationList sharedApplicationList].applicationCount == 0) {
		static BOOL hasFailedAlready;
		if (!hasFailedAlready) {
			hasFailedAlready = YES;
			UIAlertView *av = [[UIAlertView alloc] initWithTitle:@"Unable To Load Apps" message:@"AppList was unable to load the list of installed applications.\n\nPotential causes include the device being in safe mode, AppList being disabled or tampered with, RocketBootstrap being disabled or tampered with, and conflicts between packages currently installed on this device." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
			[av show];
			[av release];
		}
	}
}

- (void)loadContent
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSDictionary *descriptor = _descriptor;
	NSString *predicateText = [descriptor objectForKey:ALSectionDescriptorPredicateKey];
	NSPredicate *predicate = predicateText ? [NSPredicate predicateWithFormat:predicateText] : nil;
	BOOL onlyVisible = [[descriptor objectForKey:ALSectionDescriptorSuppressHiddenAppsKey] boolValue];
	NSArray *displayIdentifiers = nil;
	NSDictionary *applications = [[ALApplicationList sharedApplicationList] applicationsFilteredUsingPredicate:predicate onlyVisible:onlyVisible titleSortedIdentifiers:&displayIdentifiers];
	if ([applications count] == 0) {
		[self performSelectorOnMainThread:@selector(potentialLoadFail) withObject:nil waitUntilDone:NO];
	}
	[displayIdentifiers retain];
	NSMutableArray *displayNames = [[NSMutableArray alloc] init];
	for (NSString *displayId in displayIdentifiers)
		[displayNames addObject:[applications objectForKey:displayId]];
	[loadCondition lock];
	_displayIdentifiers = displayIdentifiers;
	_displayNames = displayNames;
	iconSize = [[descriptor objectForKey:ALSectionDescriptorIconSizeKey] floatValue];
	loadingState = 2;
	if (![NSThread isMainThread]) {
		[self performSelectorOnMainThread:@selector(completedLoading) withObject:nil waitUntilDone:NO];
	}
	[loadCondition signal];
	[loadCondition unlock];
	[pool drain];
}

- (void)completedLoading
{
	if (loadingState) {
		loadingState = 0;
		[_dataSource sectionRequestedSectionReload:self animated:CACurrentMediaTime() - loadStartTime > 0.1];
	}
}

- (BOOL)waitForContentUntilDate:(NSDate *)date
{
	if (loadingState) {
		[loadCondition lock];
		BOOL result;
		if (loadingState == 1) {
			if (date)
				result = [loadCondition waitUntilDate:date];
			else {
				[loadCondition wait];
				result = YES;
			}
		} else {
			result = YES;
		}
		[loadCondition unlock];
		if (loadingState == 2) {
			[self completedLoading];
		}
		return result;
	}
	return YES;
}

@synthesize descriptor = _descriptor;

static inline NSString *Localize(NSBundle *bundle, NSString *string)
{
	return bundle ? [bundle localizedStringForKey:string value:string table:nil] : string;
}
#define Localize(string) Localize(_dataSource.localizationBundle, string)

- (NSString *)title
{
	return Localize([_descriptor objectForKey:ALSectionDescriptorTitleKey]);
}

- (NSString *)footerTitle
{
	return Localize([_descriptor objectForKey:ALSectionDescriptorFooterTitleKey]);
}

- (NSString *)displayIdentifierForRow:(NSInteger)row
{
	NSArray *array = _displayIdentifiers;
	return (row < [array count]) ? [array objectAtIndex:row] : nil;
}

- (id)cellDescriptorForRow:(NSInteger)row
{
	NSArray *array = isStaticSection ? _displayNames : _displayIdentifiers;
	return (row < [array count]) ? [array objectAtIndex:row] : nil;
}

- (NSInteger)rowCount
{
	return loadingState ? 1 : [_displayNames count];
}

static inline UITableViewCell *CellWithClassName(NSString *className, UITableView *tableView)
{
	return [tableView dequeueReusableCellWithIdentifier:className] ?: [[[NSClassFromString(className) alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:className] autorelease];
}

#define CellWithClassName(className) \
	CellWithClassName(className, tableView)

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRow:(NSInteger)row
{
	if (isStaticSection) {
		NSDictionary *itemDescriptor = [_displayNames objectAtIndex:row];
		UITableViewCell *cell = CellWithClassName([itemDescriptor objectForKey:ALSectionDescriptorCellClassNameKey] ?: [_descriptor objectForKey:ALSectionDescriptorCellClassNameKey] ?: @"UITableViewCell");
		cell.textLabel.text = Localize([itemDescriptor objectForKey:ALItemDescriptorTextKey]);
		cell.detailTextLabel.text = Localize([itemDescriptor objectForKey:ALItemDescriptorDetailTextKey]);
		NSString *imagePath = [itemDescriptor objectForKey:ALItemDescriptorImageKey];
		UIImage *image = nil;
		if (imagePath) {
			CGFloat scale;
			if ([UIScreen instancesRespondToSelector:@selector(scale)] && ((scale = [[UIScreen mainScreen] scale]) != 1.0f))
				image = [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"%@@%gx.%@", [imagePath stringByDeletingPathExtension], scale, [imagePath pathExtension]]];
			if (!image)
				image = [UIImage imageWithContentsOfFile:imagePath];
		}
		cell.imageView.image = image;
		return cell;
	}
	if (loadingState) {
		return [tableView dequeueReusableCellWithIdentifier:@"ALApplicationLoadingTableViewCell"] ?: [[[ALApplicationLoadingTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ALApplicationLoadingTableViewCell"] autorelease];
	}
	UITableViewCell *cell = CellWithClassName([_descriptor objectForKey:ALSectionDescriptorCellClassNameKey] ?: @"UITableViewCell");
	cell.textLabel.text = [_displayNames objectAtIndex:row];
	if (iconSize > 0) {
		NSString *displayIdentifier = [_displayIdentifiers objectAtIndex:row];
		ALApplicationList *appList = [ALApplicationList sharedApplicationList];
		if ([appList hasCachedIconOfSize:iconSize forDisplayIdentifier:displayIdentifier]) {
			cell.imageView.image = [appList iconOfSize:iconSize forDisplayIdentifier:displayIdentifier];
			cell.indentationWidth = 10.0f;
			cell.indentationLevel = 0;
		} else {
			if (defaultImage.size.width == iconSize) {
				cell.imageView.image = defaultImage;
				cell.indentationWidth = 10.0f;
				cell.indentationLevel = 0;
			} else {
				cell.indentationWidth = iconSize + 7.0f;
				cell.indentationLevel = 1;
				cell.imageView.image = nil;
			}
			cell.imageView.image = defaultImage;
			NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
			                          [NSNumber numberWithInteger:iconSize], ALIconSizeKey,
			                          displayIdentifier, ALDisplayIdentifierKey,
			                          nil];
			OSSpinLockLock(&spinLock);
			if (iconsToLoad)
				[iconsToLoad insertObject:userInfo atIndex:0];
			else {
				iconsToLoad = [[NSMutableArray alloc] initWithObjects:userInfo, nil];
				[ALApplicationTableDataSourceSection performSelectorInBackground:@selector(loadIconsFromBackground) withObject:nil];
			}
			OSSpinLockUnlock(&spinLock);
		}
	} else {
		cell.imageView.image = nil;
	}
	return cell;
}

- (void)updateIndexPath:(NSIndexPath *)indexPath ofTableView:(UITableView *)tableView withLoadedIconOfSize:(CGFloat)newIconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	if ((loadingState == 0) && [displayIdentifier isEqual:[_displayIdentifiers objectAtIndex:indexPath.row]] && newIconSize == iconSize) {
		UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
		UIImageView *imageView = cell.imageView;
		UIImage *image = imageView.image;
		if (!image || (image == defaultImage)) {
			cell.indentationLevel = 0;
			cell.indentationWidth = 10.0f;
			imageView.image = [[ALApplicationList sharedApplicationList] iconOfSize:newIconSize forDisplayIdentifier:displayIdentifier];
			[cell setNeedsLayout];
		}
	}
}

- (void)detach
{
	_dataSource = nil;
}

@end

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
			(id)kCFBooleanTrue, ALSectionDescriptorSuppressHiddenAppsKey,
		nil],
		[NSDictionary dictionaryWithObjectsAndKeys:
			@"User Applications", ALSectionDescriptorTitleKey,
			@"isSystemApplication = FALSE", ALSectionDescriptorPredicateKey,
			@"UITableViewCell", ALSectionDescriptorCellClassNameKey,
			iconSize, ALSectionDescriptorIconSizeKey,
			(id)kCFBooleanTrue, ALSectionDescriptorSuppressHiddenAppsKey,
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
		_loadsAsynchronously = YES;
		_sectionDescriptors = [[NSMutableArray alloc] init];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(iconLoadedFromNotification:) name:ALIconLoadedNotification object:nil];
	}
	return self;
}

- (void)dealloc
{
	for (ALApplicationTableDataSourceSection *section in _sectionDescriptors) {
		[section detach];
	}
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_localizationBundle release];
	[_tableView release];
	[_sectionDescriptors release];
	[super dealloc];
}

@synthesize tableView = _tableView;
@synthesize localizationBundle = _localizationBundle;
@synthesize loadsAsynchronously = _loadsAsynchronously;

- (void)setSectionDescriptors:(NSArray *)sectionDescriptors
{
	for (ALApplicationTableDataSourceSection *section in _sectionDescriptors) {
		[section detach];
	}
	[_sectionDescriptors removeAllObjects];
	for (NSDictionary *descriptor in sectionDescriptors) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		ALApplicationTableDataSourceSection *section = [[ALApplicationTableDataSourceSection alloc] initWithDescriptor:descriptor dataSource:self loadsAsynchronously:_loadsAsynchronously];
		[_sectionDescriptors addObject:section];
		[section release];
		[pool release];
	}
	[_tableView reloadData];
}

- (NSArray *)sectionDescriptors
{
	// Recreate the array
	NSMutableArray *result = [[[NSMutableArray alloc] initWithCapacity:[_sectionDescriptors count]] autorelease];
	for (ALApplicationTableDataSourceSection *section in _sectionDescriptors) {
		[result addObject:section.descriptor];
	}
	return result;
}

- (void)removeSectionDescriptorsAtIndexes:(NSIndexSet *)indexSet
{
	if (indexSet) {
		NSUInteger index = [indexSet firstIndex];
		if (index != NSNotFound) {
			NSUInteger lastIndex = [indexSet lastIndex];
			for (;;) {
				[[_sectionDescriptors objectAtIndex:index] detach];
				if (index == lastIndex) {
					break;
				}
				index = [indexSet indexGreaterThanIndex:index];
			}
		}
	}
	[_sectionDescriptors removeObjectsAtIndexes:indexSet];
	[_tableView deleteSections:indexSet withRowAnimation:UITableViewRowAnimationFade];
}

- (void)removeSectionDescriptorAtIndex:(NSInteger)index
{
	[self removeSectionDescriptorsAtIndexes:[NSIndexSet indexSetWithIndex:index]];
}

- (void)insertSectionDescriptor:(NSDictionary *)sectionDescriptor atIndex:(NSInteger)index
{
	ALApplicationTableDataSourceSection *section = [[ALApplicationTableDataSourceSection alloc] initWithDescriptor:sectionDescriptor dataSource:self loadsAsynchronously:_loadsAsynchronously];
	[_sectionDescriptors insertObject:section atIndex:index];
	[section release];
	[_tableView insertSections:[NSIndexSet indexSetWithIndex:index] withRowAnimation:UITableViewRowAnimationFade];
}

- (void)setLocalizationBundle:(NSBundle *)localizationBundle
{
	if (_localizationBundle != localizationBundle) {
		[_localizationBundle autorelease];
		_localizationBundle = [localizationBundle retain];
		[_tableView reloadData];
	}
}

- (NSString *)displayIdentifierForIndexPath:(NSIndexPath *)indexPath
{
	NSInteger section = indexPath.section;
	if ([_sectionDescriptors count] > section)
		return [[_sectionDescriptors objectAtIndex:section] displayIdentifierForRow:indexPath.row];
	else
		return nil;
}

- (id)cellDescriptorForIndexPath:(NSIndexPath *)indexPath
{
	NSInteger section = indexPath.section;
	if ([_sectionDescriptors count] > section)
		return [[_sectionDescriptors objectAtIndex:section] cellDescriptorForRow:indexPath.row];
	else
		return nil;
}

- (void)iconLoadedFromNotification:(NSNotification *)notification
{
	NSDictionary *userInfo = notification.userInfo;
	NSString *displayIdentifier = [userInfo objectForKey:ALDisplayIdentifierKey];
	CGFloat iconSize = [[userInfo objectForKey:ALIconSizeKey] floatValue];
	for (NSIndexPath *indexPath in _tableView.indexPathsForVisibleRows) {
		NSInteger section = indexPath.section;
		ALApplicationTableDataSourceSection *sectionObject = [_sectionDescriptors objectAtIndex:section];
		[sectionObject updateIndexPath:indexPath ofTableView:_tableView withLoadedIconOfSize:iconSize forDisplayIdentifier:displayIdentifier];
	}
}

- (void)sectionRequestedSectionReload:(ALApplicationTableDataSourceSection *)section animated:(BOOL)animated
{
	if (animated) {
		NSInteger index = [_sectionDescriptors indexOfObjectIdenticalTo:section];
		if (index != NSNotFound) {
			[_tableView reloadSections:[NSIndexSet indexSetWithIndex:index] withRowAnimation:UITableViewRowAnimationFade];
		}
	} else {
		[_tableView reloadData];
	}
}

- (BOOL)waitUntilDate:(NSDate *)date forContentInSectionAtIndex:(NSInteger)sectionIndex
{
	ALApplicationTableDataSourceSection *section = [_sectionDescriptors objectAtIndex:sectionIndex];
	return [section waitForContentUntilDate:date];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	if (!_tableView) {
		_tableView = [tableView retain];
		NSLog(@"ALApplicationTableDataSource warning: Assumed control over %@", tableView);
	}
	return [_sectionDescriptors count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	return [[_sectionDescriptors objectAtIndex:section] title];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	return [[_sectionDescriptors objectAtIndex:section] footerTitle];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section
{
	return [[_sectionDescriptors objectAtIndex:section] rowCount];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	ALApplicationTableDataSourceSection *section = [_sectionDescriptors objectAtIndex:indexPath.section];
	return [section tableView:tableView cellForRow:indexPath.row];
}

@end
