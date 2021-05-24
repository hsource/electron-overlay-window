# Code structure

The main module exposes a singleton overlayWindow that can be used to control
the overlay.

On startup:

- User calls `overlayWindow.attachTo()`
- `attachTo` calls `lib.start()`, which corresponds to the `AddonStart`
  function inside of addon.c
- `AddonStart` largely delegates the platform specific code by calling
  `ow_start_hook`, a function defined for each platform.

## Native module

Immediately on attaching to a window, a background thread executes
`hook_thread`.

## hook_thread

`hook_thread` does the following:

- Hook foreground, minimize events for all windows
- Hook foreground window rename and call `check_and_handle_window`
- Start the event loop

## check_and_handle_window

`check_and_handle_window` does the following:

- Initialize `is_focused`, `is_destroyed`, and other properties on
  `target_info`
- Emits events for the initialization (blur, detach, focus)
- Create hooks for window move and destroy
  - Cleans up any existing hooks before this
- Attaches the target's input handling to the overlay's input handling
- Place the overlay window
- Make the overlay window have the other window as a parent
  - Emit attach and focus
