"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.overlayWindow = void 0;
const events_1 = require("events");
const path_1 = require("path");
const throttle_debounce_1 = require("throttle-debounce");
const electron_1 = require("electron");
const lib = require('node-gyp-build')(path_1.join(__dirname, '..'));
var EventType;
(function (EventType) {
    EventType[EventType["EVENT_ATTACH"] = 1] = "EVENT_ATTACH";
    EventType[EventType["EVENT_FOCUS"] = 2] = "EVENT_FOCUS";
    EventType[EventType["EVENT_BLUR"] = 3] = "EVENT_BLUR";
    EventType[EventType["EVENT_DETACH"] = 4] = "EVENT_DETACH";
    EventType[EventType["EVENT_FULLSCREEN"] = 5] = "EVENT_FULLSCREEN";
    EventType[EventType["EVENT_MOVERESIZE"] = 6] = "EVENT_MOVERESIZE";
})(EventType || (EventType = {}));
const isMac = process.platform === 'darwin';
class OverlayWindow extends events_1.EventEmitter {
    constructor() {
        super();
        this.defaultBehavior = true;
        this.lastBounds = { x: 0, y: 0, width: 0, height: 0 };
        this.WINDOW_OPTS = {
            fullscreenable: true,
            skipTaskbar: true,
            frame: false,
            show: false,
            transparent: true,
            // let Chromium to accept any size changes from OS
            resizable: true,
            // disable shadow for Mac OS
            hasShadow: false,
            // float above all windows on Mac OS
            alwaysOnTop: isMac
        };
        this.on('attach', (e) => {
            if (this.defaultBehavior) {
                // linux: important to show window first before changing fullscreen
                this._overlayWindow.showInactive();
                if (isMac) {
                    this._overlayWindow.setVisibleOnAllWorkspaces(e.isFullscreen || false, { visibleOnFullScreen: true });
                }
                if (e.isFullscreen !== undefined) {
                    this.handleFullscreen(e.isFullscreen);
                }
                this.lastBounds = e;
                this.updateOverlayBounds();
            }
        });
        this.on('blur', () => {
            if (this.defaultBehavior && process.platform === 'darwin') {
                // Since we can't attach the window to a parent on Mac, we have to
                // just hide it whenever the target is blurred to prevent it from
                // covering up other apps
                this._overlayWindow.hide();
            }
        });
        this.on('focus', () => {
            if (this.defaultBehavior && process.platform === 'darwin') {
                // We show on focus, but only on Mac. See reasoning in the blur handler
                this._overlayWindow.show();
                // Showing the window will focus the overlay. We don't want to take over
                // control from the target, so we immediately refocus the target
                process.nextTick(() => this.focusTarget());
            }
        });
        this.on('fullscreen', (e) => {
            if (this.defaultBehavior) {
                this.handleFullscreen(e.isFullscreen);
            }
        });
        this.on('detach', () => {
            if (this.defaultBehavior) {
                this._overlayWindow.hide();
            }
        });
        const dispatchMoveresize = throttle_debounce_1.throttle(34 /* 30fps */, this.updateOverlayBounds.bind(this));
        this.on('moveresize', (e) => {
            this.lastBounds = e;
            dispatchMoveresize();
        });
    }
    async handleFullscreen(isFullscreen) {
        if (isMac) {
            // On Mac, only a single app can be fullscreen, so we can't go
            // fullscreen. We get around it by making it display on all workspaces,
            // based on code from:
            // https://github.com/electron/electron/issues/10078#issuecomment-754105005
            this._overlayWindow.setVisibleOnAllWorkspaces(isFullscreen, { visibleOnFullScreen: true });
            if (isFullscreen) {
                const display = electron_1.screen.getPrimaryDisplay();
                this._overlayWindow.setBounds(display.bounds);
            }
            else {
                // Set it back to `lastBounds` as set before fullscreen
                this.updateOverlayBounds();
            }
        }
        else {
            this._overlayWindow.setFullScreen(isFullscreen);
        }
    }
    updateOverlayBounds() {
        let lastBounds = this.lastBounds;
        if (lastBounds.width != 0 && lastBounds.height != 0) {
            if (process.platform === 'win32') {
                lastBounds = electron_1.screen.screenToDipRect(this._overlayWindow, this.lastBounds);
            }
            this._overlayWindow.setBounds(lastBounds);
            if (process.platform === 'win32') {
                // if moved to screen with different DPI, 2nd call to setBounds will correctly resize window
                // dipRect must be recalculated as well
                lastBounds = electron_1.screen.screenToDipRect(this._overlayWindow, this.lastBounds);
                this._overlayWindow.setBounds(lastBounds);
            }
        }
    }
    handler(e) {
        switch (e.type) {
            case EventType.EVENT_ATTACH:
                this.emit('attach', e);
                break;
            case EventType.EVENT_FOCUS:
                this.emit('focus', e);
                break;
            case EventType.EVENT_BLUR:
                this.emit('blur', e);
                break;
            case EventType.EVENT_DETACH:
                this.emit('detach', e);
                break;
            case EventType.EVENT_FULLSCREEN:
                this.emit('fullscreen', e);
                break;
            case EventType.EVENT_MOVERESIZE:
                this.emit('moveresize', e);
                break;
        }
    }
    activateOverlay() {
        if (process.platform === 'win32') {
            // reason: - window lags a bit using .focus()
            //         - crashes on close if using .show()
            //         - also crashes if using .moveTop()
            lib.activateOverlay();
        }
        else {
            this._overlayWindow.focus();
        }
    }
    focusTarget() {
        lib.focusTarget();
    }
    attachTo(overlayWindow, targetWindowTitle) {
        if (this._overlayWindow) {
            throw new Error('Library can be initialized only once.');
        }
        this._overlayWindow = overlayWindow;
        lib.start(overlayWindow.getNativeWindowHandle(), targetWindowTitle, this.handler.bind(this));
    }
}
exports.overlayWindow = new OverlayWindow();
//# sourceMappingURL=index.js.map