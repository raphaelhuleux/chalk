/**
 * Id bookkeeping for the transport-internal request/reply channel both hosts
 * run to fulfil promise hooks (`resolveAsset`, `WorkspaceAccess`). Not part of
 * the frozen `HostPort` protocol. Pure TS: no `window`, no DOM.
 */
import type { AssetResolver } from './editor/asset-resolver';
import type { WorkspaceAccess } from './editor/workspace-files';

/** Reply message type to the field carrying its value. Hosts whose replies
 *  arrive as messages (VS Code) use it to keep them out of the `HostPort` stream. */
export const REPLY_FIELDS: Readonly<Record<string, string>> = {
  'resolve-asset-reply': 'url',
  'list-files-reply': 'paths',
  'read-text-reply': 'text',
};

// Settle with the fallback if the host never answers, so the promise and Map
// entry don't leak.
const DEFAULT_TIMEOUT_MS = 10_000;

// Ids must be unique across page reloads: a late reply from the previous page
// lands in the current one. Seeding from boot time x1000 keeps each page's range
// disjoint (well under 2^53 and Int64). Module-scoped so channels share it.
let sharedNextId = Date.now() * 1000;

export interface RequestChannel {
  /** Post `message` with a fresh id; resolve when the host settles that id, or
   *  with `fallback` if it never does. */
  request<T>(message: Record<string, unknown>, fallback: T): Promise<T>;
  /** Settle pending request `id`; unknown ids (stale or double replies) are
   *  ignored. */
  settle<T>(id: number, value: T): void;
  isReply(type: string): boolean;
}

export function createRequestChannel(
  post: (message: Record<string, unknown>) => void,
  opts: { timeoutMs?: number } = {},
): RequestChannel {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  interface Pending {
    settle: (value: never) => void;
    timer: ReturnType<typeof setTimeout>;
  }
  const pending = new Map<number, Pending>();

  return {
    request<T>(message: Record<string, unknown>, fallback: T): Promise<T> {
      return new Promise<T>((resolve) => {
        const id = sharedNextId++;
        const timer = setTimeout(() => {
          pending.delete(id);
          resolve(fallback);
        }, timeoutMs);
        pending.set(id, {
          settle: resolve as unknown as (value: never) => void,
          timer,
        });
        post({ ...message, id });
      });
    },

    settle<T>(id: number, value: T): void {
      const entry = pending.get(id);
      if (!entry) return;
      clearTimeout(entry.timer);
      pending.delete(id);
      (entry.settle as unknown as (v: T) => void)(value);
    },

    isReply(type: string): boolean {
      // Not `in`: it walks the prototype chain ("toString" would match).
      return Object.prototype.hasOwnProperty.call(REPLY_FIELDS, type);
    },
  };
}

/** The `mountEditor` promise hooks over `channel`: each posts its request type
 *  and settles on the matching entry of `REPLY_FIELDS`. The host fulfils them
 *  (resolving an image path, walking the document directory). */
export function requestHooks(channel: RequestChannel): {
  resolveAsset: AssetResolver;
  workspaceAccess: WorkspaceAccess;
} {
  return {
    resolveAsset: (src) => channel.request<string | null>({ type: 'resolve-asset', src }, null),
    workspaceAccess: {
      list: (kinds) => channel.request<string[]>({ type: 'list-files', kinds: [...kinds] }, []),
      readText: (path) => channel.request<string | null>({ type: 'read-text', path }, null),
    },
  };
}
