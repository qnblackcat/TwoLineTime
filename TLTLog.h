#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// TLTLog is the only way to log, and it does nothing unless the Debug switch is on (Settings → TwoLineTime →
// Troubleshooting). A macro, so the arguments are not evaluated while Debug is off. While on, each line goes to the
// unified log with the "[TwoLineTime]" prefix and is appended to a log file (capped at TLTLogFileMaxBytes,
// rotated to <name>.1).

#define TLTLogFileMaxBytes (128 * 1024)

#define TLTLog(fmt, ...) do { if (TLTDebugOn) TLTLogWrite(@"" fmt, ##__VA_ARGS__); } while (0)

// Set by the tweak (SpringBoard) from the Debug preference.
extern BOOL TLTDebugOn;

// What TLTLog calls once Debug is known to be on; don't call it directly.
void TLTLogWrite(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Used by the preference bundle: the log merged by time, newest last, limited to the last maxBytes characters.
NSString *TLTLogFileRead(NSUInteger maxBytes);
void TLTLogFileClear(void);

// YES on an iPhone with a notch or the Dynamic Island (Face ID), NO for iPhones with a Home button (Touch ID, including SE 2 and 3) and for iPads.
BOOL TLTDeviceHasFaceID(void);

#ifdef __cplusplus
}
#endif
