# Kubiverse: notes for AI agents

Godot 4.7 game in `game/`, Go bridge in `bridge/`, CI in
`.github/workflows/build.yml`. `make test` runs the bridge tests and the
headless game tests; `make lint-go`, `make test-race`, `make test-game`
are what CI blocks on. See `CONTRIBUTING.md`.

## Tests are the spec: never weaken them to make a change pass

- Never delete, skip, loosen or rewrite an existing test, assertion or
  baseline (`game/tests/i18n_missing_baseline.txt`,
  `game/tests/checks-baseline.txt`, `bridge/coverage-baseline.txt`) so that
  new code passes. If a test fails, the code is wrong until proven otherwise:
  fix the code.
- If a test is genuinely wrong (it asserts a bug, or the behavior changes on
  purpose and the user asked for it), fix it in a **separate commit** whose
  message ends with a trailer explaining why:
  `Test-Change: <why the old expectation was wrong>`. Say so to the user.
- New behavior needs new tests. Prefer adding new test lines/functions over
  editing existing ones (pure additions always pass the guard).
- Don't touch the guards themselves (`scripts/test-guard.sh`,
  `scripts/coverage.sh`, `scripts/game-tests.sh`, `scripts/hooks/`,
  `scripts/claude-hooks/`, `tools/testlint/`, `.claude/settings.json`) to get
  around them.
- After adding tests, `make coverage-bump` raises the ratchets; never lower a
  baseline without a `Test-Change:` trailer.
- Bridge snapshot tests call `assertSnapshotInvariants`; game tests use
  `check(...)` (never `assert`, it hangs headless Godot) and end with
  `finish(...)`.

## What enforces this

- CI `test-guard` job: `scripts/test-guard.sh` fails a PR/push that weakens
  existing tests without a `Test-Change:` trailer (`make test-guard` locally).
- `.claude/settings.json` hooks (this repo, every session):
  - before Edit/Write/MultiEdit/NotebookEdit of an existing test, baseline or
    guard file, or a Bash command that rewrites/deletes one, the user is
    asked to approve (`scripts/claude-hooks/protect-tests.sh`); new test
    files don't ask;
  - after a `git commit`, and when a turn stops, the test guard runs and its
    findings come back as feedback (`scripts/claude-hooks/guard-feedback.sh`).

## Other

- Never put real cluster names, IPs or providers in code, tests or commits.
