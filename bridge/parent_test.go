package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestWatchParentCancelsWhenParentChanges(t *testing.T) {
	var ppid atomic.Int64
	ppid.Store(4242)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		watchParent(ctx, cancel, func() int { return int(ppid.Load()) }, time.Millisecond)
		close(done)
	}()
	time.Sleep(10 * time.Millisecond)
	if ctx.Err() != nil {
		t.Fatal("cancelled while the parent was still alive")
	}
	ppid.Store(1) // re-parented to init: the game is gone
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("watchParent did not notice the parent going away")
	}
	if ctx.Err() == nil {
		t.Fatal("context not cancelled after the parent went away")
	}
}

func TestWatchParentStopsWithContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		watchParent(ctx, func() {}, func() int { return 4242 }, time.Millisecond)
		close(done)
	}()
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("watchParent kept running after its context ended")
	}
}

func TestWatchParentIgnoresInitParent(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	called := false
	watchParent(ctx, func() { called = true }, func() int { return 1 }, time.Millisecond)
	if called || ctx.Err() != nil {
		t.Fatal("a bridge started by init must not stop itself")
	}
}

func TestExitWithParentEnv(t *testing.T) {
	t.Setenv(exitWithParentEnv, "")
	if exitWithParent() {
		t.Fatal("off by default")
	}
	t.Setenv(exitWithParentEnv, "1")
	if !exitWithParent() {
		t.Fatal("on with " + exitWithParentEnv + "=1")
	}
}
