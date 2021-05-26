import { EventEmitter } from 'events'
import { join } from 'path'
import { throttle } from 'throttle-debounce'
import { screen } from 'electron'
import type { BrowserWindow, Rectangle } from 'electron'
const lib: AddonExports = require('node-gyp-build')(join(__dirname, '..'))

interface AddonExports {
  start(
    overlayWindowId: Buffer,
    targetWindowTitle: string,
    cb: (e: any) => void
  ): void

  activateOverlay(): void
  focusTarget(): void
}

enum EventType {
  EVENT_ATTACH = 1,
  EVENT_FOCUS = 2,
  EVENT_BLUR = 3,
  EVENT_DETACH = 4,
  EVENT_FULLSCREEN = 5,
  EVENT_MOVERESIZE = 6,
}

export interface AttachEvent {
  hasAccess: boolean | undefined
  isFullscreen: boolean | undefined
  x: number
  y: number
  width: number
  height: number
}

export interface FullscreenEvent {
  isFullscreen: boolean
}

export interface MoveresizeEvent {
  x: number
  y: number
  width: number
  height: number
}

declare interface OverlayWindow {
  on(event: 'attach', listener: (e: AttachEvent) => void): this
  on(event: 'focus', listener: () => void): this
  on(event: 'blur', listener: () => void): this
  on(event: 'detach', listener: () => void): this
  on(event: 'fullscreen', listener: (e: FullscreenEvent) => void): this
  on(event: 'moveresize', listener: (e: MoveresizeEvent) => void): this
}

class OverlayWindow extends EventEmitter {
  private _overlayWindow!: BrowserWindow
  public defaultBehavior = true
  private lastBounds: Rectangle = { x: 0, y: 0, width: 0, height: 0 }

  readonly WINDOW_OPTS = {
    fullscreenable: true,
    skipTaskbar: true,
    frame: false,
    show: false,
    transparent: true,
    // let Chromium to accept any size changes from OS
    resizable: true
  } as const
  
  constructor () {
    super()

    this.on('attach', (e) => {
      if (this.defaultBehavior) {
        // linux: important to show window first before changing fullscreen
        this._overlayWindow.showInactive()
        if (e.isFullscreen !== undefined) {
          this._overlayWindow.setFullScreen(e.isFullscreen)
        }
        this.lastBounds = e
        this.updateOverlayBounds()
      }
    })

    this.on('blur', () => {
      if (this.defaultBehavior && process.platform === 'darwin') {
        // Since we can't attach the window to a parent on Mac, we have to
        // just hide it whenever the target is blurred to prevent it from
        // covering up other apps
        this._overlayWindow.hide()
      }
    })

    this.on('focus', () => {
      if (this.defaultBehavior && process.platform === 'darwin') {
        // We show on focus, but only on Mac. See reasoning in the blur handler
        this._overlayWindow.show()
        // Showing the window will focus the overlay. We don't want to take over
        // control from the target, so we immediately refocus the target
        process.nextTick(() => this.focusTarget())
      }
    })

    this.on('fullscreen', (e) => {
      if (this.defaultBehavior) {
        this._overlayWindow.setFullScreen(e.isFullscreen)
      }
    })

    this.on('detach', () => {
      if (this.defaultBehavior) {
        this._overlayWindow.hide()
      }
    })

    const dispatchMoveresize = throttle(34 /* 30fps */, this.updateOverlayBounds.bind(this))

    this.on('moveresize', (e) => {
      this.lastBounds = e
      dispatchMoveresize()
    })
  }

  private updateOverlayBounds () {
    let lastBounds = this.lastBounds
    if (lastBounds.width != 0 && lastBounds.height != 0) {
      if (process.platform === 'win32') {
        lastBounds = screen.screenToDipRect(this._overlayWindow, this.lastBounds)
      }
      this._overlayWindow.setBounds(lastBounds)
      if (process.platform === 'win32') {
        // if moved to screen with different DPI, 2nd call to setBounds will correctly resize window
        // dipRect must be recalculated as well
        lastBounds = screen.screenToDipRect(this._overlayWindow, this.lastBounds)
        this._overlayWindow.setBounds(lastBounds)
      }
    }
  }

  private handler (e: unknown) {
    switch ((e as { type: EventType }).type) {
      case EventType.EVENT_ATTACH:
        this.emit('attach', e)
        break
      case EventType.EVENT_FOCUS:
        this.emit('focus', e)
        break
      case EventType.EVENT_BLUR:
        this.emit('blur', e)
        break
      case EventType.EVENT_DETACH:
        this.emit('detach', e)
        break
      case EventType.EVENT_FULLSCREEN:
        this.emit('fullscreen', e)
        break
      case EventType.EVENT_MOVERESIZE:
        this.emit('moveresize', e)
        break
    }
  }

  activateOverlay() {
    if (process.platform === 'win32') {
      // reason: - window lags a bit using .focus()
      //         - crashes on close if using .show()
      //         - also crashes if using .moveTop()
      lib.activateOverlay()
    } else {
      this._overlayWindow.focus()
    }
  }

  focusTarget() {
    lib.focusTarget()
  }

  attachTo (overlayWindow: BrowserWindow, targetWindowTitle: string) {
    if (this._overlayWindow) {
      throw new Error('Library can be initialized only once.')
    }
    this._overlayWindow = overlayWindow
    lib.start(overlayWindow.getNativeWindowHandle(), targetWindowTitle, this.handler.bind(this))
  }
}

export const overlayWindow = new OverlayWindow()
