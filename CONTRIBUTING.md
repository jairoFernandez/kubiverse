# Contributing

`make test` runs everything that CI blocks on locally (Go bridge + headless
Godot game tests). A few rules keep those tests honest.

## Tests only get stronger

New code must not be made to pass by editing the tests that check it. CI's
`test-guard` job (`scripts/test-guard.sh`) fails when a change **weakens**
existing tests:

- a line removed or changed in an existing test (`bridge/**/*_test.go`,
  `game/tests/*.gd`); blank lines, comments and whitespace don't count
- a test function deleted or renamed
- fewer assertions in total (`t.Error*`, `t.Fatal*`, `t.Fail*`, check helpers
  called with `t`; GDScript `check(` and `fails +=`)
- a `t.Skip` added
- a baseline loosened: a key added to `game/tests/i18n_missing_baseline.txt`,
  `bridge/coverage-baseline.txt` or `game/tests/checks-baseline.txt` lowered
- lines removed from the guards themselves (`scripts/test-guard.sh`,
  `scripts/coverage.sh`, `scripts/game-tests.sh`, the hooks,
  `tools/testlint`, `.claude/settings.json`)

New tests, new assertions and new test files always pass.

### When a test really is wrong

Fix it in its **own commit** and say why in a trailer (last paragraph of the
commit message):

```
Fix the drain test's expected order

Test-Change: the test expected pods sorted by age, but the API promises
name order; the old expectation was the bug.
```

One `Test-Change:` trailer anywhere in the pushed range / PR is enough for
the guard. A behavior change on purpose is a valid reason too; "make CI
green" is not.

### Locally

```
make test-guard    # this branch vs main
make hooks         # opt-in: the same check on every commit and push
                   # (git config core.hooksPath scripts/hooks; undo with
                   #  git config --unset core.hooksPath)
```

## Other guards

- **Coverage ratchet**: `make coverage-check` fails when the bridge's total
  coverage drops more than 0.2 points below `bridge/coverage-baseline.txt`;
  `make coverage-bump` raises the baseline after you add tests (it never
  lowers it). The game's `game/tests/checks-baseline.txt` is the number of
  `check(` calls in `game/tests`: it may only go up.
- **Assertion-free tests**: `make lint-go` runs `tools/testlint`: every
  `TestXxx` / `FuzzXxx` must be able to fail (a `t.Error*`/`t.Fatal*`/
  `t.Fail*`, a helper that receives `t`, or `t.Run` subtests that do).
  Each `game/tests/test_*.gd` must extend the harness, call `check(` at
  least 5 times, call `finish(`, and be listed in `make test-game` (which
  also requires its `<label>: OK` line).
- **Invariants**: snapshot tests call `assertSnapshotInvariants`; `FuzzDelta`
  replays random snapshot sequences through the patches the game applies;
  `game/tests/test_invariants.gd` walks every demo scenario and level.
- **Mutation testing** (weekly, `.github/workflows/mutation.yml`) shows which
  code changes no test notices.

New behavior needs new tests.

## Claude Code / AI agents

See `CLAUDE.md`. The repo's `.claude/settings.json` hooks ask before any edit
to an existing test or baseline file and run the test guard when a session
stops.
