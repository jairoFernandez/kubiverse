// Command testlint reports Go tests that cannot fail.
//
//	go run ./tools/testlint [dir...]   (default: bridge)
//
// Every func TestXxx(t *testing.T) and FuzzXxx(f *testing.F) must contain,
// anywhere in its body (closures, t.Run subtests and f.Fuzz targets
// included), at least one of:
//   - a failing call on a testing value: Error, Errorf, Fatal, Fatalf, Fail,
//     FailNow;
//   - a call that passes a testing value (t, f, a subtest's t...) to a
//     helper, unless that helper is a function of the same package that
//     itself can never fail (its testing parameter only logs, say) or a
//     fixture builder (newX, setupX, startX, makeX, fakeX, fixtureX: they
//     fail when the fixture can't be built, which checks nothing).
//
// A test without any of these passes whatever the code does: it is a smoke
// run at best and hides behind the test count. Exit status 1 lists them.
// It lives outside the bridge module so it never ends up in its binary.
package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var failing = map[string]bool{"Error": true, "Errorf": true, "Fatal": true, "Fatalf": true, "Fail": true, "FailNow": true}

// testingType: *testing.T, *testing.F, *testing.B or testing.TB.
func testingType(e ast.Expr) bool {
	if s, ok := e.(*ast.StarExpr); ok {
		e = s.X
	}
	sel, ok := e.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkg, ok := sel.X.(*ast.Ident)
	return ok && pkg.Name == "testing" && (sel.Sel.Name == "T" || sel.Sel.Name == "F" || sel.Sel.Name == "B" || sel.Sel.Name == "TB")
}

// params: names of the testing parameters of a function type.
func params(ft *ast.FuncType, into map[string]bool) {
	if ft == nil || ft.Params == nil {
		return
	}
	for _, f := range ft.Params.List {
		if testingType(f.Type) {
			for _, n := range f.Names {
				into[n.Name] = true
			}
		}
	}
}

// pkgFuncs: every top-level function of one package (directory), test files
// and the rest, by name.
type pkgFuncs map[string]*ast.FuncDecl

// verdict of a body: can it fail, and through which helpers it might.
type verdict struct {
	direct  bool     // a failing call on a testing value
	opaque  bool     // a testing value passed to something we can't see
	helpers []string // same-package helpers that received a testing value
}

func inspect(body ast.Node, names map[string]bool, funcs pkgFuncs) verdict {
	var v verdict
	ast.Inspect(body, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.FuncLit:
			params(x.Type, names) // subtests, fuzz targets, local helpers
		case *ast.CallExpr:
			if sel, ok := x.Fun.(*ast.SelectorExpr); ok {
				if id, ok := sel.X.(*ast.Ident); ok && names[id.Name] && failing[sel.Sel.Name] {
					v.direct = true
				}
			}
			passes := false
			for _, a := range x.Args {
				if id, ok := a.(*ast.Ident); ok && names[id.Name] {
					passes = true
				}
			}
			if !passes {
				break
			}
			if id, ok := x.Fun.(*ast.Ident); ok && setup(id.Name) {
				// newTestBridge(t): fails only when the fixture can't be
				// built, it checks nothing about the code under test.
			} else if ok && funcs[id.Name] != nil {
				v.helpers = append(v.helpers, id.Name)
			} else {
				v.opaque = true // a method, a closure variable, another package
			}
		}
		return true
	})
	return v
}

// setup: fixture builders by name (newX, setupX, startX, makeX, fakeX,
// fixtureX): handing them t is not an assertion.
func setup(name string) bool {
	for _, p := range []string{"new", "setup", "start", "make", "fake", "fixture"} {
		if rest, ok := strings.CutPrefix(name, p); ok && (rest == "" || rest[0] >= 'A' && rest[0] <= 'Z') {
			return true
		}
	}
	return false
}

// canFail: a same-package function fails if its body does, directly or
// through the helpers it hands its testing value to.
func canFail(name string, funcs pkgFuncs, memo map[string]int) bool {
	switch memo[name] {
	case 1:
		return true
	case 2, 3: // known not to, or being looked at (recursion)
		return false
	}
	fd := funcs[name]
	if fd == nil || fd.Body == nil {
		return true // can't see it: give it the benefit of the doubt
	}
	memo[name] = 3
	names := map[string]bool{}
	params(fd.Type, names)
	v := inspect(fd.Body, names, funcs)
	ok := v.direct || v.opaque
	for _, h := range v.helpers {
		if ok {
			break
		}
		ok = canFail(h, funcs, memo)
	}
	memo[name] = map[bool]int{true: 1, false: 2}[ok]
	return ok
}

type finding struct {
	pos  token.Position
	name string
}

func lintDir(dir string) ([]finding, int, error) {
	fset := token.NewFileSet()
	files, err := filepath.Glob(filepath.Join(dir, "*.go"))
	if err != nil {
		return nil, 0, err
	}
	funcs := pkgFuncs{}
	var tests []*ast.FuncDecl
	for _, path := range files {
		f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if err != nil {
			return nil, 0, err
		}
		isTest := strings.HasSuffix(path, "_test.go")
		for _, d := range f.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Recv != nil {
				continue
			}
			funcs[fd.Name.Name] = fd
			if isTest && isTestFunc(fd) {
				tests = append(tests, fd)
			}
		}
	}
	memo := map[string]int{}
	var out []finding
	for _, fd := range tests {
		if !canFail(fd.Name.Name, funcs, memo) {
			out = append(out, finding{fset.Position(fd.Pos()), fd.Name.Name})
		}
	}
	return out, len(tests), nil
}

// isTestFunc: TestXxx(t *testing.T) or FuzzXxx(f *testing.F).
func isTestFunc(fd *ast.FuncDecl) bool {
	n := fd.Name.Name
	var prefix string
	switch {
	case strings.HasPrefix(n, "Test"):
		prefix = "Test"
	case strings.HasPrefix(n, "Fuzz"):
		prefix = "Fuzz"
	default:
		return false
	}
	if rest := n[len(prefix):]; rest != "" && rest[0] >= 'a' && rest[0] <= 'z' {
		return false // Testable, Fuzzy: not tests
	}
	p := fd.Type.Params
	return p != nil && len(p.List) == 1 && testingType(p.List[0].Type)
}

func main() {
	dirs := os.Args[1:]
	if len(dirs) == 0 {
		dirs = []string{"bridge"}
	}
	var all []finding
	total := 0
	for _, root := range dirs {
		err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !d.IsDir() {
				return nil
			}
			if path != root && (strings.HasPrefix(d.Name(), ".") || d.Name() == "testdata" || d.Name() == "vendor" || d.Name() == "webdist" || d.Name() == "bin") {
				return filepath.SkipDir
			}
			f, n, err := lintDir(path)
			all = append(all, f...)
			total += n
			return err
		})
		if err != nil {
			fmt.Fprintln(os.Stderr, "testlint:", err)
			os.Exit(2)
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].pos.String() < all[j].pos.String() })
	for _, f := range all {
		fmt.Printf("%s: %s can never fail: no t.Error*/t.Fatal*/t.Fail*, no helper given t, no subtest that checks anything\n", f.pos, f.name)
	}
	if len(all) > 0 {
		fmt.Printf("testlint: %d of %d tests have no assertion\n", len(all), total)
		os.Exit(1)
	}
	fmt.Printf("testlint: %d tests, all can fail\n", total)
}
