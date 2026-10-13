// Package ratelimit — простой in-memory лимитер неудачных попыток (логин, коды привязки).
//
// После maxFailures подряд неудачных попыток ключ блокируется на baseDelay,
// и каждая следующая неудача удваивает задержку вплоть до maxDelay.
// Успешная попытка сбрасывает счётчик.
package ratelimit

import (
	"sync"
	"time"
)

type entry struct {
	failures     int
	blockedUntil time.Time
	lastFailure  time.Time
}

type Limiter struct {
	mu          sync.Mutex
	entries     map[string]*entry
	maxFailures int
	baseDelay   time.Duration
	maxDelay    time.Duration
	ttl         time.Duration
	now         func() time.Time
	lastSweep   time.Time
}

// New создаёт лимитер: maxFailures свободных попыток, затем блокировка baseDelay,
// удваивающаяся при каждой следующей неудаче до maxDelay.
func New(maxFailures int, baseDelay, maxDelay time.Duration) *Limiter {
	if maxFailures < 1 {
		maxFailures = 1
	}
	return &Limiter{
		entries:     make(map[string]*entry),
		maxFailures: maxFailures,
		baseDelay:   baseDelay,
		maxDelay:    maxDelay,
		ttl:         maxDelay + time.Hour,
		now:         time.Now,
	}
}

// Allow сообщает, разрешена ли попытка для ключа, и сколько ждать, если нет.
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.sweepLocked()

	e, ok := l.entries[key]
	if !ok {
		return true, 0
	}
	now := l.now()
	if now.Before(e.blockedUntil) {
		return false, e.blockedUntil.Sub(now)
	}
	return true, 0
}

// Fail регистрирует неудачную попытку.
func (l *Limiter) Fail(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	e, ok := l.entries[key]
	if !ok {
		e = &entry{}
		l.entries[key] = e
	}
	e.failures++
	e.lastFailure = now

	if e.failures >= l.maxFailures {
		exp := e.failures - l.maxFailures
		delay := l.baseDelay
		for i := 0; i < exp && delay < l.maxDelay; i++ {
			delay *= 2
		}
		if delay > l.maxDelay {
			delay = l.maxDelay
		}
		e.blockedUntil = now.Add(delay)
	}
}

// Reset сбрасывает счётчик (после успешной попытки).
func (l *Limiter) Reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, key)
}

// sweepLocked удаляет устаревшие записи (не чаще раза в минуту).
func (l *Limiter) sweepLocked() {
	now := l.now()
	if now.Sub(l.lastSweep) < time.Minute {
		return
	}
	l.lastSweep = now
	for k, e := range l.entries {
		if now.Sub(e.lastFailure) > l.ttl && now.After(e.blockedUntil) {
			delete(l.entries, k)
		}
	}
}
