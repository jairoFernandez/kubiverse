package main

import (
	"context"
	"log"
	"os"
	"time"
)

// exitWithParentEnv is set by the native game when it starts its own bridge:
// the bridge then stops when the game is gone, even after a crash or a
// force quit (otherwise it would be left running in the background). An
// environment variable, not a flag, so the game can set it on older bridges
// too (they ignore it instead of failing on an unknown flag).
const exitWithParentEnv = "KUBIVERSE_EXIT_WITH_PARENT"

// watchParent cancels when the parent process goes away: on Unix the orphan is
// re-parented (to launchd/init/a subreaper), so its parent PID changes. On
// Windows getppid keeps the original PID, so it never fires there.
func watchParent(ctx context.Context, cancel context.CancelFunc, getppid func() int, every time.Duration) {
	start := getppid()
	if start <= 1 {
		return // already orphaned or started by init: nothing to follow
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if getppid() != start {
				log.Printf("the game that started this bridge (pid %d) is gone: stopping", start)
				cancel()
				return
			}
		}
	}
}

func exitWithParent() bool { return os.Getenv(exitWithParentEnv) == "1" }
