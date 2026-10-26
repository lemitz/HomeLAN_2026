package ratelimit

import (
	"testing"
	"time"
)

func TestLimiterBlocksAndRecovers(t *testing.T) {
	clock := time.Unix(1_000_000, 0)
	l := New(3, time.Minute, 10*time.Minute)
	l.now = func() time.Time { return clock }

	for i := 0; i < 2; i++ {
		l.Fail("ip")
	}
	if ok, _ := l.Allow("ip"); !ok {
		t.Fatal("blocked too early")
	}
	l.Fail("ip")
	if ok, wait := l.Allow("ip"); ok || wait != 10*time.Minute {
		t.Fatalf("expected block for 10m, ok=%v wait=%v", ok, wait)
	}
	if ok, _ := l.Allow("other"); !ok {
		t.Fatal("other keys must not be affected")
	}

	clock = clock.Add(11 * time.Minute)
	if ok, _ := l.Allow("ip"); !ok {
		t.Fatal("block should expire")
	}
}

func TestSuccessResets(t *testing.T) {
	l := New(2, time.Minute, time.Minute)
	l.Fail("ip")
	l.Success("ip")
	l.Fail("ip")
	if ok, _ := l.Allow("ip"); !ok {
		t.Fatal("success should reset counter")
	}
}
