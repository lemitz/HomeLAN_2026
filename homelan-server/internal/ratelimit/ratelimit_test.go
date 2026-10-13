package ratelimit

import (
	"testing"
	"time"
)

func TestLimiterBlocksAfterFailures(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := New(3, 10*time.Second, time.Minute)
	l.now = func() time.Time { return now }

	for i := 0; i < 2; i++ {
		if ok, _ := l.Allow("k"); !ok {
			t.Fatalf("attempt %d should be allowed", i)
		}
		l.Fail("k")
	}
	if ok, _ := l.Allow("k"); !ok {
		t.Fatal("third attempt should still be allowed")
	}
	l.Fail("k") // 3rd failure -> blocked for 10s

	ok, wait := l.Allow("k")
	if ok || wait != 10*time.Second {
		t.Fatalf("expected block for 10s, got ok=%v wait=%v", ok, wait)
	}

	now = now.Add(11 * time.Second)
	if ok, _ := l.Allow("k"); !ok {
		t.Fatal("should be allowed after delay")
	}

	l.Fail("k") // 4th failure -> 20s
	if _, wait := l.Allow("k"); wait != 20*time.Second {
		t.Fatalf("expected exponential backoff 20s, got %v", wait)
	}

	for i := 0; i < 10; i++ {
		l.Fail("k")
	}
	if _, wait := l.Allow("k"); wait > time.Minute {
		t.Fatalf("delay must be capped at maxDelay, got %v", wait)
	}

	l.Reset("k")
	if ok, _ := l.Allow("k"); !ok {
		t.Fatal("reset must clear the block")
	}
}

func TestLimiterKeysAreIndependent(t *testing.T) {
	l := New(1, time.Minute, time.Minute)
	l.Fail("a")
	if ok, _ := l.Allow("a"); ok {
		t.Fatal("a should be blocked")
	}
	if ok, _ := l.Allow("b"); !ok {
		t.Fatal("b should be allowed")
	}
}

func TestSweepRemovesStaleEntries(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := New(1, time.Second, time.Second)
	l.now = func() time.Time { return now }
	l.Fail("old")

	now = now.Add(3 * time.Hour)
	l.Allow("other")
	if _, ok := l.entries["old"]; ok {
		t.Fatal("stale entry should be swept")
	}
}
