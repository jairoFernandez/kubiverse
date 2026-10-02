package sample

import "testing"

// Fine: a direct failing call.
func TestDirect(t *testing.T) {
	if 1+1 != 2 {
		t.Fatalf("math")
	}
}

// Fine: a helper that fails.
func TestHelper(t *testing.T) { mustEqual(t, 1, 1) }

func mustEqual(t *testing.T, a, b int) {
	t.Helper()
	if a != b {
		t.Errorf("%d != %d", a, b)
	}
}

// Fine: subtests that check.
func TestSubtests(t *testing.T) {
	for _, c := range []int{1, 2} {
		t.Run("c", func(t *testing.T) {
			if c == 0 {
				t.Error("zero")
			}
		})
	}
}

// Fine: a fuzz target that fails.
func FuzzThing(f *testing.F) {
	f.Add(1)
	f.Fuzz(func(t *testing.T, n int) {
		if n < 0 && -n < 0 {
			t.Fail()
		}
	})
}

// Fine: t handed to something we can't see (another package).
func TestOpaque(t *testing.T) { external(t) }

var external = func(t *testing.T) { t.Log("x") }

// BAD: computes, logs, never fails.
func TestNoAssert(t *testing.T) {
	x := 1 + 1
	t.Logf("x=%d", x)
}

// BAD: subtests that only log.
func TestEmptySubtests(t *testing.T) {
	t.Run("a", func(t *testing.T) { t.Log("ran") })
}

// BAD: a helper that only logs is not an assertion.
func TestLoggingHelper(t *testing.T) { logOnly(t, 3) }

func logOnly(t *testing.T, n int) { t.Logf("%d", n) }

// BAD: Skip is not a check.
func TestSkipOnly(t *testing.T) { t.Skip("later") }

// BAD: building a fixture is not checking anything.
func TestOnlySetup(t *testing.T) {
	x := newFixture(t)
	_ = x
}

func newFixture(t *testing.T) int {
	if t == nil {
		t.Fatal("no t")
	}
	return 1
}

// Not tests: wrong name or signature.
func Testable(t *testing.T) {}
func TestHelperLike(x int)  {}
