/**
 * One build at a time per root, and no save lost: a request while that root
 * builds marks it dirty, and the running loop builds once more when it ends,
 * however many saves arrived meanwhile. Pure, so it tests without vscode.
 */
export class BuildQueue {
  private readonly running = new Set<string>();
  private readonly dirty = new Set<string>();

  constructor(private readonly build: (root: string) => Promise<void>) {}

  /** `started` launches a build; `queued` folds into the running one's rerun. */
  request(root: string): 'started' | 'queued' {
    if (this.running.has(root)) {
      this.dirty.add(root);
      return 'queued';
    }
    void this.loop(root);
    return 'started';
  }

  isBuilding(root: string): boolean {
    return this.running.has(root);
  }

  /** Resolves when `root` has no build running or pending. */
  async idle(root: string): Promise<void> {
    while (this.running.has(root)) {
      await new Promise((r) => setTimeout(r, 10));
    }
  }

  private async loop(root: string): Promise<void> {
    this.running.add(root);
    try {
      do {
        this.dirty.delete(root);
        try {
          await this.build(root);
        } catch {
          // The builder logs its own failures; a throw must not wedge the root.
        }
      } while (this.dirty.has(root));
    } finally {
      this.running.delete(root);
    }
  }
}
