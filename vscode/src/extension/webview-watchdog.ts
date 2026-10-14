/**
 * Liveness watchdog for the Chalk webview. A webview can die (renderer crash,
 * service worker stops serving) with no event reaching the extension. The
 * page heartbeats every HEARTBEAT_MS; a *visible* editor silent past
 * STALE_MS gets its HTML reloaded. Hidden webviews are throttled, so hidden
 * silence is not death.
 *
 * The webview bundle imports HEARTBEAT_MS from here: keep this module free of
 * imports (`vscode` above all).
 */

export const HEARTBEAT_MS = 2000;
export const STALE_MS = 8000;
export const CHECK_MS = 3000;
export const MAX_RELOADS = 3;

export interface WatchdogHooks {
  isVisible(): boolean;
  /** Rebuild the webview HTML (fresh nonce) — reboots the page. */
  reload(): void;
  log(message: string): void;
  now(): number;
  /**
   * Fired once when a reload is due but MAX_RELOADS is exhausted; the
   * provider offers a manual reload (which calls reset()).
   */
  onGiveUp?: () => void;
}

export class WebviewWatchdog {
  private lastAlive: number;
  private lastCheck: number;
  private reloads = 0;
  private gaveUp = false;

  constructor(private readonly hooks: WatchdogHooks) {
    this.lastAlive = hooks.now();
    this.lastCheck = hooks.now();
  }

  /** Any message from the webview proves the page is alive. */
  markAlive(): void {
    this.lastAlive = this.hooks.now();
    this.reloads = 0;
  }

  /** Fresh grace period on show/hide: a just-unhidden webview may not have
   *  heartbeated for minutes. */
  markVisibilityChange(): void {
    this.lastAlive = this.hooks.now();
  }

  /** Re-arm after a give-up: fresh reload budget and grace period. */
  reset(): void {
    this.reloads = 0;
    this.gaveUp = false;
    this.lastAlive = this.hooks.now();
    this.lastCheck = this.hooks.now();
  }

  /** Called every CHECK_MS by the provider's timer. */
  check(): void {
    // Wake from suspend: `visible` stays true while minimized or asleep, but
    // heartbeats and this timer pause. A large gap between our own checks
    // means the timer was suspended, so the silence proves nothing.
    const now = this.hooks.now();
    const gap = now - this.lastCheck;
    this.lastCheck = now;
    if (gap > CHECK_MS * 3) {
      this.lastAlive = now;
      return;
    }

    if (!this.hooks.isVisible()) {
      this.lastAlive = now;
      return;
    }
    if (now - this.lastAlive < STALE_MS) return;
    if (this.reloads >= MAX_RELOADS) {
      if (!this.gaveUp) {
        this.gaveUp = true;
        this.hooks.log(
          `webview still silent after ${MAX_RELOADS} reloads — giving up.`,
        );
        this.hooks.onGiveUp?.();
      }
      return;
    }
    this.reloads++;
    this.hooks.log(
      `webview silent for ${STALE_MS}ms while visible — reloading (attempt ${this.reloads}/${MAX_RELOADS})`,
    );
    this.lastAlive = now;
    this.hooks.reload();
  }
}
