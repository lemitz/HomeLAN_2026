// Package ratelimit — защита от перебора паролей и кодов.
package ratelimit

import (
	"sync"
	"time"
)

type entry struct {
	failures     int
	windowStart  time.Time
	blockedUntil time.Time
}

// Limiter блокирует ключ (обычно IP) после MaxFailures неудач за Window
// на время Block.
type Limiter struct {
	MaxFailures int
	Window      time.Duration
	Block       time.Duration

	mu      sync.Mutex
	entries map[string]*entry
	now     func() time.Time
}

func New(maxFailures int, window, block time.Duration) *Limiter {
	return &Limiter{
		MaxFailures: maxFailures,
		Window:      window,
		Block:       block,
		entries:     make(map[string]*entry),
		now:         time.Now,
	}
}

// Allow сообщает, можно ли сейчас делать попытку, и сколько ждать, если нет.
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.entries[key]
	if e == nil {
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
	e := l.entries[key]
	if e == nil || now.Sub(e.windowStart) > l.Window {
		e = &entry{windowStart: now}
		l.entries[key] = e
	}
	e.failures++
	if e.failures >= l.MaxFailures {
		e.blockedUntil = now.Add(l.Block)
		e.failures = 0
		e.windowStart = now
	}
	l.gc(now)
}

// Success сбрасывает счётчик ключа.
func (l *Limiter) Success(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, key)
}

// gc удаляет устаревшие записи, чтобы карта не росла бесконечно.
func (l *Limiter) gc(now time.Time) {
	if len(l.entries) < 1024 {
		return
	}
	for k, e := range l.entries {
		if now.After(e.blockedUntil) && now.Sub(e.windowStart) > l.Window {
			delete(l.entries, k)
		}
	}
}
