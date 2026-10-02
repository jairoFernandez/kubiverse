package main

import (
	"reflect"
	"sort"
	"testing"
)

func TestFindsTestsThatCannotFail(t *testing.T) {
	got, total, err := lintDir("testdata/sample")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, f := range got {
		names = append(names, f.name)
	}
	sort.Strings(names)
	want := []string{"TestEmptySubtests", "TestLoggingHelper", "TestNoAssert", "TestOnlySetup", "TestSkipOnly"}
	if !reflect.DeepEqual(names, want) {
		t.Errorf("flagged %v, want %v", names, want)
	}
	// TestDirect, TestHelper, TestSubtests, FuzzThing, TestOpaque + the 5 bad ones.
	if total != 10 {
		t.Errorf("saw %d tests, want 10 (Testable and TestHelperLike are not tests)", total)
	}
}
