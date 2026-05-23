#import <Preferences/Preferences.h>
#import <spawn.h>

extern char **environ;

static NSString *const kNetsocketPrefsLogPath = @"/var/mobile/Library/Preferences/com.strayfade.netsocket.log";
static NSString *const kNetsocketPrefsTitle = @"netsocket";

@interface netsocketListController: PSListController {
}
- (void)showDebugLog;
- (void)clearDebugLog;
- (void)promptRespring;
@end

@implementation netsocketListController
- (id)specifiers {
	if(_specifiers == nil) {
		_specifiers = [self loadSpecifiersFromPlistName:@"netsocket" target:self];
	}
	return _specifiers;
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
																   message:message
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

	UIViewController *presentingController = self.navigationController ?: self;
	[presentingController presentViewController:alert animated:YES completion:nil];
}

- (void)showDebugLog {
	NSString *log = [NSString stringWithContentsOfFile:kNetsocketPrefsLogPath encoding:NSUTF8StringEncoding error:nil];
	if (!log || log.length == 0) {
		log = @"No debug logs yet.";
	}

	UIViewController *logController = [[UIViewController alloc] init];
	logController.title = @"Debug Log";
	logController.view.backgroundColor = [UIColor systemBackgroundColor];

	UITextView *textView = [[UITextView alloc] initWithFrame:logController.view.bounds];
	textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	textView.editable = NO;
	textView.selectable = YES;
	textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	textView.text = log;

	[logController.view addSubview:textView];
	[self.navigationController pushViewController:logController animated:YES];
}

- (void)clearDebugLog {
	[[NSFileManager defaultManager] removeItemAtPath:kNetsocketPrefsLogPath error:nil];

	[self showAlertWithTitle:kNetsocketPrefsTitle message:@"Debug log cleared."];
}

- (void)performRespring {
	pid_t pid = 0;
	const char *sbreloadArgs[] = {"sbreload", NULL};
	int spawnResult = posix_spawn(&pid, "/usr/bin/sbreload", NULL, NULL, (char *const *)sbreloadArgs, environ);
	if (spawnResult == 0) {
		[self showAlertWithTitle:kNetsocketPrefsTitle message:@"Respring requested."];
		return;
	}

	const char *killallArgs[] = {"killall", "-9", "SpringBoard", NULL};
	spawnResult = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)killallArgs, environ);
	if (spawnResult == 0) {
		[self showAlertWithTitle:kNetsocketPrefsTitle message:@"Respring requested."];
		return;
	}

	[self showAlertWithTitle:kNetsocketPrefsTitle message:@"Unable to trigger respring on this device."];
}

- (void)promptRespring {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring Device"
																   message:@"Apply changes now by restarting SpringBoard?"
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
@end

// vim:ft=objc