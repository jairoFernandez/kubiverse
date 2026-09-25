`make bridge-bundle` copies the Godot web export here so `go:embed` bundles it
into the k8s-bridge binary. Everything but this file is git-ignored.
