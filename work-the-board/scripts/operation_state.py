"""Durable operation lifecycle registry.

The store deliberately depends only on the Python standard library.  Each
mutation is one SQLite ``BEGIN IMMEDIATE`` transaction, and every externally
retried mutation either accepts an explicit stable identifier or has an
idempotent same-value path.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import math
import sqlite3
import time
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Optional, Sequence


class OperationState(str, Enum):
    REGISTERED = "registered"
    LAUNCHING = "launching"
    WORKING = "working"
    WAITING_USER = "waiting_user"
    COMPLETED = "completed"
    FAILED = "failed"
    RETIRING = "retiring"
    CLOSED = "closed"
    MISSING = "missing"


class ReportStatus(str, Enum):
    PENDING = "pending"
    SUBMITTED = "submitted"
    ACKNOWLEDGED = "acknowledged"


class LeaseDisposition(str, Enum):
    ACTIVE = "active"
    RELEASED = "released"
    EXPIRED = "expired"

class CloseDisposition(str, Enum):
    PENDING = "pending"
    CLOSED = "closed"
    MISSING = "missing"
    DEFERRED = "deferred"
    REFUSED = "refused"


class LaunchIntentStatus(str, Enum):
    PENDING = "pending"
    EXECUTING = "executing"
    COMMITTED = "committed"
    AMBIGUOUS = "ambiguous"
    FAILED = "failed"

@dataclass(frozen=True)
class LaunchIntent:
    intent_id: str
    operation_id: str
    generation: int
    kind: str
    idempotency_key: str
    payload: str
    status: LaunchIntentStatus
    outcome: Optional[str]
    evidence: Optional[str]
    created_at: float
    updated_at: float


class OperationStoreError(RuntimeError):
    """Base class for lifecycle registry errors."""


class OperationNotFound(OperationStoreError):
    pass


class StaleGeneration(OperationStoreError):
    def __init__(self, operation_id: str, requested: int, current: int) -> None:
        super().__init__(
            f"stale generation for {operation_id!r}: requested {requested}, current {current}"
        )
        self.operation_id = operation_id
        self.requested = requested
        self.current = current


class LifecycleConflict(OperationStoreError):
    pass


class InvalidTransition(OperationStoreError):
    pass


class CloseNotEligible(OperationStoreError):
    def __init__(self, eligibility: "CloseEligibility") -> None:
        super().__init__(eligibility.reason)
        self.eligibility = eligibility


@dataclass(frozen=True)
class OperationIdentity:
    board: str
    repo: str
    workspace: str
    tab: str
    root_pane: str
    terminal: str
    session: str


@dataclass(frozen=True)
class OperationRecord:
    operation_id: str
    generation: int
    state: OperationState
    identity: OperationIdentity
    registered_at: float
    updated_at: float
    state_evidence: Optional[str]


@dataclass(frozen=True)
class ReportRecord:
    report_id: str
    operation_id: str
    generation: int
    board: str
    recipient: str
    body: str
    digest: str
    is_final: bool
    status: ReportStatus
    attempts: int
    created_at: float
    updated_at: float
    submission_id: Optional[str]
    submitted_at: Optional[float]
    acknowledged_at: Optional[float]
    acknowledgment: Optional[str]
    last_error: Optional[str]
    claim_owner: Optional[str]
    claim_expires_at: Optional[float]


@dataclass(frozen=True)
class RetentionLease:
    lease_id: str
    operation_id: str
    generation: int
    holder: str
    reason: str
    acquired_at: float
    expires_at: float
    disposition: LeaseDisposition
    disposed_at: Optional[float]
    evidence: Optional[str]


@dataclass(frozen=True)
class CloseEligibility:
    eligible: bool
    reason: str
    operation: OperationRecord


@dataclass(frozen=True)
class CloseIntent:
    intent_id: str
    operation_id: str
    generation: int
    identity: OperationIdentity
    requested_at: float
    reason: str
    disposition: CloseDisposition
    disposed_at: Optional[float]
    evidence: Optional[str]


_ALLOWED_TRANSITIONS = {
    OperationState.REGISTERED: {
        OperationState.LAUNCHING,
        OperationState.FAILED,
        OperationState.RETIRING,
        OperationState.MISSING,
    },
    OperationState.LAUNCHING: {
        OperationState.WORKING,
        OperationState.WAITING_USER,
        OperationState.FAILED,
        OperationState.RETIRING,
        OperationState.MISSING,
    },
    OperationState.WORKING: {
        OperationState.WAITING_USER,
        OperationState.COMPLETED,
        OperationState.FAILED,
        OperationState.RETIRING,
        OperationState.MISSING,
    },
    OperationState.WAITING_USER: {
        OperationState.WORKING,
        OperationState.COMPLETED,
        OperationState.FAILED,
        OperationState.RETIRING,
        OperationState.MISSING,
    },
    OperationState.COMPLETED: {
        OperationState.RETIRING,
        OperationState.MISSING,
    },
    OperationState.FAILED: {
        OperationState.WORKING,
        OperationState.RETIRING,
        OperationState.MISSING,
    },
    OperationState.RETIRING: {
        OperationState.CLOSED,
        OperationState.MISSING,
    },
    OperationState.MISSING: {
        OperationState.WORKING,
        OperationState.WAITING_USER,
        OperationState.COMPLETED,
        OperationState.FAILED,
        OperationState.RETIRING,
        OperationState.CLOSED,
    },
    OperationState.CLOSED: set(),
}


_SCHEMA = """
CREATE TABLE IF NOT EXISTS operations (
    operation_id TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation >= 0),
    state TEXT NOT NULL CHECK (state IN (
        'registered', 'launching', 'working', 'waiting_user', 'completed',
        'failed', 'retiring', 'closed', 'missing'
    )),
    board TEXT NOT NULL,
    repo TEXT NOT NULL,
    workspace TEXT NOT NULL,
    tab TEXT NOT NULL,
    root_pane TEXT NOT NULL,
    terminal TEXT NOT NULL,
    session TEXT NOT NULL,
    registered_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    state_evidence TEXT,
    PRIMARY KEY (operation_id, generation)
);
CREATE INDEX IF NOT EXISTS operations_current
    ON operations (operation_id, generation DESC);
CREATE INDEX IF NOT EXISTS operations_state ON operations (state, updated_at);

