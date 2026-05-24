#import <Preferences/Preferences.h>
#import <spawn.h>
#import <rootless.h>

extern char **environ;

static NSString *const kSensorUsageLogPrefsTitle = @"SensorUsageLog";
static NSString *const kSensorUsageLogPath = @"/var/mobile/Library/Preferences/com.noah.sensorusagelog.events.jsonl";

@interface sensorusagelogListController : PSListController
@end

@implementation sensorusagelogListController

- (id)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"sensorusagelog" target:self];
	}
	return _specifiers;
}

- (NSString *)resolvedLogPath {
	return ROOT_PATH_NS(kSensorUsageLogPath);
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
																   message:message
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	UIViewController *presenter = self.navigationController ?: self;
	[presenter presentViewController:alert animated:YES completion:nil];
}

- (NSArray<NSDictionary *> *)readEvents {
	NSString *log = [NSString stringWithContentsOfFile:[self resolvedLogPath] encoding:NSUTF8StringEncoding error:nil];
	if (log.length == 0) {
		return @[];
	}

	NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
	[log enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
		NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
		if (!lineData) {
			return;
		}
		NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
		if ([entry isKindOfClass:[NSDictionary class]]) {
			[events addObject:entry];
		}
		if (events.count > 10000) {
			*stop = YES;
		}
	}];
	return events;
}

- (NSString *)rankingTextFromEvents:(NSArray<NSDictionary *> *)events {
	if (events.count == 0) {
		return @"No sensor events logged yet.";
	}

	NSMutableDictionary<NSString *, NSMutableDictionary *> *statsByBundle = [NSMutableDictionary dictionary];
	for (NSDictionary *entry in events) {
		NSString *bundleID = entry[@"bundleID"] ?: @"unknown.bundle";
		NSString *sensor = entry[@"sensor"] ?: @"unknown";
		NSNumber *durationMs = entry[@"durationMs"];

		NSMutableDictionary *appStats = statsByBundle[bundleID];
		if (!appStats) {
			appStats = [@{
				@"events": @0,
				@"durationMs": @0LL,
				@"camera": @0,
				@"microphone": @0,
				@"location": @0,
				@"motion": @0
			} mutableCopy];
			statsByBundle[bundleID] = appStats;
		}

		appStats[@"events"] = @([appStats[@"events"] integerValue] + 1);
		if ([durationMs isKindOfClass:[NSNumber class]]) {
			long long newDuration = [appStats[@"durationMs"] longLongValue] + [durationMs longLongValue];
			appStats[@"durationMs"] = @(newDuration);
		}
		if (appStats[sensor]) {
			appStats[sensor] = @([appStats[sensor] integerValue] + 1);
		}
	}

	NSArray<NSString *> *sortedBundles = [statsByBundle.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
		NSDictionary *a = statsByBundle[lhs];
		NSDictionary *b = statsByBundle[rhs];
		long long scoreA = ([a[@"events"] longLongValue] * 1000LL) + [a[@"durationMs"] longLongValue];
		long long scoreB = ([b[@"events"] longLongValue] * 1000LL) + [b[@"durationMs"] longLongValue];
		if (scoreA > scoreB) return NSOrderedAscending;
		if (scoreA < scoreB) return NSOrderedDescending;
		return [lhs compare:rhs];
	}];

	NSMutableString *report = [NSMutableString string];
	[report appendFormat:@"SensorUsageLog ranking\n\nTotal events: %lu\nUnique apps: %lu\n\nTop apps by activity score:\n\n",
	 (unsigned long)events.count, (unsigned long)sortedBundles.count];

	NSUInteger rank = 1;
	for (NSString *bundleID in sortedBundles) {
		if (rank > 25) {
			break;
		}
		NSDictionary *stats = statsByBundle[bundleID];
		double durationSec = [stats[@"durationMs"] doubleValue] / 1000.0;
		[report appendFormat:
		 @"%lu) %@\n   events=%@  duration=%.2fs\n   camera=%@ mic=%@ location=%@ motion=%@\n\n",
		 (unsigned long)rank,
		 bundleID,
		 stats[@"events"],
		 durationSec,
		 stats[@"camera"],
		 stats[@"microphone"],
		 stats[@"location"],
		 stats[@"motion"]];
		rank++;
	}

	NSDictionary *latest = events.lastObject;
	if (latest) {
		[report appendString:@"Most recent event:\n"];
		[report appendFormat:@"%@\n", latest];
	}
	return report;
}

- (void)pushTextViewerWithTitle:(NSString *)title body:(NSString *)body {
	UIViewController *controller = [[UIViewController alloc] init];
	controller.title = title;
	controller.view.backgroundColor = [UIColor systemBackgroundColor];

	UITextView *textView = [[UITextView alloc] initWithFrame:controller.view.bounds];
	textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	textView.editable = NO;
	textView.selectable = YES;
	textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	textView.text = body.length > 0 ? body : @"No data.";
	[controller.view addSubview:textView];
	[self.navigationController pushViewController:controller animated:YES];
}

- (void)showRankingReport {
	NSArray<NSDictionary *> *events = [self readEvents];
	NSString *report = [self rankingTextFromEvents:events];
	[self pushTextViewerWithTitle:@"App Ranking" body:report];
}

- (void)showRawLog {
	NSString *raw = [NSString stringWithContentsOfFile:[self resolvedLogPath] encoding:NSUTF8StringEncoding error:nil];
	if (raw.length == 0) {
		raw = @"No log data yet.";
	}
	[self pushTextViewerWithTitle:@"Raw Sensor Log" body:raw];
}

- (void)clearLog {
	[[NSFileManager defaultManager] removeItemAtPath:[self resolvedLogPath] error:nil];
	[self showAlertWithTitle:kSensorUsageLogPrefsTitle message:@"Sensor log cleared."];
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
																   message:@"Apply SensorUsageLog changes now?"
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

