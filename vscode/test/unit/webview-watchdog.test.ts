import { describe, it, expect } from 'vitest';
import {
  WebviewWatchdog,
  STALE_MS,
  CHECK_MS,
  MAX_RELOADS,
} from '../../src/extension/webview-watchdog';

function harness(opts: { visible?: boolean } = {}) {
  const state = {
    visible: opts.visible ?? true,
    now: 0,
    reloads: 0,
    giveUps: 0,
    logs: [] as string[],
  };
  const dog = new WebviewWatchdog({
    isVisible: () => state.visible,
    reload: () => state.reloads++,
    log: (m) => state.logs.push(m),
    now: () => state.now,
    onGiveUp: () => state.giveUps++,
  });
  return { state, dog };
}

describe('WebviewWatchdog', () => {
  it('does nothing while heartbeats keep arriving', () => {
    const { state, dog } = harness();
    for (let t = 0; t < 60_000; t += 2000) {
      state.now = t;
      dog.markAlive();
      dog.check();
    }
    expect(state.reloads).toBe(0);
  });

  it('reloads a visible webview once silence passes the threshold', () => {
    const { state, dog } = harness();
    state.now = STALE_MS + 1;
    dog.check();
    expect(state.reloads).toBe(1);
    expect(state.logs.some((l) => l.includes('reloading'))).toBe(true);
  });

  it('does not reload again until a fresh stale period elapses', () => {
    const { state, dog } = harness();
    state.now = STALE_MS + 1;
    dog.check();
    state.now += 1000; // well within the post-reload grace period
    dog.check();
    expect(state.reloads).toBe(1);
    state.now += STALE_MS; // the reloaded page never spoke either
    dog.check();
    expect(state.reloads).toBe(2);
  });

  it('stops after MAX_RELOADS consecutive dead reloads', () => {
    const { state, dog } = harness();
    for (let i = 0; i < MAX_RELOADS + 5; i++) {
      state.now += STALE_MS + 1;
      dog.check();
    }
    expect(state.reloads).toBe(MAX_RELOADS);
  });

  it('a successful recovery resets the reload budget', () => {
    const { state, dog } = harness();
    state.now = STALE_MS + 1;
    dog.check();
    expect(state.reloads).toBe(1);
    dog.markAlive(); // reloaded page came up and heartbeated
    for (let i = 0; i < MAX_RELOADS; i++) {
      state.now += STALE_MS + 1;
      dog.check();
    }
    expect(state.reloads).toBe(1 + MAX_RELOADS);
  });

  it('treats hidden silence as alive (VS Code throttles hidden webviews)', () => {
    const { state, dog } = harness({ visible: false });
    state.now = 10 * STALE_MS;
    dog.check();
    expect(state.reloads).toBe(0);
    // Becoming visible starts a fresh grace period, not an instant reload.
    state.visible = true;
    dog.markVisibilityChange();
    state.now += STALE_MS - 1;
    dog.check();
    expect(state.reloads).toBe(0);
    state.now += 2;
    dog.check();
    expect(state.reloads).toBe(1);
  });

  it('does not reset the budget without markAlive (checks alone never reset)', () => {
    const { state, dog } = harness();
    // Two dead reloads, then plenty of quiet checks — the budget must stay
    // spent; only markAlive (a real message from the page) may reset it.
    state.now += STALE_MS + 1;
    dog.check();
    state.now += STALE_MS + 1;
    dog.check();
    expect(state.reloads).toBe(2);
    for (let i = 0; i < 10; i++) {
      state.now += CHECK_MS;
      dog.check();
    }
    state.now += STALE_MS + 1;
    dog.check();
    expect(state.reloads).toBe(MAX_RELOADS); // spent the last one, no reset happened
    state.now += STALE_MS + 1;
    dog.check();
    expect(state.reloads).toBe(MAX_RELOADS);
  });

  it('boot-crash bundle (never markAlive) exhausts the budget in MAX_RELOADS', () => {
    // Simulates a deterministically boot-crashing bundle: each reload posts
    // only client-error, which the provider does NOT count as liveness, so
    // markAlive is never called between reloads.
    const { state, dog } = harness();
    for (let i = 0; i < MAX_RELOADS * 3; i++) {
      state.now += STALE_MS + 1;
      dog.check();
    }
    expect(state.reloads).toBe(MAX_RELOADS);
  });

  it('grants wake-gap grace: a suspended check timer does not trigger a reload', () => {
    const { state, dog } = harness();
    // Regular healthy cadence first.
    state.now = CHECK_MS;
    dog.markAlive();
    dog.check();
    // Machine sleeps: next check fires hours later. lastAlive is far past
    // STALE_MS but the gap between checks proves the timer was suspended.
    state.now += 3 * 60 * 60 * 1000;
    dog.check();
    expect(state.reloads).toBe(0);
    // lastAlive was refreshed: still within grace just under STALE_MS later…
    state.now += STALE_MS - 1;
    dog.check();
    expect(state.reloads).toBe(0);
    // …but genuine post-wake silence past STALE_MS does reload.
    state.now += STALE_MS + 1;
    dog.check();
    expect(state.reloads).toBe(1);
  });

  it('fires onGiveUp exactly once when the budget is exhausted', () => {
    const { state, dog } = harness();
    for (let i = 0; i < MAX_RELOADS; i++) {
      state.now += STALE_MS + 1;
      dog.check();
    }
    expect(state.reloads).toBe(MAX_RELOADS);
    expect(state.giveUps).toBe(0); // not yet: fires when a reload is next warranted
    state.now += STALE_MS + 1;
    dog.check();
    expect(state.giveUps).toBe(1);
    state.now += STALE_MS + 1;
    dog.check();
    state.now += STALE_MS + 1;
    dog.check();
    expect(state.giveUps).toBe(1); // exactly once
    expect(state.reloads).toBe(MAX_RELOADS);
  });

  it('reset() re-arms the budget and give-up notification', () => {
    const { state, dog } = harness();
    for (let i = 0; i < MAX_RELOADS + 1; i++) {
      state.now += STALE_MS + 1;
      dog.check();
    }
    expect(state.reloads).toBe(MAX_RELOADS);
    expect(state.giveUps).toBe(1);
    dog.reset();
    // Fresh grace period after reset: no instant reload.
    state.now += 1000;
    dog.check();
    expect(state.reloads).toBe(MAX_RELOADS);
    // Budget is fresh: reloads resume, and give-up can fire again later.
    for (let i = 0; i < MAX_RELOADS + 1; i++) {
      state.now += STALE_MS + 1;
      dog.check();
    }
    expect(state.reloads).toBe(2 * MAX_RELOADS);
    expect(state.giveUps).toBe(2);
  });
});
