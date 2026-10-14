import { describe, it, expect, vi } from 'vitest';
import { memoizedAssetResolver } from '../src/utils/asset-cache';

const url = (s: string) => `data:image/png;base64,${s}`;

describe('memoizedAssetResolver', () => {
  it('resolves through the wrapped resolver', async () => {
    const memo = memoizedAssetResolver(async (src) => url(src));
    await expect(memo('a.png')).resolves.toBe(url('a.png'));
  });

  it('serves a repeat request from the cache without re-invoking', async () => {
    const inner = vi.fn(async (src: string) => url(src));
    const memo = memoizedAssetResolver(inner);
    await memo('a.png');
    await memo('a.png');
    expect(inner).toHaveBeenCalledTimes(1);
  });

  it('shares one in-flight promise between concurrent requests', async () => {
    let resolveInner!: (v: string | null) => void;
    const inner = vi.fn(() => new Promise<string | null>((r) => (resolveInner = r)));
    const memo = memoizedAssetResolver(inner);
    const p1 = memo('a.png');
    const p2 = memo('a.png');
    resolveInner(url('a'));
    await expect(p1).resolves.toBe(url('a'));
    await expect(p2).resolves.toBe(url('a'));
    expect(inner).toHaveBeenCalledTimes(1);
  });

  it('does not retain null results, so a missing file can appear later', async () => {
    let found = false;
    const inner = vi.fn(async () => (found ? url('late') : null));
    const memo = memoizedAssetResolver(inner);
    await expect(memo('a.png')).resolves.toBeNull();
    found = true;
    await expect(memo('a.png')).resolves.toBe(url('late'));
    expect(inner).toHaveBeenCalledTimes(2);
  });

  it('does not let a rejection poison the cache, and settles null', async () => {
    let fail = true;
    const inner = vi.fn(async () => {
      if (fail) throw new Error('io');
      return url('ok');
    });
    const memo = memoizedAssetResolver(inner);
    await expect(memo('a.png')).resolves.toBeNull();
    fail = false;
    await expect(memo('a.png')).resolves.toBe(url('ok'));
  });

  it('a stale null does not evict a newer entry for the same src', async () => {
    let settleFirst!: (v: string | null) => void;
    let calls = 0;
    const inner = vi.fn((src: string) => {
      calls++;
      if (src === 'a.png' && calls === 1) return new Promise<string | null>((r) => (settleFirst = r));
      return Promise.resolve(url(src));
    });
    const memo = memoizedAssetResolver(inner, 1);
    const first = memo('a.png'); // pending
    await memo('b.png'); // evicts the pending a
    await expect(memo('a.png')).resolves.toBe(url('a.png')); // a newer entry for a
    settleFirst(null);
    await expect(first).resolves.toBeNull();
    await expect(memo('a.png')).resolves.toBe(url('a.png'));
    expect(inner).toHaveBeenCalledTimes(3);
  });

  it('evicts the least recently used entry at capacity', async () => {
    const inner = vi.fn(async (src: string) => url(src));
    const memo = memoizedAssetResolver(inner, 2);
    await memo('a.png'); // {a}
    await memo('b.png'); // {a, b}
    await memo('a.png'); // touch a → b is LRU
    await memo('c.png'); // evicts b → {a, c}
    inner.mockClear();
    await memo('a.png');
    expect(inner).not.toHaveBeenCalled();
    await memo('b.png');
    expect(inner).toHaveBeenCalledWith('b.png');
  });
});
