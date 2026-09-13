#!/usr/bin/env python3
"""Deterministic clock helpers for lifecycle and retry fixtures.

The clock never reads or sleeps on wall time.  Tests advance it explicitly, and
scheduled callbacks run synchronously in due-time/FIFO order.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import heapq
import itertools
from typing import Any, Callable, Iterator


@dataclass(order=True)
class ScheduledCall:
    when: float
    order: int
    callback: Callable[..., Any] = field(compare=False, repr=False)
    args: tuple[Any, ...] = field(default_factory=tuple, compare=False, repr=False)
    kwargs: dict[str, Any] = field(default_factory=dict, compare=False, repr=False)
    cancelled: bool = field(default=False, compare=False)

    def cancel(self) -> None:
        self.cancelled = True


class FakeClock:
    """A callable, ``time``/``monotonic``/``sleep`` compatible fake clock."""

    def __init__(self, start: float = 0.0) -> None:
        self._now = self._coerce(start)
        self._order: Iterator[int] = itertools.count()
        self._scheduled: list[ScheduledCall] = []
        self.history: list[dict[str, float | str]] = []
        self.sleeps: list[float] = []

    @staticmethod
    def _coerce(value: float) -> float:
        result = float(value)
        if result < 0:
            raise ValueError("clock values must be non-negative")
        return result

    def __call__(self) -> float:
        return self._now

    def now(self) -> float:
        return self._now

    def time(self) -> float:
        return self._now

    def monotonic(self) -> float:
        return self._now

    def set(self, value: float) -> float:
        target = self._coerce(value)
        if target < self._now:
            raise ValueError("a monotonic fake clock cannot move backwards")
        previous = self._now
        self._advance_to(target)
        self.history.append({"action": "set", "from": previous, "to": target})
        return self._now

    def advance(self, seconds: float) -> float:
        delta = self._coerce(seconds)
        previous = self._now
        self._advance_to(previous + delta)
        self.history.append(
            {"action": "advance", "from": previous, "to": self._now, "seconds": delta}
        )
        return self._now

    def sleep(self, seconds: float) -> None:
        delta = self._coerce(seconds)
        self.sleeps.append(delta)
        previous = self._now
        self._advance_to(previous + delta)
        self.history.append(
            {"action": "sleep", "from": previous, "to": self._now, "seconds": delta}
        )

    def deadline(self, seconds: float) -> float:
        return self._now + self._coerce(seconds)

    def expired(self, deadline: float) -> bool:
        return self._now >= float(deadline)

    def call_at(
        self, when: float, callback: Callable[..., Any], *args: Any, **kwargs: Any
    ) -> ScheduledCall:
        target = self._coerce(when)
        call = ScheduledCall(target, next(self._order), callback, args, kwargs)
        heapq.heappush(self._scheduled, call)
        return call

    def call_later(
        self, seconds: float, callback: Callable[..., Any], *args: Any, **kwargs: Any
    ) -> ScheduledCall:
        return self.call_at(self.deadline(seconds), callback, *args, **kwargs)

    def pending(self) -> tuple[ScheduledCall, ...]:
        return tuple(sorted(call for call in self._scheduled if not call.cancelled))

    def run_due(self) -> None:
        self._advance_to(self._now)

    def _advance_to(self, target: float) -> None:
        while self._scheduled and self._scheduled[0].when <= target:
            call = heapq.heappop(self._scheduled)
            if call.cancelled:
                continue
            self._now = max(self._now, call.when)
            call.callback(*call.args, **call.kwargs)
        self._now = target


def retry_delay(
    attempt: int,
    *,
    initial: float = 1.0,
    multiplier: float = 2.0,
    maximum: float | None = None,
) -> float:
    """Return deterministic exponential backoff for a zero-based attempt."""

    if attempt < 0:
        raise ValueError("attempt must be non-negative")
    if initial < 0 or multiplier < 0:
        raise ValueError("retry parameters must be non-negative")
    delay = float(initial) * (float(multiplier) ** attempt)
    return min(delay, float(maximum)) if maximum is not None else delay
