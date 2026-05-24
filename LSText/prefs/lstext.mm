#import <Preferences/Preferences.h>
#import <spawn.h>

extern char **environ;

@interface lstextListController : PSListController
@end

@implementation lstextListController

- (id)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"lstext" target:self];
	}
	return _specifiers;
}

- (void)performRespring {
	pid_t pid = 0;
	const char *sbreloadArgs[] = {"sbreload", NULL};
	int result = posix_spawn(&pid, "/usr/bin/sbreload", NULL, NULL, (char *const *)sbreloadArgs, environ);
	if (result == 0) {
		return;
	}

	const char *killallArgs[] = {"killall", "-9", "SpringBoard", NULL};
	posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)killallArgs, environ);
}

- (void)promptRespring {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring Device"
																   message:@"Apply LSText changes now?"
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Respring"
										  style:UIAlertActionStyleDestructive
										handler:^(__unused UIAlertAction *action) {
											[self performRespring];
										}]];
	UIViewController *presenter = self.navigationController ?: self;
	[presenter presentViewController:alert animated:YES completion:nil];
}

@end
