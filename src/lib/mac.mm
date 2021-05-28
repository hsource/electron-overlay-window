#include "overlay_window.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <array>

/**
 * FORMATTING: This file was formatted automatically with clang-format.
 * We recommend formatting with clang-format before commiting updates.
 *
 * This file handles the overlay window for Mac. It:
 *
 * 1. Uses the accessibility API, creates two sets of listeners
 *    - Listen to any window switches by attaching to the foreground app
 *    - When it finds the targetWindow, listen to any move/resize events
 *      by attaching to the targetWindow.
 * 2. Sends those events back up via the standard overlay_window APIs.
 * 3. The Javascript code only shows the overlay window when the target window
 *    is in the foreground.
 */

extern "C" {
/**
 * Undocumented, but widely used API to get the Window ID
 * See
 * https://stackoverflow.com/questions/7422666/uniquely-identify-active-window-on-os-x
 */
AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
}

static void checkAndHandleWindow(pid_t pid, AXUIElementRef frontmostWindow);

struct ow_target_window {
  const char *title;
  /** Set to -1 if not initialized yet */
  pid_t pid;
  /** Window matching the target title, or null */
  AXUIElementRef element;
  /** Observer that sends all observed events to hookProc */
  AXObserverRef observer;
  bool isFocused;
  bool isDestroyed;
};

struct ow_overlay_window {
  NSWindow *window;
};

struct ow_frontmost_app {
  /** Set to -1 if not initialized */
  pid_t pid;
  /** Set to 0 if not initialized */
  CGWindowID windowID;
  /** Latest application (not window) identified to be frontmost */
  AXUIElementRef element;
  /** Observer that sends all observed events to hookProc */
  AXObserverRef observer;
};

/**
 * This should only be modified inside the checkAndHandleWindow
 * function for more centralized logic.
 */
static struct ow_target_window targetInfo = {
    .title = NULL,
    .pid = -1,
    .element = NULL,
    .observer = NULL,
    .isFocused = false,
};

static struct ow_overlay_window overlayInfo = {.window = NULL};

/**
 * Unlike on Windows and Linux, we have no way to listen to all window
 * foreground changes. As such, we have to always just check when the
 * foreground app changes, and recheck focus/frontmost when it does.
 */
static struct ow_frontmost_app frontmostInfo = {
    .pid = -1, .windowID = 0, .element = NULL, .observer = NULL};

// Window notifications: these are attached to the target window
static std::array<CFStringRef, 4> windowNotificationTypes = {
    kAXUIElementDestroyedNotification, kAXMovedNotification,
    kAXResizedNotification, kAXTitleChangedNotification};

// Applicaton notifications: these are attached to the foreground (not
// necessarily the target) app
static std::array<CFStringRef, 5> appFocusNotificationTypes = {
    kAXFocusedWindowChangedNotification, kAXApplicationDeactivatedNotification,
    kAXApplicationHiddenNotification, kAXMainWindowChangedNotification,
    kAXWindowMiniaturizedNotification};

bool requestAccessibility(bool showDialog) {
  NSDictionary *opts =
      @{(__bridge id)(kAXTrustedCheckOptionPrompt) : showDialog ? @YES : @NO};
  return AXIsProcessTrustedWithOptions(static_cast<CFDictionaryRef>(opts));
}

/**
 * Make sure to release the returns of all "copy" functions with CFRelease
 * when done
 */
static AXUIElementRef copyFrontmostWindow(pid_t pid) {
  AXUIElementRef appElement = AXUIElementCreateApplication(pid);

  AXUIElementRef window = NULL;
  AXError error = AXUIElementCopyAttributeValue(
      appElement, kAXFocusedWindowAttribute, (CFTypeRef *)&window);
  CFRelease(appElement);
  if (error != kAXErrorSuccess) {
    return NULL;
  }

  return window;
}

/** Gets the process ID of the current frontmost app */
static pid_t getFrontmostAppPID() {
  NSRunningApplication *app =
      [[NSWorkspace sharedWorkspace] frontmostApplication];
  return [app processIdentifier];
}

/**
 * Equivalent to the window's windowNumber. Will be <= 0 when invalid,
 * according to
 * https://developer.apple.com/documentation/appkit/nswindow/1419068-windownumber?language=objc
 */
static CGWindowID getWindowID(AXUIElementRef window) {
  CGWindowID windowID = 0;
  _AXUIElementGetWindow(window, &windowID);
  return windowID;
}

static NSString *getTitleForWindow(AXUIElementRef window) {
  CFStringRef cfTitle = NULL;
  AXError error = AXUIElementCopyAttributeValue(window, kAXTitleAttribute,
                                                (CFTypeRef *)&cfTitle);
  if (error != kAXErrorSuccess) {
    return NULL;
  }

  NSString *title = CFBridgingRelease(cfTitle);
  return title;
}

