#import "LiquidGlassSliderCell.h"
#import <Preferences/PSSpecifier.h>
#import "../TintColors.h"

@implementation LiquidGlassSliderCell {
	UILabel *_titleLabel;
	UILabel *_valueLabel;
	UISlider *_slider;
	NSString *_defaultsKey;
	NSString *_suiteName;
	NSString *_valueFormat;
	float _minValue;
	float _maxValue;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
	self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
	if (!self) {
		return nil;
	}

	self.textLabel.hidden = YES;
	self.detailTextLabel.hidden = YES;

	_suiteName = [specifier propertyForKey:@"defaults"] ?: @"com.strayfade.liquidglass~prefs";
	_defaultsKey = [specifier propertyForKey:@"key"];
	_valueFormat = [specifier propertyForKey:@"valueFormat"];
	_minValue = [[specifier propertyForKey:@"min"] floatValue];
	_maxValue = [[specifier propertyForKey:@"max"] floatValue];
	float defaultValue = [[specifier propertyForKey:@"default"] floatValue];

	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:_suiteName];
	float stored = [defaults objectForKey:_defaultsKey] ? [defaults floatForKey:_defaultsKey] : defaultValue;
	stored = fminf(fmaxf(stored, _minValue), _maxValue);

	_titleLabel = [UILabel new];
	_titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
	_titleLabel.text = [specifier propertyForKey:@"label"] ?: @"";
	[self.contentView addSubview:_titleLabel];

	_valueLabel = [UILabel new];
	_valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightMedium];
	_valueLabel.textColor = UIColor.secondaryLabelColor;
	_valueLabel.textAlignment = NSTextAlignmentRight;
	_valueLabel.text = [self formattedValue:stored];
	[self.contentView addSubview:_valueLabel];

	_slider = [UISlider new];
	_slider.translatesAutoresizingMaskIntoConstraints = NO;
	_slider.minimumValue = _minValue;
	_slider.maximumValue = _maxValue;
	_slider.value = stored;
	_slider.minimumTrackTintColor = kTintColor;
	_slider.maximumTrackTintColor = [UIColor tertiaryLabelColor];
	[_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
	[self.contentView addSubview:_slider];

	[NSLayoutConstraint activateConstraints:@[
		[_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
		[_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10.0],
		[_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor constant:-8.0],

		[_valueLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
		[_valueLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
		[_valueLabel.widthAnchor constraintGreaterThanOrEqualToConstant:52.0],

		[_slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
		[_slider.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
		[_slider.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:8.0],
		[_slider.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12.0]
	]];

	return self;
}

- (NSString *)formattedValue:(float)value {
	if ([_valueFormat isEqualToString:@"percent"]) {
		return [NSString stringWithFormat:@"%.0f%%", value];
	}
	if (fabsf(_maxValue - 100.0f) < 0.01f && _minValue == 0.0f) {
		return [NSString stringWithFormat:@"%.0f", value];
	}
	if (fabsf(roundf(value) - value) < 0.01f) {
		return [NSString stringWithFormat:@"%.0f", value];
	}
	return [NSString stringWithFormat:@"%.1f", value];
}

- (void)sliderChanged:(UISlider *)sender {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:_suiteName];
	[defaults setFloat:sender.value forKey:_defaultsKey];
	[defaults synchronize];
	_valueLabel.text = [self formattedValue:sender.value];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	self.textLabel.hidden = YES;
	self.detailTextLabel.hidden = YES;
}

- (CGFloat)preferredCellHeight {
	return 72.0;
}

@end
