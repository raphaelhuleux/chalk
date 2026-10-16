import { describe, expect, it } from 'vitest';
import { BuildQueue } from '../../src/extension/latex/build-queue';

/** A build that finishes only when the test says so. */
function controlledBuilds() {
  const started: string[] = [];
  const finishers: (() => void)[] = [];
  const queue = new BuildQueue(
    (root) =>
      new Promise<void>((resolve) => {
        started.push(root);
        finishers.push(resolve);
      }),
  );
  const finishNext = async (): Promise<void> => {
    finishers.shift()?.();
    // Let the loop observe the finish and start a rerun.
    await new Promise((r) => setTimeout(r, 0));
  };
  return { queue, started, finishNext };
}

describe('BuildQueue', () => {
  it('folds saves during a build into exactly one rerun', async () => {
    const { queue, started, finishNext } = controlledBuilds();
    expect(queue.request('/ws/main.tex')).toBe('started');
    expect(queue.request('/ws/main.tex')).toBe('queued');
    expect(queue.request('/ws/main.tex')).toBe('queued');
    expect(started).toEqual(['/ws/main.tex']);
    await finishNext();
    expect(started).toEqual(['/ws/main.tex', '/ws/main.tex']);
    await finishNext();
    expect(started).toHaveLength(2);
    expect(queue.isBuilding('/ws/main.tex')).toBe(false);
  });

  it('builds different roots independently', () => {
    const { queue, started } = controlledBuilds();
    queue.request('/ws/main.tex');
    expect(queue.request('/ws/slides.tex')).toBe('started');
    expect(started).toEqual(['/ws/main.tex', '/ws/slides.tex']);
  });

  it('keeps going after a build throws', async () => {
    let calls = 0;
    const queue = new BuildQueue(async () => {
      calls += 1;
      throw new Error('boom');
    });
    queue.request('/ws/main.tex');
    await queue.idle('/ws/main.tex');
    expect(queue.request('/ws/main.tex')).toBe('started');
    await queue.idle('/ws/main.tex');
    expect(calls).toBe(2);
  });
});
