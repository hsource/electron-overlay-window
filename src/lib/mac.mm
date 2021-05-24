#include "overlay_window.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <array>

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
  char *title;
  /** Window matching the target title, or null */
  AXUIElementRef element;
  /** Observer that sends all observed events to hookProc */
  AXObserverRef observer;
  bool isFocused;
  bool isDestroyed;
  bool isFullscreen;
};

struct ow_overlay_window {
  NSView *view;
};

struct ow_frontmost_app {
  pid_t pid;
  /** Latest application identified to be frontmost */
  AXUIElementRef element;
  /** Observer that sends all observed events to hookProc */
  AXObserverRef observer;
};

static struct ow_target_window targetInfo = {
    .title = NULL,
    .element = NULL,
    .observer = NULL,
    .isFocused = false,
    .isDestroyed = false,
    .isFullscreen = false // initial state of *overlay* window
};

static struct ow_overlay_window overlayInfo = {.view = NULL};

/**
 * Unlike on Windows and Linux, we have no way to listen to all window
 * foreground changes. As such, we have to always just check when the
 * foreground app changes, and recheck focus/frontmost when it does.
 */
static struct ow_frontmost_app frontmostInfo = {
    .pid = -1, .element = NULL, .observer = NULL};

/** We should emit move/resize events for these notification types */
static std::array<CFStringRef, 2> moveResizeNotificationTypes = {
    kAXMovedNotification, kAXResizedNotification};
static std::array<CFStringRef, 2> focusNotificationTypes = {
    kAXFocusedWindowChangedNotification, kAXApplicationDeactivatedNotification};

bool requestAccessibility(bool showDialog) {
  NSDictionary *opts =
      @{static_cast<id>(kAXTrustedCheckOptionPrompt) : showDialog ? @YES : @NO};
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

  for (NSDictionary *info in (NSArray *)windowList) {
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

static void handleFocusEvent() {
  pid_t pid = getFrontmostAppPID();
  AXUIElementRef frontmostWindow = copyFrontmostWindow(pid);
  checkAndHandleWindow(pid, frontmostWindow);
}

/**
 * If changing this, ensure this function handles all the same
 * `notificationTypes` as are registered in the `checkAndHandleWindow` function
 * below.
 */
static void hookProc(AXObserverRef observer, AXUIElementRef element,
                     CFStringRef cfNotificationType, void *contextData) {
  NSString *notificationType = CFBridgingRelease(cfNotificationType);

  NSLog(@"hookProc with notificationType: %@", notificationType);

  // Handle move/resize events
  for (auto &moveResizeNotificationType : moveResizeNotificationTypes) {
    if ([notificationType
            isEqualToString:(__bridge NSString *)moveResizeNotificationType]) {
      CGWindowID windowID = getWindowID(element);
      emitMoveResizeEvent(windowID);
    }
  }

  // Handle move/resize events
  for (auto &focusNotificationType : focusNotificationTypes) {
    if ([notificationType
            isEqualToString:(__bridge NSString *)focusNotificationType]) {
      handleFocusEvent();
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
               std::array<CFStringRef, N> notificationTypes) {
  AXObserverRef observer = NULL;
  AXError error = AXObserverCreate(pid, hookProc, &observer);
  if (error != kAXErrorSuccess) {
    return NULL;
  }

  if (element) {
    for (auto &notificationType : notificationTypes) {
      AXObserverAddNotification(observer, element, notificationType, NULL);
      NSLog(@"Creating observer for type: %@", notificationType);
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
 * Update the `frontmostInfo` if the `frontmostWindow` has changed.
 */
template <typename WindowInfo, std::size_t NotificationTypesSize>
static void updateWindowInfo(
    pid_t pid, AXUIElementRef element, WindowInfo &windowInfo,
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

  windowInfo.element = element;
  CFRetain(windowInfo.element);
  windowInfo.observer =
      createObserver(pid, windowInfo.element, notificationTypes);
}

/**
 * Called with the frontmost window and its PID.
 */
static void checkAndHandleWindow(pid_t pid, AXUIElementRef frontmostWindow) {
  CGWindowID windowID = getWindowID(frontmostWindow);
  CGWindowID targetWindowID = getWindowID(targetInfo.element);

  // Emit blur/detach/focus if the frontmost window has changed
  if (targetWindowID > 0) {
    if (targetWindowID != windowID) {
      if (targetInfo.isFocused) {
        targetInfo.isFocused = false;
        struct ow_event e = {.type = OW_BLUR};
        ow_emit_event(&e);
      }

      if (targetInfo.isDestroyed) {
        targetWindowID = 0;
        targetInfo.isDestroyed = false;
        struct ow_event e = {.type = OW_DETACH};
        ow_emit_event(&e);
      }
    } else if (targetWindowID == windowID) {
      if (!targetInfo.isFocused) {
        targetInfo.isFocused = true;
        struct ow_event e = {.type = OW_FOCUS};
        ow_emit_event(&e);
      }
      return;
    }
  }

  if (pid != frontmostInfo.pid) {
    frontmostInfo.pid = pid;
    AXUIElementRef application = AXUIElementCreateApplication(pid);
    updateWindowInfo(pid, application, frontmostInfo, focusNotificationTypes);
  }

  // For the rest of this function, only run if the title matches
  NSString *title = getTitleForWindow(frontmostWindow);
  // if (!title || ![title isEqualToString: @(targetInfo.title)]) {
  //   return;
  // }

  // The rest of the initialization/teardown logic only needs to be run
  // if the target window has changed
  if (targetWindowID == windowID) {
    return;
  }

  updateWindowInfo(pid, frontmostWindow, targetInfo,
                   moveResizeNotificationTypes);

  // Emit the attach and focus events
  struct ow_event e = {.type = OW_ATTACH,
                       .data.attach = {.has_access = -1, .is_fullscreen = -1}};
  bool getBoundsSuccess = getBounds(windowID, &e.data.attach.bounds);
  if (getBoundsSuccess) {
    // emit OW_ATTACH
    ow_emit_event(&e);

    targetInfo.isFocused = true;
    e.type = OW_FOCUS;
    ow_emit_event(&e);
  } else {
    // something went wrong, did the target window die right after becoming
    // active?
    targetWindowID = 0;
  }
}

/**
 * Initializes listeners for the frontmost window, and then starts the event
 * loop.
 */
static void hookThread(void *_arg) {
  pid_t pid = getFrontmostAppPID();
  AXUIElementRef frontmostWindow = copyFrontmostWindow(pid);
  checkAndHandleWindow(pid, frontmostWindow);
  CFRelease(frontmostWindow);

  // Start the RunLoop so that our AXObservers added by CFRunLoopAddSource
  // work properly
  CFRunLoopRun();
}

void ow_start_hook(char *target_window_title, void *overlay_window_id) {
  targetInfo.title = target_window_title;
  overlayInfo.view = *static_cast<NSView **>(overlay_window_id);
  uv_thread_create(&hook_tid, hookThread, NULL);
}
