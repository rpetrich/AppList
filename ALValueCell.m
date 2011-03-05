#import "ALValueCell.h"

@implementation ALValueCell

@synthesize delegate;

- (void)loadValue:(id)value
{
}

- (void)didSelect
{
}

@end

@implementation ALSwitchCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
		switchView = [[UISwitch alloc] initWithFrame:CGRectZero];
		[switchView addTarget:self action:@selector(valueChanged) forControlEvents:UIControlEventValueChanged];
		[self setAccessoryView:switchView];
	}
	return self;
}

- (void)dealloc
{
	[switchView release];
	[super dealloc];
}

@synthesize switchView = _switchView;

- (void)loadValue:(id)value
{
	switchView.on = [value boolValue];
}

- (void)valueChanged
{
	id value = [NSNumber numberWithBool:switchView.on];
	[[self delegate] valueCell:self didChangeToValue:value];
}

@end

@implementation ALCheckCell

- (void)loadValue:(id)value
{
	[self setAccessoryType:[value boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone];
}

- (void)didSelect
{
	UITableViewCellAccessoryType type = [self accessoryType];
	[self setAccessoryType:(type == UITableViewCellAccessoryNone) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone];
	id value = [NSNumber numberWithBool:type == UITableViewCellAccessoryNone];
	[[self delegate] valueCell:self didChangeToValue:value];
}

@end