#import <Preferences/Preferences.h>
#import <spawn.h>
#import <rootless.h>
#import "TintColors.h"

extern char **environ;

@interface screenmirroringListController : PSListController
- (void)openWindowsDownload;
- (void)promptRespring;
@end

@implementation screenmirroringListController

- (id)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"screenmirroring" target:self];
	}
	return _specifiers;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[self initTopMenu];
}

- (void)initTopMenu {
	__weak typeof(self) weakSelf = self;

	UIButton *topMenuButton = [UIButton buttonWithType:UIButtonTypeCustom];
	topMenuButton.frame = CGRectMake(0, 0, 26, 26);
	[topMenuButton setImage:[[UIImage systemImageNamed:@"gearshape.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
	topMenuButton.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
	topMenuButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
	topMenuButton.tintColor = kTintColor;

	UIAction *respringAction = [UIAction actionWithTitle:@"Respring"
													image:[UIImage systemImageNamed:@"arrow.counterclockwise.circle.fill"]
											   identifier:nil
												  handler:^(__unused UIAction *action) {
													  [weakSelf promptRespring];
												  }];

	topMenuButton.menu = [UIMenu menuWithTitle:@"" children:@[respringAction]];
	topMenuButton.showsMenuAsPrimaryAction = YES;

	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:topMenuButton];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	self.navigationController.navigationBar.tintColor = kTintColor;
	self.navigationController.navigationController.navigationBar.tintColor = kTintColor;
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	self.navigationController.navigationBar.tintColor = UIColor.systemBlueColor;
	self.navigationController.navigationController.navigationBar.tintColor = UIColor.systemBlueColor;
}

- (void)performRespring {
	pid_t pid = 0;
	const char *args[] = { "killall", "SpringBoard", NULL };
	int spawnResult = posix_spawn(&pid, ROOT_PATH("/usr/bin/killall"), NULL, NULL, (char *const *)args, environ);
	if (spawnResult == 0) {
		return;
	}

	const char *fallbackArgs[] = {
		"sh",
		"-c",
		"killall -9 SpringBoard || sbreload || killall backboardd",
		NULL
	};
	posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)fallbackArgs, environ);
}

- (void)promptRespring {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring Device"
																   message:@"Apply VNC server changes now?"
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Respring"
											  style:UIAlertActionStyleDestructive
											handler:^(__unused UIAlertAction *action) {
												[self performRespring];
											}]];

	UIViewController *presentingController = self.navigationController ?: self;
	[presentingController presentViewController:alert animated:YES completion:nil];
}

- (PSTableCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	PSTableCell *cell = (PSTableCell *)[super tableView:tableView cellForRowAtIndexPath:indexPath];
	if (indexPath.section == 0 && indexPath.row == 0) {
		cell.backgroundColor = UIColor.clearColor;
		cell.contentView.backgroundColor = UIColor.clearColor;
	}
	return cell;
}

- (void)setTitle:(NSString *)title {}

- (void)openWindowsDownload {
	NSURL *url = [NSURL URLWithString:@"https://github.com/strayfade/tweaks/releases/latest"];
	if (!url) {
		return;
	}
	[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
