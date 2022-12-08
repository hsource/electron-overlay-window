"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.OverlayController = exports.OVERLAY_WINDOW_OPTS = void 0;
const events_1 = require("events");
const path_1 = require("path");
const throttle_debounce_1 = require("throttle-debounce");
const electron_1 = require("electron");
const electron_2 = require("electron");
const lib = require('node-gyp-build')((0, path_1.join)(__dirname, '..'));
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
exports.OVERLAY_WINDOW_OPTS = {
    fullscreenable: true,
    skipTaskbar: true,
    frame: false,
    show: false,
    transparent: true,
    // let Chromium to accept any size changes from OS
    resizable: true,
    // disable shadow for Mac OS
    hasShadow: !isMac,
    // float above all windows on Mac OS
    alwaysOnTop: isMac
};
class OverlayControllerGlobal {
    constructor() {
        // Exposed so that apps can get the current bounds of the target
        // NOTE: stores screen physical rect on Windows
        this.targetBounds = { x: 0, y: 0, width: 0, height: 0 };
        this.targetHasFocus = false;
        // The height of a title bar on a standard window. Only measured on Mac
        this.macTitleBarHeight = 0;
        this.attachOptions = {};
        this.events = new events_1.EventEmitter();
        this.events.on('attach', (e) => {
            this.targetHasFocus = true;
            this.electronWindow.setIgnoreMouseEvents(true);
            this.electronWindow.showInactive();
            if (process.platform === 'linux') {
                this.electronWindow.setSkipTaskbar(true);
            }
            this.electronWindow.setAlwaysOnTop(true, 'screen-saver');
            if (e.isFullscreen !== undefined) {
                this.handleFullscreen(e.isFullscreen);
            }
            this.targetBounds = e;
            this.updateOverlayBounds();
        });
        this.events.on('fullscreen', (e) => {
            this.handleFullscreen(e.isFullscreen);
        });
        this.events.on('detach', () => {
            this.targetHasFocus = false;
            this.electronWindow.hide();
        });
        const dispatchMoveresize = (0, throttle_debounce_1.throttle)(34 /* 30fps */, this.updateOverlayBounds.bind(this));
        this.events.on('moveresize', (e) => {
            this.targetBounds = e;
            dispatchMoveresize();
        });
        this.events.on('blur', () => {
            this.targetHasFocus = false;
            if (isMac || this.focusNext !== 'overlay' && !this.electronWindow.isFocused()) {
                this.electronWindow.hide();
            }
        });
        this.events.on('focus', () => {
            this.focusNext = undefined;
            this.targetHasFocus = true;
            this.electronWindow.setIgnoreMouseEvents(true);
            if (!this.electronWindow.isVisible()) {
                this.electronWindow.showInactive();
                if (process.platform === 'linux') {
                    this.electronWindow.setSkipTaskbar(true);
                }
                this.electronWindow.setAlwaysOnTop(true, 'screen-saver');
            }
        });
    }
    async handleFullscreen(isFullscreen) {
        if (isMac) {
            // On Mac, only a single app can be fullscreen, so we can't go
            // fullscreen. We get around it by making it display on all workspaces,
            // based on code from:
            // https://github.com/electron/electron/issues/10078#issuecomment-754105005
            this.electronWindow.setVisibleOnAllWorkspaces(isFullscreen, { visibleOnFullScreen: true });
            if (isFullscreen) {
                const display = electron_1.screen.getPrimaryDisplay();
                this.electronWindow.setBounds(display.bounds);
            }
            else {
                // Set it back to `lastBounds` as set before fullscreen
                this.updateOverlayBounds();
            }
        }
        else {
            this.electronWindow.setFullScreen(isFullscreen);
        }
    }
    updateOverlayBounds() {
        let lastBounds = this.adjustBoundsForMacTitleBar(this.targetBounds);
        if (lastBounds.width === 0 || lastBounds.height === 0)
            return;
        if (process.platform === 'win32') {
            lastBounds = electron_1.screen.screenToDipRect(this.electronWindow, this.targetBounds);
        }
        this.electronWindow.setBounds(lastBounds);
        // if moved to screen with different DPI, 2nd call to setBounds will correctly resize window
        // dipRect must be recalculated as well
        if (process.platform === 'win32') {
            lastBounds = electron_1.screen.screenToDipRect(this.electronWindow, this.targetBounds);
            this.electronWindow.setBounds(lastBounds);
        }
    }
    handler(e) {
        switch (e.type) {
            case EventType.EVENT_ATTACH:
                this.events.emit('attach', e);
                break;
            case EventType.EVENT_FOCUS:
                this.events.emit('focus', e);
                break;
            case EventType.EVENT_BLUR:
                this.events.emit('blur', e);
                break;
            case EventType.EVENT_DETACH:
                this.events.emit('detach', e);
                break;
            case EventType.EVENT_FULLSCREEN:
                this.events.emit('fullscreen', e);
                break;
            case EventType.EVENT_MOVERESIZE:
                this.events.emit('moveresize', e);
                break;
        }
    }
    /**
     * Create a dummy window to calculate the title bar height on Mac. We use
     * the title bar height to adjust the size of the overlay to not overlap
     * the title bar. This helps Mac match the behaviour on Windows/Linux.
     */
    calculateMacTitleBarHeight() {
        const testWindow = new electron_2.BrowserWindow({
            width: 400,
            height: 300,
            webPreferences: {
                nodeIntegration: true
            },
            show: false,
        });
        const fullHeight = testWindow.getSize()[1];
        const contentHeight = testWindow.getContentSize()[1];
        this.macTitleBarHeight = fullHeight - contentHeight;
        testWindow.close();
    }
    /** If we're on a Mac, adjust the bounds to not overlap the title bar */
    adjustBoundsForMacTitleBar(bounds) {
        if (!isMac || !this.attachOptions.hasTitleBarOnMac) {
            return bounds;
        }
        const newBounds = {
            ...bounds,
            y: bounds.y + this.macTitleBarHeight,
            height: bounds.height - this.macTitleBarHeight
        };
        return newBounds;
    }
    activateOverlay() {
        this.focusNext = 'overlay';
        this.electronWindow.setIgnoreMouseEvents(false);
        this.electronWindow.focus();
    }
    focusTarget() {
        this.focusNext = 'target';
        this.electronWindow.setIgnoreMouseEvents(true);
        lib.focusTarget();
    }
    attachByTitle(electronWindow, targetWindowTitle, options = {}) {
        if (this.electronWindow) {
            throw new Error('Library can be initialized only once.');
        }
        else {
            this.electronWindow = electronWindow;
        }
        this.electronWindow.on('blur', () => {
            if (!this.targetHasFocus && this.focusNext !== 'target') {
                this.electronWindow.hide();
            }
        });
        this.electronWindow.on('focus', () => {
            this.focusNext = undefined;
        });
        this.attachOptions = options;
        if (isMac) {
            this.calculateMacTitleBarHeight();
        }
        lib.start(this.electronWindow.getNativeWindowHandle(), targetWindowTitle, this.handler.bind(this));
    }
}
exports.OverlayController = new OverlayControllerGlobal();
//# sourceMappingURL=index.js.map