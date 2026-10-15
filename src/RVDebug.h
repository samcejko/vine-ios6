#import <Foundation/Foundation.h>

// Test commands for driving Vine over SSH (`uiopen 'vine://revine/<command>?...'`), handled only while the file
// /Library/Application Support/Revine/debug exists (only root can create it). Commands:
//   dump                 every visible button, label, text field and table row with its frame (to the log)
//   snapshot             the screen into the app's tmp/screen.png
//   press?x=&y=          a tap at a point (tap recognizer, control or table row under it)
//   tap?text=            a tap on the button, label or row showing this text
//   type?n=&text=&submit=1   text into the n-th text field (Return pressed when submit=1)
//   alert?n=             the alert on screen answered with button n (default: cancel)
//   back, close          pop the navigation stack / dismiss what is presented
@interface RVDebug : NSObject

// Hooks the app delegate's URL handling (call once at load)
+ (void)install;

@end
