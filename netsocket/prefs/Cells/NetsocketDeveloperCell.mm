#import "NetsocketDeveloperCell.h"
#import <Preferences/PSSpecifier.h>

@interface NetsocketDeveloperView : UIControl
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *handle;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic, copy) NSString *openURL;
@end

@implementation NetsocketDeveloperView {
	UIImageView *_avatarView;
	UILabel *_nameLabel;
	UILabel *_handleLabel;
	BOOL _didSetup;
}

- (void)didMoveToWindow {
	[super didMoveToWindow];
	if (_didSetup) {
		return;
	}
	_didSetup = YES;

	self.translatesAutoresizingMaskIntoConstraints = NO;
	self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
	self.layer.cornerRadius = 14.0;
	self.layer.masksToBounds = YES;

	UIImage *avatar = [UIImage imageNamed:self.imageName inBundle:[NSBundle bundleForClass:self.class] compatibleWithTraitCollection:nil];
	_avatarView = [[UIImageView alloc] initWithImage:avatar];
	_avatarView.translatesAutoresizingMaskIntoConstraints = NO;
	_avatarView.layer.cornerRadius = 10.0;
	_avatarView.layer.masksToBounds = YES;
	[self addSubview:_avatarView];

	_nameLabel = [UILabel new];
	_nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_nameLabel.text = self.displayName;
	_nameLabel.font = [UIFont boldSystemFontOfSize:15.0];
	[self addSubview:_nameLabel];

	_handleLabel = [UILabel new];
	_handleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_handleLabel.text = self.handle;
	_handleLabel.textColor = UIColor.secondaryLabelColor;
	_handleLabel.font = [UIFont systemFontOfSize:12.0];
	[self addSubview:_handleLabel];

	[NSLayoutConstraint activateConstraints:@[
		[_avatarView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:0.0],
		[_avatarView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
		[_avatarView.widthAnchor constraintEqualToConstant:42.0],
		[_avatarView.heightAnchor constraintEqualToConstant:42.0],

		[_nameLabel.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:12.0],
		[_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],
		[_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:14.0],

		[_handleLabel.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:12.0],
		[_handleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],
		[_handleLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2.0],
	]];

	[self addTarget:self action:@selector(openDeveloperURL) forControlEvents:UIControlEventTouchUpInside];
}

- (void)openDeveloperURL {
	if (self.openURL.length == 0) {
		return;
	}
	NSURL *url = [NSURL URLWithString:self.openURL];
	if (!url) {
		return;
	}
	[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end

@implementation NetsocketDeveloperCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
	self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
	if (!self) {
		return nil;
	}

	self.selectionStyle = UITableViewCellSelectionStyleNone;
	self.backgroundColor = UIColor.clearColor;
	self.contentView.backgroundColor = UIColor.clearColor;

	NetsocketDeveloperView *developerView = [NetsocketDeveloperView new];
	developerView.displayName = [specifier propertyForKey:@"developerName"] ?: @"Developer";
	developerView.handle = [specifier propertyForKey:@"developerHandle"] ?: @"";
	developerView.imageName = [specifier propertyForKey:@"developerImage"] ?: @"developer.png";
	developerView.openURL = [specifier propertyForKey:@"developerURL"] ?: @"";
	[self.contentView addSubview:developerView];

	[NSLayoutConstraint activateConstraints:@[
		[developerView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12.0],
		[developerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12.0],
		[developerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4.0],
		[developerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4.0]
	]];

	return self;
}

@end
