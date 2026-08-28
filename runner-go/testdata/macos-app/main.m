#import <Cocoa/Cocoa.h>

@interface RobineAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@end

@implementation RobineAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  NSRect frame = NSMakeRect(0, 0, 560, 320);
  self.window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.window.title = @"Robine Runner Fixture";
  [self.window center];
  [self.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  (void)sender;
  return YES;
}

@end

int main(int argc, const char *argv[]) {
  (void)argc;
  (void)argv;
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    RobineAppDelegate *delegate = [RobineAppDelegate new];
    application.delegate = delegate;
    [application run];
  }
  return 0;
}
