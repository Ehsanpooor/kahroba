# STALE — do not read the card data in this directory

This folder is a hand-copied mirror of `runtime/rules.go` and `runtime/cards.go`
from before 5 September 2026. It is now wrong in two ways that matter:

1. **`cards.go` here holds the old card table**, including the 49 costs that
   exist nowhere in the Splendor deck. Anyone porting card numbers from this
   copy will reintroduce the bug that was just fixed.
2. **`rules.go` here predates the rules fixes** — the final-round end condition,
   standings that exclude conceded players, and the harvest-fewer-than-three
   rule are all missing.

It also no longer serves its original purpose. It existed so the pure rules could
be unit tested without the Nakama dependency, but `runtime/` now tests cleanly on
its own (`cd runtime && go test ./...`, 83 tests), and `rules.go` there still has
no Nakama imports.

**Recommended: delete this directory.** It was left in place only because it is
not mine to remove. Nothing in the build, the tests or the Docker image
references it.

The source of truth for cards is `runtime/cards.go`, guarded by
`runtime/deck_test.go`.
