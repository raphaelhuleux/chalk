import { afterEach, describe, expect, it, vi } from 'vitest';
import { createRequestChannel, REPLY_FIELDS } from '../src/host-request';

/**
 * The transport-internal request/reply channel both hosts run. The id
 * bookkeeping is the whole point: a reply that arrives late (or for a page
 * generation that is gone) must never settle a live request.
 */

afterEach(() => {
  vi.useRealTimers();
});

function posted(): { calls: Record<string, unknown>[]; post: (m: Record<string, unknown>) => void } {
  const calls: Record<string, unknown>[] = [];
  return { calls, post: (m) => calls.push(m) };
}

describe('createRequestChannel', () => {
  it('posts the message with an id and resolves when that id is settled', async () => {
    const { calls, post } = posted();
    const channel = createRequestChannel(post);

    const pending = channel.request<string | null>({ type: 'resolve-asset', src: 'a.png' }, null);
    expect(calls).toHaveLength(1);
    expect(calls[0].type).toBe('resolve-asset');
    expect(calls[0].src).toBe('a.png');
    const id = calls[0].id as number;
    expect(typeof id).toBe('number');

    channel.settle(id, 'file:///a.png');
    await expect(pending).resolves.toBe('file:///a.png');
  });

  it('falls back when the host never answers', async () => {
    vi.useFakeTimers();
    const { post } = posted();
    const channel = createRequestChannel(post, { timeoutMs: 10_000 });

    const pending = channel.request<string[]>({ type: 'list-files' }, []);
    vi.advanceTimersByTime(9_999);
    vi.advanceTimersByTime(1);
    await expect(pending).resolves.toEqual([]);
  });

  it('ignores a settle for an unknown id and leaves the real request pending', async () => {
    vi.useFakeTimers();
    const { calls, post } = posted();
    const channel = createRequestChannel(post);

    const pending = channel.request<string | null>({ type: 'read-text', path: 'refs.bib' }, null);
    const id = calls[0].id as number;

    // A reply from a previous page generation, and a reply for an id that was
    // already settled: neither may touch the live request.
    expect(() => channel.settle(id - 1, 'stale')).not.toThrow();
    expect(() => channel.settle(id + 1, 'never-requested')).not.toThrow();

    channel.settle(id, 'real');
    await expect(pending).resolves.toBe('real');
    expect(() => channel.settle(id, 'again')).not.toThrow();
  });

  it('hands out ids no other channel in the same tick reuses', () => {
    const a = posted();
    const b = posted();
    const channelA = createRequestChannel(a.post);
    const channelB = createRequestChannel(b.post);

    for (let i = 0; i < 5; i++) {
      void channelA.request({ type: 'resolve-asset', src: `a${i}` }, null);
      void channelB.request({ type: 'resolve-asset', src: `b${i}` }, null);
    }
    const ids = [...a.calls, ...b.calls].map((m) => m.id as number);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it('seeds from the boot timestamp so a reloaded page never reuses ids', () => {
    const { calls, post } = posted();
    const channel = createRequestChannel(post);
    void channel.request({ type: 'resolve-asset', src: 'x' }, null);
    // Date.now() * 1000 leaves a gap between page generations no realistic
    // request burst can cross, and stays well under 2^53.
    expect(calls[0].id as number).toBeGreaterThan(Date.now() * 999);
    expect(calls[0].id as number).toBeLessThan(Number.MAX_SAFE_INTEGER);
  });

  it('recognises exactly the transport-internal reply types', () => {
    const channel = createRequestChannel(posted().post);
    for (const type of Object.keys(REPLY_FIELDS)) {
      expect(channel.isReply(type)).toBe(true);
    }
    expect(channel.isReply('init')).toBe(false);
    expect(channel.isReply('theme-colors')).toBe(false);
    expect(channel.isReply('toString')).toBe(false);
  });
});