CREATE TABLE IF NOT EXISTS transitions (
    transition_id TEXT NOT NULL PRIMARY KEY,
    operation_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    from_state TEXT NOT NULL,
    to_state TEXT NOT NULL,
    evidence TEXT,
    occurred_at REAL NOT NULL,
    FOREIGN KEY (operation_id, generation)
        REFERENCES operations (operation_id, generation) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS transitions_operation
    ON transitions (operation_id, generation, occurred_at);

CREATE TABLE IF NOT EXISTS reports (
    report_id TEXT NOT NULL PRIMARY KEY,
    operation_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    board TEXT NOT NULL,
    recipient TEXT NOT NULL,
    body TEXT NOT NULL,
    digest TEXT NOT NULL,
    is_final INTEGER NOT NULL CHECK (is_final IN (0, 1)),
    status TEXT NOT NULL CHECK (status IN ('pending', 'submitted', 'acknowledged')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    submission_id TEXT,
    submitted_at REAL,
    acknowledged_at REAL,
    acknowledgment TEXT,
    last_error TEXT,
    claim_owner TEXT,
    claim_expires_at REAL,
    FOREIGN KEY (operation_id, generation)
        REFERENCES operations (operation_id, generation) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS reports_delivery
    ON reports (status, created_at);
CREATE INDEX IF NOT EXISTS reports_operation
    ON reports (operation_id, generation, is_final, status);

CREATE TABLE IF NOT EXISTS retention_leases (
    lease_id TEXT NOT NULL PRIMARY KEY,
    operation_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    holder TEXT NOT NULL,
    reason TEXT NOT NULL,
    acquired_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    disposition TEXT NOT NULL CHECK (disposition IN ('active', 'released', 'expired')),
    disposed_at REAL,
    evidence TEXT,
    FOREIGN KEY (operation_id, generation)
        REFERENCES operations (operation_id, generation) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS retention_operation
    ON retention_leases (operation_id, generation, disposition, expires_at);

CREATE TABLE IF NOT EXISTS close_intents (
    intent_id TEXT NOT NULL PRIMARY KEY,
    operation_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    board TEXT NOT NULL,
    repo TEXT NOT NULL,
    workspace TEXT NOT NULL,
    tab TEXT NOT NULL,
    root_pane TEXT NOT NULL,
    terminal TEXT NOT NULL,
    session TEXT NOT NULL,
    requested_at REAL NOT NULL,
    reason TEXT NOT NULL,
    disposition TEXT NOT NULL CHECK (
        disposition IN ('pending', 'closed', 'missing', 'deferred', 'refused')
    ),
    disposed_at REAL,
    evidence TEXT,
    FOREIGN KEY (operation_id, generation)
        REFERENCES operations (operation_id, generation) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS close_intents_operation
    ON close_intents (operation_id, generation, requested_at);
CREATE UNIQUE INDEX IF NOT EXISTS close_intents_pending
    ON close_intents (operation_id, generation)
    WHERE disposition = 'pending';
CREATE TABLE IF NOT EXISTS launch_intents (
    intent_id TEXT PRIMARY KEY,
    operation_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('create', 'start', 'prompt')),
    idempotency_key TEXT NOT NULL UNIQUE,
    payload TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'executing', 'committed', 'ambiguous', 'failed')),
    outcome TEXT,
    evidence TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS launch_intents_operation
    ON launch_intents (operation_id, generation, status, created_at);
"""


class OperationStore:
    """SQLite-backed authoritative registry for operation generations."""

    def __init__(
        self,
        path: str,
        *,
        clock: Callable[[], float] = time.time,
        busy_timeout_ms: int = 5000,
    ) -> None:
        db_path = Path(path).expanduser()
        if not db_path.is_absolute():
            raise ValueError("operation state database path must be absolute")
        if busy_timeout_ms < 0:
            raise ValueError("busy_timeout_ms must be non-negative")
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.path = str(db_path)
        self._clock = clock
        self._busy_timeout_ms = busy_timeout_ms
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(
            self.path,
            timeout=self._busy_timeout_ms / 1000.0,
            isolation_level=None,
        )
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(f"PRAGMA busy_timeout = {self._busy_timeout_ms}")
        return connection

    def _initialize(self) -> None:
        connection = self._connect()
        try:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA synchronous = FULL")
            try:
                connection.executescript("BEGIN IMMEDIATE;\n" + _SCHEMA)
                report_columns = {
                    row["name"] for row in connection.execute("PRAGMA table_info(reports)")
                }
                migrations = {
                    "board": "ALTER TABLE reports ADD COLUMN board TEXT NOT NULL DEFAULT ''",
                    "recipient": "ALTER TABLE reports ADD COLUMN recipient TEXT NOT NULL DEFAULT ''",
                    "claim_owner": "ALTER TABLE reports ADD COLUMN claim_owner TEXT",
                    "claim_expires_at": "ALTER TABLE reports ADD COLUMN claim_expires_at REAL",
                }
                for column, statement in migrations.items():
                    if column not in report_columns:
                        connection.execute(statement)
                connection.execute(
                    """UPDATE reports SET board = (
                           SELECT board FROM operations
                           WHERE operations.operation_id = reports.operation_id
                             AND operations.generation = reports.generation
                       ) WHERE board = ''"""
                )
                connection.execute(
                    "UPDATE reports SET recipient = board WHERE recipient = ''"
                )
                version = connection.execute("PRAGMA user_version").fetchone()[0]
                if version < 3:
                    connection.execute(
                        """CREATE TABLE launch_intents_v3 (
                            intent_id TEXT PRIMARY KEY,
                            operation_id TEXT NOT NULL,
                            generation INTEGER NOT NULL,
                            kind TEXT NOT NULL CHECK (kind IN ('create', 'start', 'prompt')),
                            idempotency_key TEXT NOT NULL UNIQUE,
                            payload TEXT NOT NULL,
                            status TEXT NOT NULL CHECK (status IN (
                                'pending', 'executing', 'committed', 'ambiguous', 'failed'
                            )),
                            outcome TEXT, evidence TEXT,
                            created_at REAL NOT NULL, updated_at REAL NOT NULL
                        )"""
                    )
                    connection.execute(
                        "INSERT INTO launch_intents_v3 SELECT * FROM launch_intents"
                    )
                    connection.execute("DROP TABLE launch_intents")
                    connection.execute("ALTER TABLE launch_intents_v3 RENAME TO launch_intents")
                    connection.execute(
                        """CREATE INDEX launch_intents_operation
                           ON launch_intents (operation_id, generation, status, created_at)"""
                    )
                    connection.execute("PRAGMA user_version = 3")
            except BaseException:
                connection.rollback()
                raise
            else:
                connection.commit()
        finally:
            connection.close()

    @contextmanager
    def launch_lock(self, operation_id: str) -> Iterator[None]:
        operation_id = _required("operation_id", operation_id)
        suffix = hashlib.sha256(operation_id.encode()).hexdigest()
        # Keep the inode stable; unlinking a lock permits two independent owners.
        with open(f"{self.path}.launch-{suffix}.lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise LifecycleConflict(f"operation {operation_id!r} is already launching") from error
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            try:
                yield connection
            except BaseException:
                connection.rollback()
                raise
            else:
                connection.commit()
        finally:
            connection.close()

    @contextmanager
    def _read(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            yield connection
        finally:
            connection.close()

    def register(
        self,
        operation_id: str,
        generation: int,
        identity: OperationIdentity,
        *,
        evidence: Optional[str] = None,
    ) -> OperationRecord:
        operation_id = _required("operation_id", operation_id)
        generation = _generation(generation)
        identity = _identity(identity)
        now = self._clock()
        with self._transaction() as connection:
            current = self._current_row(connection, operation_id)
            if current is not None:
                current_generation = int(current["generation"])
                if generation < current_generation:
                    raise StaleGeneration(operation_id, generation, current_generation)
                if generation == current_generation:
                    record = _operation(current)
                    if record.identity != identity:
                        raise LifecycleConflict(
                            f"generation {generation} of {operation_id!r} is already registered "
                            "to a different identity"
                        )
                    return record
                if OperationState(current["state"]) not in {
                    OperationState.CLOSED,
                    OperationState.MISSING,
                }:
                    raise LifecycleConflict(
                        f"cannot register generation {generation} of {operation_id!r}; "
                        f"generation {current_generation} is {current['state']}"
                    )
            connection.execute(
                """INSERT INTO operations (
                       operation_id, generation, state, board, repo, workspace,
                       tab, root_pane, terminal, session, registered_at,
                       updated_at, state_evidence
                   ) VALUES (?, ?, 'registered', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    operation_id,
                    generation,
                    identity.board,
                    identity.repo,
                    identity.workspace,
                    identity.tab,
                    identity.root_pane,
                    identity.terminal,
                    identity.session,
                    now,
                    now,
                    evidence,
                ),
            )
            return self._get_row(connection, operation_id, generation)

    def get(self, operation_id: str, generation: Optional[int] = None) -> OperationRecord:
        operation_id = _required("operation_id", operation_id)
        with self._read() as connection:
            if generation is None:
                row = self._current_row(connection, operation_id)
                if row is None:
                    raise OperationNotFound(operation_id)
                return _operation(row)
            return self._get_row(connection, operation_id, _generation(generation))

    def list_operations(
        self,
        *,
        states: Optional[Sequence[OperationState]] = None,
        current_only: bool = True,
    ) -> list[OperationRecord]:
        parameters: list[Any] = []
        if current_only:
            sql = """SELECT o.* FROM operations o
                     JOIN (
                         SELECT operation_id, MAX(generation) AS generation
                         FROM operations GROUP BY operation_id
                     ) c USING (operation_id, generation)"""
        else:
            sql = "SELECT * FROM operations o"
        if states:
            values = [OperationState(state).value for state in states]
            sql += f" WHERE o.state IN ({','.join('?' for _ in values)})"
            parameters.extend(values)
        sql += " ORDER BY o.operation_id, o.generation"
        with self._read() as connection:
            return [_operation(row) for row in connection.execute(sql, parameters)]
    def prepare_launch_intent(
        self,
        operation_id: str,
        generation: int,
        intent_id: str,
        kind: str,
        idempotency_key: str,
        payload: Mapping[str, Any],
    ) -> LaunchIntent:
        operation_id = _required("operation_id", operation_id)
        generation = _generation(generation)
        idempotency_key = _required("idempotency_key", idempotency_key)
        if kind not in {"create", "start", "prompt"}:
            raise ValueError("launch intent kind must be create, start, or prompt")
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        now = self._clock()
        with self._transaction() as connection:
            current = self._current_row(connection, operation_id)
            if current is not None:
                latest = int(current["generation"])
                if generation < latest:
                    raise StaleGeneration(operation_id, generation, latest)
                if generation > latest and current["state"] not in {"closed", "missing"}:
                    raise LifecycleConflict("previous operation generation is still active")
            reserved = connection.execute(
                "SELECT MAX(generation) FROM launch_intents WHERE operation_id = ?",
                (operation_id,),
            ).fetchone()[0]
            if reserved is not None:
                if generation < reserved:
                    raise StaleGeneration(operation_id, generation, reserved)
                if generation > reserved and (
                    current is None or int(current["generation"]) < reserved
                ):
                    raise LifecycleConflict("previous launch is unresolved")
            existing = connection.execute(
                "SELECT * FROM launch_intents WHERE intent_id = ?",
                (_required("intent_id", intent_id),),
            ).fetchone()
            if existing is not None:
                intent = _launch_intent(existing)
                if (
                    intent.operation_id != operation_id
                    or intent.generation != generation
                    or intent.kind != kind
                    or intent.idempotency_key != idempotency_key
                ):
                    raise LifecycleConflict("launch intent identity or payload conflict")
                if intent.payload != encoded:
                    legacy = json.loads(intent.payload)
                    legacy_keys = {"workspace", "cwd", "label"}
                    if (
                        kind != "create"
                        or not isinstance(legacy, dict)
                        or set(legacy) != legacy_keys
                        or set(payload) != legacy_keys | {"board", "repo", "agent", "prompt"}
                        or any(payload[key] != value for key, value in legacy.items())
                    ):
                        raise LifecycleConflict("launch intent identity or payload conflict")
                    # Older controllers did not persist the whole business request at
                    # creation. Bind missing fields only after checking every known value.
                    if current is not None and int(current["generation"]) == generation:
                        if any(current[key] != payload[key] for key in ("board", "repo", "workspace")):
                            raise LifecycleConflict("legacy launch disagrees with registered ownership")
                    for row in connection.execute(
                        """SELECT payload FROM launch_intents
                           WHERE operation_id = ? AND generation = ? AND kind IN ('start', 'prompt')""",
                        (operation_id, generation),
                    ):
                        known = json.loads(row["payload"])
                        if not isinstance(known, dict) or any(
                            key in known and known[key] != payload[key]
                            for key in ("agent", "prompt")
                        ):
                            raise LifecycleConflict("legacy launch disagrees with saved agent or prompt")
                    connection.execute(
                        "UPDATE launch_intents SET payload = ?, updated_at = ? WHERE intent_id = ?",
                        (encoded, now, intent_id),
                    )
                    return self._launch_intent_row(connection, intent_id)
                return intent
            if kind == "create" and current is not None and generation == int(current["generation"]):
                raise LifecycleConflict("registered generation has no matching launch reservation")
            connection.execute(
                """INSERT INTO launch_intents (
                       intent_id, operation_id, generation, kind, idempotency_key,
                       payload, status, created_at, updated_at
                   ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)""",
                (
                    intent_id,
                    operation_id,
                    generation,
                    kind,
                    idempotency_key,
                    encoded,
                    now,
                    now,
                ),
            )
            return self._launch_intent_row(connection, intent_id)

    def get_launch_intent(self, intent_id: str) -> LaunchIntent:
        with self._read() as connection:
            return self._launch_intent_row(connection, _required("intent_id", intent_id))

    def list_launch_intents(
        self, operation_id: str, generation: int
    ) -> list[LaunchIntent]:
        with self._read() as connection:
            return [
                _launch_intent(row)
                for row in connection.execute(
                    """SELECT * FROM launch_intents
                       WHERE operation_id = ? AND generation = ?
                       ORDER BY created_at, intent_id""",
                    (operation_id, generation),
                )
            ]

    def claim_launch_intent(self, intent_id: str) -> Optional[LaunchIntent]:
        with self._transaction() as connection:
            intent = self._launch_intent_row(connection, intent_id)
            if intent.status != LaunchIntentStatus.PENDING:
                return None
            connection.execute(
                """UPDATE launch_intents
                   SET status = 'executing', updated_at = ?
                   WHERE intent_id = ? AND status = 'pending'""",
                (self._clock(), intent_id),
            )
            return self._launch_intent_row(connection, intent_id)

    def record_launch_intent(
        self,
        intent_id: str,
        status: LaunchIntentStatus,
        *,
        outcome: Optional[Mapping[str, Any]] = None,
        evidence: Optional[str] = None,
    ) -> LaunchIntent:
        status = LaunchIntentStatus(status)
        encoded = None if outcome is None else json.dumps(
            outcome, sort_keys=True, separators=(",", ":")
        )
        with self._transaction() as connection:
            intent = self._launch_intent_row(connection, intent_id)
            if intent.status == LaunchIntentStatus.COMMITTED and status != intent.status:
                return intent
            if status == LaunchIntentStatus.COMMITTED and encoded is None:
                raise ValueError("committed launch intent requires an outcome")
            connection.execute(
                """UPDATE launch_intents
                   SET status = ?, outcome = COALESCE(?, outcome),
                       evidence = COALESCE(?, evidence), updated_at = ?
                   WHERE intent_id = ?""",
                (status.value, encoded, evidence, self._clock(), intent_id),
            )
            return self._launch_intent_row(connection, intent_id)

    def transition(
        self,
        operation_id: str,
        generation: int,
        state: OperationState,
        *,
        evidence: Optional[str] = None,
        expected_state: Optional[OperationState] = None,
        transition_id: Optional[str] = None,
    ) -> OperationRecord:
        operation_id = _required("operation_id", operation_id)
        generation = _generation(generation)
        target = OperationState(state)
        expected = OperationState(expected_state) if expected_state is not None else None
        if transition_id is not None:
            transition_id = _required("transition_id", transition_id)
        now = self._clock()
        with self._transaction() as connection:
            row = self._require_current(connection, operation_id, generation)
            current = OperationState(row["state"])
            if transition_id is not None:
                prior = connection.execute(
                    "SELECT * FROM transitions WHERE transition_id = ?", (transition_id,)
                ).fetchone()
                if prior is not None:
                    if (
                        prior["operation_id"] != operation_id
                        or int(prior["generation"]) != generation
                        or prior["from_state"] != current.value
                        and prior["to_state"] != current.value
                        or prior["to_state"] != target.value
                        or prior["evidence"] != evidence
                    ):
                        raise LifecycleConflict(
                            f"transition_id {transition_id!r} was used for another transition"
                        )
                    return _operation(row)
            if current == target:
                return _operation(row)
            if expected is not None and current != expected:
                raise LifecycleConflict(
                    f"expected {operation_id!r} generation {generation} to be "
                    f"{expected.value}, found {current.value}"
                )
            if target not in _ALLOWED_TRANSITIONS[current]:
                raise InvalidTransition(f"cannot transition from {current.value} to {target.value}")
            connection.execute(
                """UPDATE operations
                   SET state = ?, updated_at = ?, state_evidence = ?
                   WHERE operation_id = ? AND generation = ?""",
                (target.value, now, evidence, operation_id, generation),
            )
            event_id = transition_id or _transition_digest(
                operation_id, generation, current, target, now
            )
            connection.execute(
                """INSERT INTO transitions (
                       transition_id, operation_id, generation, from_state,
                       to_state, evidence, occurred_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    event_id,
                    operation_id,
                    generation,
                    current.value,
                    target.value,
                    evidence,
                    now,
                ),
            )
            return self._get_row(connection, operation_id, generation)

    def enqueue_report(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        body: str,
        *,
        digest: Optional[str] = None,
        is_final: bool = False,
        board: Optional[str] = None,
        recipient: Optional[str] = None,
    ) -> ReportRecord:
        operation_id = _required("operation_id", operation_id)
        generation = _generation(generation)
        report_id = _required("report_id", report_id)
        digest = _report_digest(body, digest)
        now = self._clock()
        with self._transaction() as connection:
            operation = _operation(
                self._require_current(connection, operation_id, generation)
            )
            return self._enqueue_report(
                connection,
                operation,
                report_id,
                body,
                digest,
                bool(is_final),
                board or operation.identity.board,
                recipient or board or operation.identity.board,
                now,
            )

    def finalize(
        self,
        operation_id: str,
        generation: int,
        state: OperationState,
        report_id: str,
        body: str,
        *,
        digest: Optional[str] = None,
        board: Optional[str] = None,
        recipient: Optional[str] = None,
        evidence: Optional[str] = None,
        transition_id: Optional[str] = None,
    ) -> tuple[OperationRecord, ReportRecord]:
        """Atomically persist a final report and completed/failed lifecycle state."""
        operation_id = _required("operation_id", operation_id)
        generation = _generation(generation)
        report_id = _required("report_id", report_id)
        target = OperationState(state)
        if target not in {OperationState.COMPLETED, OperationState.FAILED}:
            raise ValueError("final state must be completed or failed")
        digest = _report_digest(body, digest)
        event_id = transition_id or f"finalize:{report_id}:{target.value}"
        now = self._clock()
        with self._transaction() as connection:
            row = self._require_current(connection, operation_id, generation)
            operation = _operation(row)
            report = self._enqueue_report(
                connection,
                operation,
                report_id,
                body,
                digest,
                True,
                board or operation.identity.board,
                recipient or board or operation.identity.board,
                now,
            )
            if operation.state != target:
                if target not in _ALLOWED_TRANSITIONS[operation.state]:
                    raise InvalidTransition(
                        f"cannot transition from {operation.state.value} to {target.value}"
                    )
                prior = connection.execute(
                    "SELECT * FROM transitions WHERE transition_id = ?", (event_id,)
                ).fetchone()
                if prior is not None:
                    raise LifecycleConflict(
                        f"transition_id {event_id!r} was used before terminal state persisted"
                    )
                connection.execute(
                    """UPDATE operations SET state = ?, updated_at = ?, state_evidence = ?
                       WHERE operation_id = ? AND generation = ?""",
                    (target.value, now, evidence, operation_id, generation),
                )
                connection.execute(
                    """INSERT INTO transitions (
                           transition_id, operation_id, generation, from_state,
                           to_state, evidence, occurred_at
                       ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (
                        event_id,
                        operation_id,
                        generation,
                        operation.state.value,
                        target.value,
                        evidence,
                        now,
                    ),
                )
            return self._get_row(connection, operation_id, generation), report

    def _enqueue_report(
        self,
        connection: sqlite3.Connection,
        operation: OperationRecord,
        report_id: str,
        body: str,
        digest: str,
        is_final: bool,
        board: str,
        recipient: str,
        now: float,
    ) -> ReportRecord:
        board = _required("board", board)
        recipient = _required("recipient", recipient)
        prior = connection.execute(
            "SELECT * FROM reports WHERE report_id = ?", (report_id,)
        ).fetchone()
        if prior is not None:
            report = _report(prior)
            if (
                report.operation_id != operation.operation_id
                or report.generation != operation.generation
                or report.board != board
                or report.recipient != recipient
                or report.body != body
                or report.digest != digest
                or report.is_final != is_final
            ):
                raise LifecycleConflict(
                    f"report_id {report_id!r} was used for different report content or routing"
                )
            return report
        connection.execute(
            """INSERT INTO reports (
                   report_id, operation_id, generation, board, recipient, body,
                   digest, is_final, status, created_at, updated_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)""",
            (
                report_id,
                operation.operation_id,
                operation.generation,
                board,
                recipient,
                body,
                digest,
                int(is_final),
                now,
                now,
            ),
        )
        return self._report_row(connection, report_id)

    def list_reports(
        self,
        *,
        statuses: Optional[Sequence[ReportStatus]] = None,
        operation_id: Optional[str] = None,
        generation: Optional[int] = None,
        board: Optional[str] = None,
        recipient: Optional[str] = None,
    ) -> list[ReportRecord]:
        clauses: list[str] = []
        parameters: list[Any] = []
        if statuses:
            values = [ReportStatus(status).value for status in statuses]
            clauses.append(f"status IN ({','.join('?' for _ in values)})")
            parameters.extend(values)
        for column, value in (
            ("operation_id", operation_id),
            ("board", board),
            ("recipient", recipient),
        ):
            if value is not None:
                clauses.append(f"{column} = ?")
                parameters.append(_required(column, value))
        if generation is not None:
            clauses.append("generation = ?")
            parameters.append(_generation(generation))
        sql = "SELECT * FROM reports"
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        sql += " ORDER BY created_at, report_id"
        with self._read() as connection:
            return [_report(row) for row in connection.execute(sql, parameters)]

    def claim_report_submission(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        owner: str,
        *,
        expires_at: float,
    ) -> Optional[ReportRecord]:
        owner = _required("owner", owner)
        now = self._clock()
        if not math.isfinite(expires_at) or expires_at <= now:
            raise ValueError("report claim deadline must be finite and in the future")
        with self._transaction() as connection:
            report = self._require_report(
                connection, operation_id, generation, report_id, current=False
            )
            if report.status != ReportStatus.PENDING:
                return None
            if (
                report.claim_owner is not None
                and report.claim_owner != owner
                and report.claim_expires_at is not None
                and report.claim_expires_at > now
            ):
                return None
            connection.execute(
                """UPDATE reports SET claim_owner = ?, claim_expires_at = ?, updated_at = ?
                   WHERE report_id = ?""",
                (owner, expires_at, now, report_id),
            )
            return self._report_row(connection, report_id)

    def release_report_claim(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        owner: str,
        *,
        error: Optional[str] = None,
    ) -> ReportRecord:
        owner = _required("owner", owner)
        with self._transaction() as connection:
            report = self._require_report(
                connection, operation_id, generation, report_id, current=False
            )
            if report.claim_owner not in {None, owner}:
                raise LifecycleConflict(
                    f"report {report_id!r} is claimed by another submitter"
                )
            now = self._clock()
            connection.execute(
                """UPDATE reports SET claim_owner = NULL, claim_expires_at = NULL,
                       updated_at = ?, last_error = ? WHERE report_id = ?""",
                (now, error, report_id),
            )
            return self._report_row(connection, report_id)

    def mark_report_submitted(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        submission_id: str,
        *,
        claim_owner: Optional[str] = None,
    ) -> ReportRecord:
        submission_id = _required("submission_id", submission_id)
        with self._transaction() as connection:
            report = self._require_report(
                connection, operation_id, generation, report_id, current=False
            )
            if claim_owner is not None and report.claim_owner != claim_owner:
                raise LifecycleConflict(
                    f"report {report_id!r} submission claim is not owned by {claim_owner!r}"
                )
            if report.status in {ReportStatus.SUBMITTED, ReportStatus.ACKNOWLEDGED}:
                if report.submission_id != submission_id:
                    raise LifecycleConflict(
                        f"report {report_id!r} already has submission {report.submission_id!r}"
                    )
                return report
            now = self._clock()
            connection.execute(
                """UPDATE reports SET status = 'submitted', attempts = attempts + 1,
                       submission_id = ?, submitted_at = ?, updated_at = ?,
                       last_error = NULL, claim_owner = NULL, claim_expires_at = NULL
                   WHERE report_id = ?""",
                (submission_id, now, now, report_id),
            )
            return self._report_row(connection, report_id)

    def acknowledge_report(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        acknowledgment: str,
    ) -> ReportRecord:
        acknowledgment = _required("acknowledgment", acknowledgment)
        with self._transaction() as connection:
            report = self._require_report(
                connection, operation_id, generation, report_id, current=False
            )
            if report.status == ReportStatus.ACKNOWLEDGED:
                if report.acknowledgment != acknowledgment:
                    raise LifecycleConflict(
                        f"report {report_id!r} already has different acknowledgment evidence"
                    )
                return report
            if report.status != ReportStatus.SUBMITTED:
                raise LifecycleConflict(
                    f"report {report_id!r} must be submitted before acknowledgment"
                )
            now = self._clock()
            connection.execute(
                """UPDATE reports SET status = 'acknowledged', acknowledgment = ?,
                       acknowledged_at = ?, updated_at = ?, last_error = NULL,
                       claim_owner = NULL, claim_expires_at = NULL
                   WHERE report_id = ?""",
                (acknowledgment, now, now, report_id),
            )
            return self._report_row(connection, report_id)

    def record_report_failure(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        error: str,
        *,
        claim_owner: Optional[str] = None,
    ) -> ReportRecord:
        error = _required("error", error)
        with self._transaction() as connection:
            report = self._require_report(
                connection, operation_id, generation, report_id, current=False
            )
            if report.status == ReportStatus.ACKNOWLEDGED:
                raise LifecycleConflict(f"report {report_id!r} is already acknowledged")
            if claim_owner is not None and report.claim_owner not in {None, claim_owner}:
                raise LifecycleConflict(
                    f"report {report_id!r} submission claim is not owned by {claim_owner!r}"
                )
            now = self._clock()
            connection.execute(
                """UPDATE reports SET status = 'pending', attempts = attempts + 1,
                       submission_id = NULL, submitted_at = NULL, updated_at = ?,
                       last_error = ?, claim_owner = NULL, claim_expires_at = NULL
                   WHERE report_id = ?""",
                (now, error, report_id),
            )
            return self._report_row(connection, report_id)

    def acquire_retention(
        self,
        operation_id: str,
        generation: int,
        lease_id: str,
        holder: str,
        reason: str,
        *,
        expires_at: float,
    ) -> RetentionLease:
        lease_id = _required("lease_id", lease_id)
        holder = _required("holder", holder)
        reason = _required("reason", reason)
        now = self._clock()
        if not math.isfinite(expires_at) or expires_at <= now:
            raise ValueError("expires_at must be finite and in the future")
        if expires_at - now > 7 * 24 * 60 * 60:
            raise ValueError("retention lease may not exceed seven days")
        with self._transaction() as connection:
            operation = _operation(
                self._require_current(connection, operation_id, generation)
            )
            if operation.state in {
                OperationState.CLOSED,
                OperationState.MISSING,
                OperationState.RETIRING,
            }:
                raise LifecycleConflict(
                    f"cannot retain operation in state {operation.state.value}"
                )
            prior = connection.execute(
                "SELECT * FROM retention_leases WHERE lease_id = ?", (lease_id,)
            ).fetchone()
            if prior is not None:
                lease = _lease(prior)
                if (
                    lease.operation_id != operation_id
                    or lease.generation != generation
                    or lease.holder != holder
                    or lease.reason != reason
                    or lease.expires_at != expires_at
                ):
                    raise LifecycleConflict(
                        f"lease_id {lease_id!r} was used for a different lease"
                    )
                return lease
            connection.execute(
                """INSERT INTO retention_leases (
                       lease_id, operation_id, generation, holder, reason,
                       acquired_at, expires_at, disposition
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active')""",
                (lease_id, operation_id, generation, holder, reason, now, expires_at),
            )
            return self._lease_row(connection, lease_id)

    def release_retention(
        self,
        operation_id: str,
        generation: int,
        lease_id: str,
        evidence: str,
    ) -> RetentionLease:
        evidence = _required("evidence", evidence)
        with self._transaction() as connection:
            self._require_current(connection, operation_id, generation)
            lease = self._require_lease(connection, operation_id, generation, lease_id)
            if lease.disposition != LeaseDisposition.ACTIVE:
                if (
                    lease.disposition == LeaseDisposition.RELEASED
                    and lease.evidence == evidence
                ):
                    return lease
                raise LifecycleConflict(
                    f"lease {lease_id!r} is already {lease.disposition.value}"
                )
            now = self._clock()
            connection.execute(
                """UPDATE retention_leases SET disposition = 'released',
                       disposed_at = ?, evidence = ? WHERE lease_id = ?""",
                (now, evidence, lease_id),
            )
            return self._lease_row(connection, lease_id)

    def expire_retention_leases(self, *, at: Optional[float] = None) -> int:
        now = self._clock() if at is None else at
        with self._transaction() as connection:
            cursor = connection.execute(
                """UPDATE retention_leases SET disposition = 'expired',
                       disposed_at = ?, evidence = 'lease deadline elapsed'
                   WHERE disposition = 'active' AND expires_at <= ?""",
                (now, now),
            )
            return cursor.rowcount

    def list_retention(
        self,
        operation_id: str,
        generation: int,
        *,
        active_only: bool = False,
        at: Optional[float] = None,
    ) -> list[RetentionLease]:
        now = self._clock() if at is None else at
        sql = """SELECT * FROM retention_leases
                 WHERE operation_id = ? AND generation = ?"""
        parameters: list[Any] = [operation_id, generation]
        if active_only:
            sql += " AND disposition = 'active' AND expires_at > ?"
            parameters.append(now)
        sql += " ORDER BY acquired_at, lease_id"
        with self._read() as connection:
            return [_lease(row) for row in connection.execute(sql, parameters)]

    def close_eligibility(
        self,
        operation_id: str,
        generation: int,
        *,
        at: Optional[float] = None,
    ) -> CloseEligibility:
        now = self._clock() if at is None else at
        with self._read() as connection:
            row = self._require_current(connection, operation_id, generation)
            return self._close_eligibility(connection, _operation(row), now)

    def request_close(
        self,
        operation_id: str,
        generation: int,
        intent_id: str,
        observed_identity: OperationIdentity,
        *,
        reason: str,
    ) -> CloseIntent:
        intent_id = _required("intent_id", intent_id)
        reason = _required("reason", reason)
        observed_identity = _identity(observed_identity)
        now = self._clock()
        with self._transaction() as connection:
            operation = _operation(
                self._require_current(connection, operation_id, generation)
            )
            prior = connection.execute(
                "SELECT * FROM close_intents WHERE intent_id = ?", (intent_id,)
            ).fetchone()
            if prior is not None:
                intent = _close_intent(prior)
                if (
                    intent.operation_id != operation_id
                    or intent.generation != generation
                    or intent.identity != observed_identity
                    or intent.reason != reason
                ):
                    raise LifecycleConflict(
                        f"intent_id {intent_id!r} was used for a different close intent"
                    )
                return intent
            if operation.identity != observed_identity:
                raise LifecycleConflict(
                    "observed pane identity does not match the registered operation owner"
                )
            connection.execute(
                """UPDATE retention_leases SET disposition = 'expired',
                       disposed_at = ?, evidence = 'lease deadline elapsed'
                   WHERE operation_id = ? AND generation = ?
                     AND disposition = 'active' AND expires_at <= ?""",
                (now, operation_id, generation, now),
            )
            eligibility = self._close_eligibility(connection, operation, now)
            if not eligibility.eligible:
                raise CloseNotEligible(eligibility)
            connection.execute(
                """INSERT INTO close_intents (
                       intent_id, operation_id, generation, board, repo, workspace,
                       tab, root_pane, terminal, session, requested_at, reason,
                       disposition
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending')""",
                (
                    intent_id,
                    operation_id,
                    generation,
                    observed_identity.board,
                    observed_identity.repo,
                    observed_identity.workspace,
                    observed_identity.tab,
                    observed_identity.root_pane,
                    observed_identity.terminal,
                    observed_identity.session,
                    now,
                    reason,
                ),
            )
            if operation.state == OperationState.COMPLETED:
                connection.execute(
                    """UPDATE operations SET state = 'retiring', updated_at = ?,
                           state_evidence = ? WHERE operation_id = ? AND generation = ?""",
                    (now, f"close intent {intent_id}", operation_id, generation),
                )
                connection.execute(
                    """INSERT INTO transitions (
                           transition_id, operation_id, generation, from_state,
                           to_state, evidence, occurred_at
                       ) VALUES (?, ?, ?, 'completed', 'retiring', ?, ?)""",
                    (
                        f"close:{intent_id}",
                        operation_id,
                        generation,
                        f"close intent {intent_id}",
                        now,
                    ),
                )
            return self._close_intent_row(connection, intent_id)

    def record_close_disposition(
        self,
        operation_id: str,
        generation: int,
        intent_id: str,
        disposition: CloseDisposition,
        evidence: str,
    ) -> CloseIntent:
        disposition = CloseDisposition(disposition)
        if disposition == CloseDisposition.PENDING:
            raise ValueError("a close disposition cannot be pending")
        evidence = _required("evidence", evidence)
        now = self._clock()
        with self._transaction() as connection:
            operation = _operation(
                self._require_current(connection, operation_id, generation)
            )
            intent = self._require_close_intent(
                connection, operation_id, generation, intent_id
            )
            if intent.disposition != CloseDisposition.PENDING:
                if intent.disposition == disposition and intent.evidence == evidence:
                    return intent
                raise LifecycleConflict(
                    f"close intent {intent_id!r} is already {intent.disposition.value}"
                )
            connection.execute(
                """UPDATE close_intents SET disposition = ?, disposed_at = ?, evidence = ?
                   WHERE intent_id = ?""",
                (disposition.value, now, evidence, intent_id),
            )
            target: Optional[OperationState] = None
            if disposition == CloseDisposition.CLOSED:
                target = OperationState.CLOSED
            elif disposition == CloseDisposition.MISSING:
                target = OperationState.MISSING
            if target is not None and operation.state != target:
                if target not in _ALLOWED_TRANSITIONS[operation.state]:
                    raise InvalidTransition(
                        f"cannot record {disposition.value} from {operation.state.value}"
                    )
                connection.execute(
                    """UPDATE operations SET state = ?, updated_at = ?, state_evidence = ?
                       WHERE operation_id = ? AND generation = ?""",
                    (target.value, now, evidence, operation_id, generation),
                )
                connection.execute(
                    """INSERT INTO transitions (
                           transition_id, operation_id, generation, from_state,
                           to_state, evidence, occurred_at
                       ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (
                        f"dispose:{intent_id}",
                        operation_id,
                        generation,
                        operation.state.value,
                        target.value,
                        evidence,
                        now,
                    ),
                )
            return self._close_intent_row(connection, intent_id)

    def list_close_intents(
        self,
        operation_id: str,
        generation: int,
    ) -> list[CloseIntent]:
        with self._read() as connection:
            return [
                _close_intent(row)
                for row in connection.execute(
                    """SELECT * FROM close_intents
                       WHERE operation_id = ? AND generation = ?
                       ORDER BY requested_at, intent_id""",
                    (operation_id, generation),
                )
            ]

    def _close_eligibility(
        self,
        connection: sqlite3.Connection,
        operation: OperationRecord,
        now: float,
    ) -> CloseEligibility:
        if operation.state not in {OperationState.COMPLETED, OperationState.RETIRING}:
            return CloseEligibility(
                False,
                f"operation state is {operation.state.value}, not completed or retiring",
                operation,
            )
        active_lease = connection.execute(
            """SELECT 1 FROM retention_leases
               WHERE operation_id = ? AND generation = ? AND disposition = 'active'
                 AND expires_at > ? LIMIT 1""",
            (operation.operation_id, operation.generation, now),
        ).fetchone()
        if active_lease is not None:
            return CloseEligibility(False, "operation has an active retention lease", operation)
        final_count, unacknowledged = connection.execute(
            """SELECT COUNT(*),
                      SUM(CASE WHEN status != 'acknowledged' THEN 1 ELSE 0 END)
               FROM reports
               WHERE operation_id = ? AND generation = ? AND is_final = 1""",
            (operation.operation_id, operation.generation),
        ).fetchone()
        if final_count == 0:
            return CloseEligibility(False, "operation has no durable final report", operation)
        if unacknowledged:
            return CloseEligibility(False, "operation has an unacknowledged final report", operation)
        pending_intent = connection.execute(
            """SELECT 1 FROM close_intents
               WHERE operation_id = ? AND generation = ? AND disposition = 'pending'
               LIMIT 1""",
            (operation.operation_id, operation.generation),
        ).fetchone()
        if pending_intent is not None:
            return CloseEligibility(False, "operation already has a pending close intent", operation)
        return CloseEligibility(True, "eligible", operation)

    def _current_row(
        self, connection: sqlite3.Connection, operation_id: str
    ) -> Optional[sqlite3.Row]:
        return connection.execute(
            """SELECT * FROM operations WHERE operation_id = ?
               ORDER BY generation DESC LIMIT 1""",
            (operation_id,),
        ).fetchone()

    def _require_current(
        self, connection: sqlite3.Connection, operation_id: str, generation: int
    ) -> sqlite3.Row:
        operation_id = _required("operation_id", operation_id)
        generation = _generation(generation)
        current = self._current_row(connection, operation_id)
        if current is None:
            raise OperationNotFound(operation_id)
        current_generation = int(current["generation"])
        if generation < current_generation:
            raise StaleGeneration(operation_id, generation, current_generation)
        if generation > current_generation:
            raise OperationNotFound(f"{operation_id!r} generation {generation}")
        return current

    def _get_row(
        self, connection: sqlite3.Connection, operation_id: str, generation: int
    ) -> OperationRecord:
        row = connection.execute(
            "SELECT * FROM operations WHERE operation_id = ? AND generation = ?",
            (operation_id, generation),
        ).fetchone()
        if row is None:
            current = self._current_row(connection, operation_id)
            if current is not None and generation < int(current["generation"]):
                raise StaleGeneration(operation_id, generation, int(current["generation"]))
            raise OperationNotFound(f"{operation_id!r} generation {generation}")
        return _operation(row)

    def _report_row(
        self, connection: sqlite3.Connection, report_id: str
    ) -> ReportRecord:
        row = connection.execute(
            "SELECT * FROM reports WHERE report_id = ?", (report_id,)
        ).fetchone()
        if row is None:
            raise OperationNotFound(f"report {report_id!r}")
        return _report(row)

    def _require_report(
        self,
        connection: sqlite3.Connection,
        operation_id: str,
        generation: int,
        report_id: str,
        *,
        current: bool,
    ) -> ReportRecord:
        operation_id = _required("operation_id", operation_id)
        generation = _generation(generation)
        report_id = _required("report_id", report_id)
        if current:
            self._require_current(connection, operation_id, generation)
        report = self._report_row(connection, report_id)
        if report.operation_id != operation_id or report.generation != generation:
            raise LifecycleConflict(f"report {report_id!r} belongs to another operation")
        return report

    def _lease_row(
        self, connection: sqlite3.Connection, lease_id: str
    ) -> RetentionLease:
        row = connection.execute(
            "SELECT * FROM retention_leases WHERE lease_id = ?", (lease_id,)
        ).fetchone()
        if row is None:
            raise OperationNotFound(f"retention lease {lease_id!r}")
        return _lease(row)

    def _require_lease(
        self,
        connection: sqlite3.Connection,
        operation_id: str,
        generation: int,
        lease_id: str,
    ) -> RetentionLease:
        lease = self._lease_row(connection, _required("lease_id", lease_id))
        if lease.operation_id != operation_id or lease.generation != generation:
            raise LifecycleConflict(f"lease {lease_id!r} belongs to another operation")
        return lease

    def _close_intent_row(
        self, connection: sqlite3.Connection, intent_id: str
    ) -> CloseIntent:
        row = connection.execute(
            "SELECT * FROM close_intents WHERE intent_id = ?", (intent_id,)
        ).fetchone()
        if row is None:
            raise OperationNotFound(f"close intent {intent_id!r}")
        return _close_intent(row)

    def _require_close_intent(
        self,
        connection: sqlite3.Connection,
        operation_id: str,
        generation: int,
        intent_id: str,
    ) -> CloseIntent:
        intent = self._close_intent_row(
            connection, _required("intent_id", intent_id)
        )
        if intent.operation_id != operation_id or intent.generation != generation:
            raise LifecycleConflict(f"close intent {intent_id!r} belongs to another operation")
        return intent


    def _launch_intent_row(
        self, connection: sqlite3.Connection, intent_id: str
    ) -> LaunchIntent:
        row = connection.execute(
            "SELECT * FROM launch_intents WHERE intent_id = ?", (intent_id,)
        ).fetchone()
        if row is None:
            raise OperationNotFound(f"launch intent {intent_id!r}")
        return _launch_intent(row)

def _required(name: str, value: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value


def _generation(value: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError("generation must be a non-negative integer")
    return value


def _identity(value: OperationIdentity) -> OperationIdentity:
    if not isinstance(value, OperationIdentity):
        raise TypeError("identity must be an OperationIdentity")
    return OperationIdentity(
        board=_required("identity.board", value.board),
        repo=_required("identity.repo", value.repo),
        workspace=_required("identity.workspace", value.workspace),
        tab=_required("identity.tab", value.tab),
        root_pane=_required("identity.root_pane", value.root_pane),
        terminal=_required("identity.terminal", value.terminal),
        session=_required("identity.session", value.session),
    )


def _operation(row: sqlite3.Row) -> OperationRecord:
    return OperationRecord(
        operation_id=row["operation_id"],
        generation=int(row["generation"]),
        state=OperationState(row["state"]),
        identity=OperationIdentity(
            board=row["board"],
            repo=row["repo"],
            workspace=row["workspace"],
            tab=row["tab"],
            root_pane=row["root_pane"],
            terminal=row["terminal"],
            session=row["session"],
        ),
        registered_at=float(row["registered_at"]),
        updated_at=float(row["updated_at"]),
        state_evidence=row["state_evidence"],
    )
def _launch_intent(row: sqlite3.Row) -> LaunchIntent:
    return LaunchIntent(
        intent_id=row["intent_id"],
        operation_id=row["operation_id"],
        generation=int(row["generation"]),
        kind=row["kind"],
        idempotency_key=row["idempotency_key"],
        payload=row["payload"],
        status=LaunchIntentStatus(row["status"]),
        outcome=row["outcome"],
        evidence=row["evidence"],
        created_at=float(row["created_at"]),
        updated_at=float(row["updated_at"]),
    )


def _report(row: sqlite3.Row) -> ReportRecord:
    return ReportRecord(
        report_id=row["report_id"],
        operation_id=row["operation_id"],
        generation=int(row["generation"]),
        board=row["board"],
        recipient=row["recipient"],
        body=row["body"],
        digest=row["digest"],
        is_final=bool(row["is_final"]),
        status=ReportStatus(row["status"]),
        attempts=int(row["attempts"]),
        created_at=float(row["created_at"]),
        updated_at=float(row["updated_at"]),
        submission_id=row["submission_id"],
        submitted_at=_optional_float(row["submitted_at"]),
        acknowledged_at=_optional_float(row["acknowledged_at"]),
        acknowledgment=row["acknowledgment"],
        last_error=row["last_error"],
        claim_owner=row["claim_owner"],
        claim_expires_at=_optional_float(row["claim_expires_at"]),
    )


def _lease(row: sqlite3.Row) -> RetentionLease:
    return RetentionLease(
        lease_id=row["lease_id"],
        operation_id=row["operation_id"],
        generation=int(row["generation"]),
        holder=row["holder"],
        reason=row["reason"],
        acquired_at=float(row["acquired_at"]),
        expires_at=float(row["expires_at"]),
        disposition=LeaseDisposition(row["disposition"]),
        disposed_at=_optional_float(row["disposed_at"]),
        evidence=row["evidence"],
    )


def _close_intent(row: sqlite3.Row) -> CloseIntent:
    return CloseIntent(
        intent_id=row["intent_id"],
        operation_id=row["operation_id"],
        generation=int(row["generation"]),
        identity=OperationIdentity(
            board=row["board"],
            repo=row["repo"],
            workspace=row["workspace"],
            tab=row["tab"],
            root_pane=row["root_pane"],
            terminal=row["terminal"],
            session=row["session"],
        ),
        requested_at=float(row["requested_at"]),
        reason=row["reason"],
        disposition=CloseDisposition(row["disposition"]),
        disposed_at=_optional_float(row["disposed_at"]),
        evidence=row["evidence"],
    )


def _report_digest(body: str, expected: Optional[str]) -> str:
    if not isinstance(body, str):
        raise TypeError("body must be a string")
    computed = hashlib.sha256(body.encode("utf-8")).hexdigest()
    if expected is not None and expected != computed:
        raise ValueError("digest does not match the SHA-256 digest of body")
    return computed


def _optional_float(value: Any) -> Optional[float]:
    return None if value is None else float(value)


def _transition_digest(
    operation_id: str,
    generation: int,
    source: OperationState,
    target: OperationState,
    occurred_at: float,
) -> str:
    payload: Mapping[str, Any] = {
        "operation_id": operation_id,
        "generation": generation,
        "from": source.value,
        "to": target.value,
        "occurred_at": occurred_at,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return "auto:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


__all__ = [
    "CloseDisposition",
    "CloseEligibility",
    "CloseIntent",
    "CloseNotEligible",
    "InvalidTransition",
    "LeaseDisposition",
    "LifecycleConflict",
    "OperationIdentity",
    "OperationNotFound",
    "OperationRecord",
    "OperationState",
    "OperationStore",
    "OperationStoreError",
    "ReportRecord",
    "ReportStatus",
    "RetentionLease",
    "StaleGeneration",
]
