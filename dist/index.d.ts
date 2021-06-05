/// <reference types="node" />
import { EventEmitter } from 'events';
import { BrowserWindow, BrowserWindowConstructorOptions } from 'electron';
export interface AttachEvent {
    hasAccess: boolean | undefined;
    isFullscreen: boolean | undefined;
    x: number;
    y: number;
    width: number;
    height: number;
}
export interface FullscreenEvent {
    isFullscreen: boolean;
}
export interface MoveresizeEvent {
    x: number;
    y: number;
    width: number;
    height: number;
}
export interface AttachToOptions {
    /**
     * Whether the Window has a title bar. We adjust the overlay to not cover
     * it
     */
    hasTitleBarOnMac?: boolean;
}
declare interface OverlayWindow {
    on(event: 'attach', listener: (e: AttachEvent) => void): this;
    on(event: 'focus', listener: () => void): this;
    on(event: 'blur', listener: () => void): this;
    on(event: 'detach', listener: () => void): this;
    on(event: 'fullscreen', listener: (e: FullscreenEvent) => void): this;
    on(event: 'moveresize', listener: (e: MoveresizeEvent) => void): this;
}
declare class OverlayWindow extends EventEmitter {
    private _overlayWindow;
    defaultBehavior: boolean;
    private lastBounds;
    /** The height of a title bar on a standard window. Only measured on Mac */
    private macTitleBarHeight;
    private attachToOptions;
    readonly WINDOW_OPTS: BrowserWindowConstructorOptions;
    constructor();
    private handleFullscreen;
    private updateOverlayBounds;
    private handler;
    /**
     * Create a dummy window to calculate the title bar height on Mac. We use
     * the title bar height to adjust the size of the overlay to not overlap
     * the title bar. This helps Mac match the behaviour on Windows/Linux.
     */
    private calculateMacTitleBarHeight;
    /** If we're on a Mac, adjust the bounds to not overlap the title bar */
    private adjustBoundsForMacTitleBar;
    activateOverlay(): void;
    focusTarget(): void;
    attachTo(overlayWindow: BrowserWindow, targetWindowTitle: string, options?: AttachToOptions): void;
}
export declare const overlayWindow: OverlayWindow;
export {};
