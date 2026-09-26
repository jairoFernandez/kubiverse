class_name TextDiff
## A small line diff (removed lines with -, added with +): the demo's DIFF,
## where there is no API server to ask.

static func lines(a: String, b: String) -> String:
	var la := a.split("\n")
	var lb := b.split("\n")
	var out := PackedStringArray()
	var i := 0
	var j := 0
	while i < la.size() or j < lb.size():
		if i < la.size() and j < lb.size() and la[i] == lb[j]:
			i += 1
			j += 1
			continue
		# a changed stretch: find where they meet again
		var ni := i
		var nj := j
		var found := false
		for d in range(1, 40):
			for k in d + 1:
				var x := i + k
				var y := j + d - k
				if x < la.size() and y < lb.size() and la[x] == lb[y]:
					ni = x
					nj = y
					found = true
					break
			if found:
				break
		if not found:
			ni = la.size()
			nj = lb.size()
		out.append("@@ line %d @@" % (j + 1))
		for x in range(i, ni):
			out.append("-" + la[x])
		for y in range(j, nj):
			out.append("+" + lb[y])
		i = ni
		j = nj
	return "\n".join(out)
