#import <UIKit/UIKit.h>

// Opens Vitrine's separate library for tracks whose providers explicitly allow downloading.
// This is deliberately separate from Spotify's native offline-download records.
void SGRAuthorizedDownloadsPresent(UIView *source, NSString *trackTitle, NSString *artistName, NSTimeInterval duration);
