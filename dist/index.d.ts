/// <reference types="node" />
import { EventEmitter } from 'events';
import type { BrowserWindow, BrowserWindowConstructorOptions } from 'electron';
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
    readonly WINDOW_OPTS: BrowserWindowConstructorOptions;
    constructor();
    private handleFullscreen;
    private updateOverlayBounds;
    private handler;
    activateOverlay(): void;
    focusTarget(): void;
    attachTo(overlayWindow: BrowserWindow, targetWindowTitle: string): void;
}
export declare const overlayWindow: OverlayWindow;
export {};
