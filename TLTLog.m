#import <UIKit/UIKit.h>
#import "TLTLog.h"
#include <roothide.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/utsname.h>

BOOL TLTDebugOn = NO;

@interface UIDevice (TLTHomeButton)
+ (BOOL)_hasHomeButton; // UIKit (iOS 16 and later headers): YES with a Home button (Touch ID), NO with a notch / Dynamic Island
@end

static NSString *const TLTRecordSeparator = @"\x1e";

// The first directory the process may really write to wins; the reader looks in all of them.
static NSArray<NSString *> *TLTLogDirectories(void) {
	return @[
		jbroot(@"/var/mobile/Library/Caches/TwoLineTime"),
		jbroot(@"/var/mobile/Library/TwoLineTime/Logs"),
		jbroot(@"/var/tmp/TwoLineTime"),
		@"/var/mobile/tmp/TwoLineTime",
	];
}

static NSString *TLTWritableDirectory(void) {
	static NSString *directory;
	static BOOL failed;
	if (directory || failed) return directory;
	for (NSString *candidate in TLTLogDirectories()) {
		if (![[NSFileManager defaultManager] createDirectoryAtPath:candidate withIntermediateDirectories:YES attributes:nil error:NULL]) continue;
		// access() can say yes where the sandbox still refuses open(): try a real file
		NSString *probe = [candidate stringByAppendingPathComponent:@".probe"];
		int fd = open(probe.fileSystemRepresentation, O_WRONLY | O_CREAT, 0644);
		if (fd < 0) continue;
		close(fd);
		unlink(probe.fileSystemRepresentation);
		directory = candidate;
		return directory;
	}
	failed = YES;
	NSLog(@"[TwoLineTime] no writable log directory, debug log file disabled");
	return nil;
}

static void TLTLogFileAppend(NSString *text) {
	static dispatch_queue_t queue;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		queue = dispatch_queue_create("com.qn.twolinetime.log", DISPATCH_QUEUE_SERIAL);
	});
	long long millis = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
	NSString *process = [[NSProcessInfo processInfo] processName];
	NSString *record = [NSString stringWithFormat:@"%@%lld %@ %@\n", TLTRecordSeparator, millis, process, text];
	dispatch_async(queue, ^{
		NSString *directory = TLTWritableDirectory();
		if (!directory) return;
		NSString *path = [directory stringByAppendingPathComponent:[process stringByAppendingString:@".log"]];
		struct stat st;
		if (stat(path.fileSystemRepresentation, &st) == 0 && st.st_size >= TLTLogFileMaxBytes) {
			rename(path.fileSystemRepresentation, [path stringByAppendingString:@".1"].fileSystemRepresentation);
		}
		int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
		if (fd < 0) return;
		NSData *data = [record dataUsingEncoding:NSUTF8StringEncoding];
		write(fd, data.bytes, data.length);
		close(fd);
	});
}

void TLTLogWrite(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);
	NSLog(@"[TwoLineTime] %@", text);
	TLTLogFileAppend(text);
}

static NSArray<NSString *> *TLTLogPaths(void) {
	NSMutableArray *paths = [NSMutableArray array];
	for (NSString *directory in TLTLogDirectories()) {
		for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL]) {
			if ([name hasSuffix:@".log"] || [name hasSuffix:@".log.1"]) [paths addObject:[directory stringByAppendingPathComponent:name]];
		}
	}
	return paths;
}

NSString *TLTLogFileRead(NSUInteger maxBytes) {
	NSMutableArray<NSArray *> *records = [NSMutableArray array];   // [millis, line]
	for (NSString *path in TLTLogPaths()) {
		NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
		for (NSString *record in [content componentsSeparatedByString:TLTRecordSeparator]) {
			NSRange space = [record rangeOfString:@" "];
			if (space.location == NSNotFound) continue;
			long long millis = [[record substringToIndex:space.location] longLongValue];
			if (millis <= 0) continue;
			[records addObject:@[@(millis), [record substringFromIndex:NSMaxRange(space)]]];
		}
	}
	[records sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
		return [a[0] compare:b[0]];
	}];
	NSDateFormatter *formatter = [NSDateFormatter new];
	formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	NSUInteger total = 0;
	// newest first, so the cut at maxBytes drops the oldest records
	for (NSArray *record in [records reverseObjectEnumerator]) {
		NSString *time = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[record[0] longLongValue] / 1000.0]];
		NSString *line = [NSString stringWithFormat:@"%@ %@", time, record[1]];
		if (total + line.length > maxBytes && lines.count) break;
		total += line.length;
		[lines addObject:line];
	}
	return [[[lines reverseObjectEnumerator] allObjects] componentsJoinedByString:@""];
}

void TLTLogFileClear(void) {
	for (NSString *path in TLTLogPaths()) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

BOOL TLTDeviceHasFaceID(void) {
	if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO; // iPad: its status bar is different
	if ([UIDevice respondsToSelector:@selector(_hasHomeButton)]) return ![UIDevice _hasHomeButton];

	// No such method: go by the model identifier
	struct utsname system;
	uname(&system);
	int major = 0, minor = 0;
	if (sscanf(system.machine, "iPhone%d,%d", &major, &minor) != 2) return NO;
	if ((major == 12 && minor == 8) || (major == 14 && minor == 6)) return NO;  // iPhone SE 2 and 3: Touch ID
	if (major == 10) return minor == 3 || minor == 6;                           // iPhone X; the 8 has Touch ID
	return major >= 11;
}
