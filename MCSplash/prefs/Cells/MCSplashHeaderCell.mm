#import "MCSplashHeaderCell.h"
#import <Preferences/PSSpecifier.h>

static NSString *const kMCSplashPrefsSuite = @"com.noah.mcsplash~prefs";

@implementation MCSplashHeaderCell {
	UISwitch *_toggle;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
	self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
	if (!self) {
		return nil;
	}

	self.selectionStyle = UITableViewCellSelectionStyleNone;
	self.backgroundColor = UIColor.clearColor;
	self.contentView.backgroundColor = UIColor.clearColor;

	UILabel *titleLabel = [UILabel new];
	titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	titleLabel.text = @"MCSplash";
	titleLabel.font = [UIFont boldSystemFontOfSize:44.0];
	titleLabel.textAlignment = NSTextAlignmentCenter;
	[self.contentView addSubview:titleLabel];

	UILabel *versionLabel = [UILabel new];
	versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
	versionLabel.text = @"1.0 (Rootless)";
	versionLabel.font = [UIFont boldSystemFontOfSize:20.0];
	versionLabel.textColor = UIColor.secondaryLabelColor;
	versionLabel.textAlignment = NSTextAlignmentCenter;
	[self.contentView addSubview:versionLabel];

	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kMCSplashPrefsSuite];
	BOOL enabled = [defaults objectForKey:@"Enabled"] ? [defaults boolForKey:@"Enabled"] : YES;

	_toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
	_toggle.translatesAutoresizingMaskIntoConstraints = NO;
	_toggle.transform = CGAffineTransformMakeScale(1.25, 1.25);
	_toggle.on = enabled;
	[_toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
	[self.contentView addSubview:_toggle];

	[NSLayoutConstraint activateConstraints:@[
		[titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:6.0],
		[titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6.0],
		[titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:20.0],

		[versionLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12.0],
		[versionLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12.0],
		[versionLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2.0],

		[_toggle.topAnchor constraintEqualToAnchor:versionLabel.bottomAnchor constant:20.0],
		[_toggle.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
		[_toggle.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12.0]
	]];

	return self;
}

- (void)toggleChanged:(UISwitch *)sender {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kMCSplashPrefsSuite];
	[defaults setBool:sender.isOn forKey:@"Enabled"];
	[defaults synchronize];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	for (UIView *view in self.subviews) {
		if (view != self.contentView) {
			[view removeFromSuperview];
		}
	}
}

@end
