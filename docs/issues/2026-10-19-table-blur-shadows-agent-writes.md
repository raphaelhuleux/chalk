# A table blur overwrites an AI agent's writes

Status: **fixed, 2026-10-19.**

## Symptom

An agent (Claude Code) edits a `.md` file that is open in Chalk. Chalk keeps showing the old text, and the next time its window loses focus it saves that old text over the agent's edit and shows "Changed Outside This Window". The agent's version survives only as `<name>.conflict.md`.
The user never typed in Chalk.

## Evidence

Two incidents, both in files with GFM tables:

- `notes/anki-prehistoire.md`, 2026-10-14: Chalk's save re-padded the first table (`| ---------------------- |`) where the agent had written `|---|---|`.
- `pareto-tail-proof.md`, 2026-10-19: the agent's Claude Code transcript shows its Edit at 14:47:36Z, then a read at 14:48:07Z finding the old text. The conflict copy's mtime is the agent's write time (`copyItem` keeps it), not Chalk's save.

## Cause

`TableWidget.flush` compared the padded serialization of the cells against the raw source.
A compact table never matches, so any focus-out of a cell rewrote the table with no edit.
A window switch blurs the webview after `windowDidResignKey`'s save has already run, so the buffer turned dirty in the background.
`reloadIfChangedExternally` then skipped every external write ("keeping local copy"), and the next resign-key save overwrote it.

## Fix

- `TableWidget.flush` returns when the cells still serialize to the widget's own model (`table-flush-detach.test.ts` (e), (f)).
- An external write that lands on a dirty buffer is now merged line by line (`TextMerge.threeWay`), so a real unsaved edit elsewhere in the file no longer shadows it. Changes on the same or neighbouring lines still keep the local copy and fall through to the save-time conflict copy.
- A reload check that arrives mid-save now reruns after the save instead of being dropped.