/**
 * Copied from
 * https://github.com/sentialx/node-window-manager/blob/v2.2.0/lib/macos.mm#L25
 */
static NSDictionary *getWindowInfo(CGWindowID windowID) {
  CGWindowListOption listOptions =
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements;
  CFArrayRef windowList =
      CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID);

  for (NSDictionary *info in (__bridge NSArray *)windowList) {
    NSNumber *windowNumber = info[(id)kCGWindowNumber];

    if ([windowNumber intValue] == (int)windowID) {
      // Retain property list so it doesn't get release w. windowList
      CFRetain((CFPropertyListRef)info);
      CFRelease(windowList);
      return info;
    }
  }

  if (windowList) {
    CFRelease(windowList);
  }
  return NULL;
}

/**
 * Gets the current bounds for a `windowID`. Returns true only if we
 * successfully wrote the bounds to `outputBounds`.
 */
static bool getBounds(CGWindowID windowID, ow_window_bounds *outputBounds) {
  if (windowID <= 0) {
    return false;
  }
  NSDictionary *windowInfo = getWindowInfo(windowID);
  if (!windowInfo) {
    return false;
  }
  NSDictionary *inputBounds = windowInfo[(id)kCGWindowBounds];
  if (!inputBounds) {
    return false;
  }

  NSNumber *x = inputBounds[@"X"];
  NSNumber *y = inputBounds[@"Y"];
  NSNumber *width = inputBounds[@"Width"];
  NSNumber *height = inputBounds[@"Height"];

  if (x && y && width && height) {
    *outputBounds = {
        .x = [x intValue],
        .y = [y intValue],
        .width = static_cast<uint32_t>([width intValue]),
        .height = static_cast<uint32_t>([height intValue]),
    };
    return true;
  };

  return false;
}

static void emitMoveResizeEvent(CGWindowID windowID) {
  struct ow_window_bounds bounds;
  if (!targetInfo.element) {
    return;
  }
  CGWindowID targetWindowID = getWindowID(targetInfo.element);
  if (windowID != targetWindowID) {
    return;
  }

  if (getBounds(windowID, &bounds)) {
    struct ow_event e = {.type = OW_MOVERESIZE,
                         .data.moveresize = {.bounds = bounds}};
    ow_emit_event(&e);
  }
}

/**
 * Calls checkAndHandleWindow with the latest window
 */
static void handleFocusMaybeChanged() {
  pid_t frontmostPID = getFrontmostAppPID();
  AXUIElementRef frontmostWindow = copyFrontmostWindow(frontmostPID);

  checkAndHandleWindow(frontmostPID, frontmostWindow);

  if (frontmostWindow) {
    CFRelease(frontmostWindow);
  }
}

/**
 * Handle notifications (activate, deactivate, focus change) from the
 * frontmost application.
 */
static void hookProcFrontmostApplication(AXObserverRef observer,
                                         AXUIElementRef element,
                                         CFStringRef cfNotificationType,
                                         void *contextData) {
  // NSString *notificationType = CFBridgingRelease(cfNotificationType);
  // NSLog(@"hookProcFrontmostApplication: processing for type %@",
  // notificationType);

  handleFocusMaybeChanged();
}

/**
 * Handle notifications (move, resize, destroy) from the target window.
 */
static void hookProcTargetWindow(AXObserverRef observer, AXUIElementRef element,
                                 CFStringRef cfNotificationType,
                                 void *contextData) {
  NSString *notificationType = (__bridge NSString *)cfNotificationType;
  // NSLog(@"hookProcTargetWindow: processing for type %@", notificationType);

  // Handle move/resize events
  for (auto &moveResizeNotificationType :
       {kAXMovedNotification, kAXResizedNotification}) {
    if ([notificationType
            isEqualToString:(__bridge NSString *)moveResizeNotificationType]) {
      CGWindowID windowID = getWindowID(element);
      emitMoveResizeEvent(windowID);
    }
  }

  // Handle destroy
  if ([notificationType
          isEqualToString:(__bridge NSString *)
                              kAXUIElementDestroyedNotification]) {
    targetInfo.isDestroyed = true;
    handleFocusMaybeChanged();
  }

  // Handle title change
  if ([notificationType
          isEqualToString:(__bridge NSString *)kAXTitleChangedNotification]) {
    NSString *title = getTitleForWindow(element);
    if (title) {
      targetInfo.title = [title UTF8String];
    }
  }
}

/**
 * Creates an observer for observing a set of notification types for a specific
 * process/window combination.
 *
 * Most of this logic is based on code from
 * https://stackoverflow.com/a/853953/319066
 */
