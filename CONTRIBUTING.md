# Contributing to Chalk

Thanks for helping. This file covers the basics; [CLAUDE.md](CLAUDE.md) has the architecture and the guardrails.

## Prerequisites

- macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), for the Mac app
- Node.js and [pnpm](https://pnpm.io)
- Playwright's browsers for the browser tests: `npx playwright install chromium webkit`

Then:

```bash
pnpm install
cd mac && xcodegen generate
```

If you only work on the engine or the VS Code extension, you do not need Xcode.

## Running the checks

- `scripts/check.sh` runs everything and prints each failure in a fixed `FAILURE <n>` format. `--list` names the steps.
- `scripts/check.sh --fast` skips the Xcode test suites and the benchmarks. Use it while you iterate.
- For engine work, `pnpm test`, `pnpm typecheck`, `pnpm test:browser` and `pnpm test:caret` are the quick loop.
- For Swift work, `pnpm test:swift` runs the ChalkKit tests without Xcode's test runner.

Check [docs/known-failing-tests.md](docs/known-failing-tests.md) before you chase a red suite.

## Rules worth knowing first

- The `HostPort` protocol is frozen. If it ever has to grow, the engine, both hosts and the Swift mirror types change in the same pull request.
- `packages/editor-core` stays host-agnostic: no UIKit, VS Code or other host assumptions. Read [packages/editor-core/CLAUDE.md](packages/editor-core/CLAUDE.md) before touching editor code.
- Chrome geometry in the Mac app is asserted by tests. Read [docs/ui-correctness.md](docs/ui-correctness.md) before changing the tab band, the Library panel, the tab strip or the editor's resting offset.
- Comments follow the rules in the "Comments" section of [CLAUDE.md](CLAUDE.md): keep the why, no history, no restating the code.

## Pull requests

- Keep each pull request to one change, and say in the description what it fixes or adds and how you tested it.
- Run `scripts/check.sh` (or at least `--fast`, plus the Xcode suites if you touched `mac/`) and say what you ran.
- Add or update tests with the change. Do not delete or loosen an assertion to make a suite pass; if a failure is accepted, record it in `docs/known-failing-tests.md` or the runner's `KNOWN_FAILURES` file with a reason.
- A visual change that moves a snapshot in `Tests/__Snapshots__` needs a re-recorded baseline (`node Tests/runner/snapshots.mjs --record`) and a sentence explaining why it changed.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