template <std::size_t N>
static AXObserverRef
createObserver(pid_t pid, AXUIElementRef element,
               std::array<CFStringRef, N> notificationTypes,
               bool isTargetWindow) {
  AXObserverRef observer = NULL;
  AXError error =
      isTargetWindow
          ? AXObserverCreate(pid, hookProcTargetWindow, &observer)
          : AXObserverCreate(pid, hookProcFrontmostApplication, &observer);
  if (error != kAXErrorSuccess) {
    return NULL;
  }

  if (element) {
    for (auto &notificationType : notificationTypes) {
      AXObserverAddNotification(observer, element, notificationType, NULL);
      // NSLog(@"createObserver: created for PID %d with type %@", pid,
      //       notificationType);
    }
  }
  CFRunLoopAddSource([[NSRunLoop currentRunLoop] getCFRunLoop],
                     AXObserverGetRunLoopSource(observer),
                     kCFRunLoopDefaultMode);
  return observer;
}

/**
 * Removes an observer from the event loop and cleans up all handlers.
 * Does not release any resources.
 */
template <std::size_t N>
static void removeObserver(AXObserverRef observer, AXUIElementRef element,
                           std::array<CFStringRef, N> notificationTypes) {
  if (!observer) {
    return;
  }

  CFRunLoopRemoveSource([[NSRunLoop currentRunLoop] getCFRunLoop],
                        AXObserverGetRunLoopSource(observer),
                        kCFRunLoopDefaultMode);
  if (element) {
    for (auto &notificationType : notificationTypes) {
      AXObserverRemoveNotification(observer, element, notificationType);
    }
  }
}

/**
 * Clear the `windowInfo`, making sure to release memory of associated
 * observers for the given `notificationTypes` and the window itself.
 */
template <typename WindowInfo, std::size_t NotificationTypesSize>
static void clearWindowInfo(
    WindowInfo &windowInfo,
    std::array<CFStringRef, NotificationTypesSize> notificationTypes) {
  if (windowInfo.observer) {
    removeObserver(windowInfo.observer, windowInfo.element, notificationTypes);
    CFRelease(windowInfo.observer);
    windowInfo.observer = NULL;
  }

  if (windowInfo.element) {
    CFRelease(windowInfo.element);
    windowInfo.element = NULL;
  }
}

/**
 * Clear and reinitialize the `windowInfo` object for the current element,
 * including any observers for the `notificationTypes`.
 */
template <typename WindowInfo, std::size_t NotificationTypesSize>
static void updateWindowInfo(
    pid_t pid, AXUIElementRef element, WindowInfo &windowInfo,
    std::array<CFStringRef, NotificationTypesSize> notificationTypes,
    bool isTargetWindow) {
  clearWindowInfo(windowInfo, notificationTypes);

  windowInfo.element = element;
  CFRetain(windowInfo.element);
  windowInfo.observer = createObserver(pid, windowInfo.element,
                                       notificationTypes, isTargetWindow);
}

/**
 * For a brief while after we reattach accessibility observers to a new app,
 * that new app may not report any events. For that amount of time, we
 * manually poll for changes.
 *
 * This seems to only last for 2-3 seconds, but we poll for 5s to be safe.
 */
static void pollAfterAppObserverChange() {
  NSTimeInterval secondsToPoll = 5;
  NSTimeInterval startTime = [[NSDate date] timeIntervalSince1970];
  [NSTimer
      scheduledTimerWithTimeInterval:0.2
                             repeats:YES
                               block:^(NSTimer *timer) {
                                 NSTimeInterval currentTime =
                                     [[NSDate date] timeIntervalSince1970];
                                 if (currentTime - startTime >= secondsToPoll &&
                                     timer) {
                                   [timer invalidate];
                                   timer = NULL;
                                 }
                                 handleFocusMaybeChanged();
                               }];
}

/**
 * Called with the frontmost window and its PID.
 */
static void checkAndHandleWindow(pid_t pid, AXUIElementRef frontmostWindow) {
  CGWindowID frontmostWindowID = getWindowID(frontmostWindow);
  CGWindowID targetWindowID = getWindowID(targetInfo.element);
  CGWindowID overlayWindowID =
      overlayInfo.window ? [overlayInfo.window windowNumber] : 0;

  // Emit blur/detach/focus if the frontmost window has changed
  // We count the target as focused even if the overlay is focused, since
  // we don't want to hide the overlay when the user is using it
  bool targetFocused =
      frontmostWindowID != 0 && targetWindowID == frontmostWindowID;

  if (targetFocused && !targetInfo.isFocused) {
    targetInfo.isFocused = true;
    struct ow_event e = {.type = OW_FOCUS};
    // NSLog(@"checkAndHandleWindow: focus");
    ow_emit_event(&e);
  } else if (!targetFocused && targetInfo.isFocused) {
    if (targetInfo.isDestroyed || frontmostWindowID != overlayWindowID) {
      targetInfo.isFocused = false;
      struct ow_event e = {.type = OW_BLUR};
      // NSLog(@"checkAndHandleWindow: blur");
      ow_emit_event(&e);
    }

    if (targetInfo.isDestroyed) {
      targetInfo.pid = -1;
      targetInfo.isDestroyed = false;
      struct ow_event e = {.type = OW_DETACH};
      clearWindowInfo(targetInfo, windowNotificationTypes);
      // NSLog(@"checkAndHandleWindow: detach");
      ow_emit_event(&e);
    }
  }

  frontmostInfo.windowID = frontmostWindowID;
  // Ensure that the window focus/blur observers are attached to the foreground
  // window at all times
  if (pid != frontmostInfo.pid) {
    frontmostInfo.pid = pid;
    AXUIElementRef application = AXUIElementCreateApplication(pid);
    updateWindowInfo(pid, application, frontmostInfo, appFocusNotificationTypes,
                     /* isTargetWindow */ false);
    pollAfterAppObserverChange();
  }

  // For the rest of this function, only run if the title matches
  NSString *title = getTitleForWindow(frontmostWindow);
  if (!title || ![title isEqualToString:@(targetInfo.title)]) {
    return;
  }

  // The rest of the initialization/teardown logic only needs to be run
  // if the target window has changed
  if (targetWindowID == frontmostWindowID) {
    return;
  }

  targetInfo.pid = pid;
  updateWindowInfo(pid, frontmostWindow, targetInfo, windowNotificationTypes,
                   /* isTargetWindow */ true);

  // Emit the attach and focus events
  struct ow_event e = {.type = OW_ATTACH,
                       .data.attach = {.has_access = -1, .is_fullscreen = -1}};
  bool getBoundsSuccess = getBounds(frontmostWindowID, &e.data.attach.bounds);
  if (getBoundsSuccess) {
    // emit OW_ATTACH
    ow_emit_event(&e);
    // NSLog(@"checkAndHandleWindow: attach");

    targetInfo.isFocused = true;
    e.type = OW_FOCUS;
    // NSLog(@"checkAndHandleWindow: post-attach focus");
    ow_emit_event(&e);
  } else {
    // something went wrong, did the target window die right after becoming
    // active?
    targetWindowID = 0;
  }
}

/**
 * Request the accessibility permission and sleep repeatedly until it's granted.
 */
static void waitUntilAccessibilityGranted() {
  NSString *trustedCheckOptionPromptKey =
      (__bridge NSString *)(kAXTrustedCheckOptionPrompt);
  bool trusted = AXIsProcessTrustedWithOptions(static_cast<CFDictionaryRef>(
      @{trustedCheckOptionPromptKey : @YES}));
  // NSLog(@"waitUntilAccessibilityGranted: initial %d", trusted);

  while (!trusted) {
    [NSThread sleepForTimeInterval:1.0];
    // NSLog(@"waitUntilAccessibilityGranted: polling");
    trusted = AXIsProcessTrustedWithOptions(static_cast<CFDictionaryRef>(
        @{trustedCheckOptionPromptKey : @NO}));
  }
}

/**
 * Initializes listeners for the frontmost window, and then starts the event
 * loop.
 */
static void hookThread(void *_arg) {
  waitUntilAccessibilityGranted();
  handleFocusMaybeChanged();

  // Start the RunLoop so that our AXObservers added by CFRunLoopAddSource
  // work properly
  CFRunLoopRun();
}

void ow_start_hook(char *target_window_title, void *overlay_window_id) {
  targetInfo.title = target_window_title;
  NSView *overlayView = *(NSView * __weak *)(overlay_window_id);
  NSWindow *overlayWindow = [overlayView window];
  overlayInfo.window = overlayWindow;

  // Have the overlay window be above everything else when it's visible
  [overlayWindow setLevel:NSFloatingWindowLevel];
  // Hide the shadow, so that we can hide the whole window using CSS
  [overlayWindow setHasShadow:NO];

  uv_thread_create(&hook_tid, hookThread, NULL);
}

void ow_activate_overlay() {
  [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

void ow_focus_target() {
  if (targetInfo.pid < 0 || !targetInfo.element) {
    return;
  }

  AXUIElementRef app = AXUIElementCreateApplication(targetInfo.pid);
  AXUIElementSetAttributeValue(app, kAXFrontmostAttribute, kCFBooleanTrue);
  AXUIElementRef window = targetInfo.element;
  AXUIElementSetAttributeValue(window, kAXMainAttribute, kCFBooleanTrue);
}
