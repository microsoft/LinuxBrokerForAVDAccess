"""Reuse SQL connections within a Broker API worker process.

Opening a connection to Azure SQL costs a TCP and TLS handshake and a login, and on App
Service every closed connection also holds one of the instance's outbound SNAT ports for
four minutes. The pool keeps the connections a worker process has finished with for its
next request.

A connection is only reused in a clean state. When it comes back it is rolled back, so
no uncommitted work or lock outlives the request, and it waits in the pool with no
transaction open. It begins a new transaction only as it is handed out again, which also
proves it still answers, so the transaction starts when the request does; see _reset
for why that matters. Nothing else the API does outlives a transaction on its
connection: application locks are owned by the transaction, and the API sets no session
options, temporary tables or session context. Keep it that way, or set
DB_POOL_ENABLED=false.

db_connection() still bounds how many connections a process holds. A connection is
opened only by a thread holding one of its slots, and is back in the pool or closed
before that slot is released, so idle and busy connections together stay within
DB_MAX_CONCURRENCY.
"""

import logging
import os
import threading
import time
from dataclasses import dataclass

# A child of the logger the API sends to Application Insights.
logger = logging.getLogger('linuxbroker.api.db_pool')


@dataclass
class PooledConnection:
    """A connection handed out by the pool, with what the pool needs to take it back."""

    connection: object
    opened_at: float
    pid: int
    returned_at: float = 0.0


class ConnectionPool:
    """Idle connections of one process, the most recently returned reused first.

    Reusing the most recent keeps the rest idle, so when load drops they reach the idle
    limit and are closed rather than kept open for nobody.
    """

    def __init__(self, max_idle, idle_seconds, max_lifetime_seconds,
                 clock=time.monotonic, getpid=os.getpid):
        self.max_idle = max_idle
        self.idle_seconds = idle_seconds
        self.max_lifetime_seconds = max_lifetime_seconds
        self._clock = clock
        self._getpid = getpid
        self._lock = threading.Lock()
        self._idle = []
        self._pid = getpid()
        # Connections a forked process inherited from its parent. They share the
        # parent's sockets, so this process neither uses nor closes them, and the
        # reference keeps garbage collection from closing them either.
        self._inherited = []

    @property
    def idle_count(self):
        with self._lock:
            return len(self._idle)

    def acquire(self, connect):
        """Hand out an idle connection that still answers, or a new one from connect().

        Returns None when connect() does.
        """
        while True:
            pooled, expired = self._take_idle()
            for stale in expired:
                self._close(stale.connection)
            if pooled is None:
                break
            if self._begin(pooled.connection):
                return pooled
            logger.warning("A pooled database connection stopped answering. It was closed "
                           "and another connection is being used.")
            self._close(pooled.connection)

        connection = connect()
        if connection is None:
            return None
        return PooledConnection(connection, opened_at=self._clock(), pid=self._getpid())

    def release(self, pooled, reusable=True):
        """Take a connection back, or close it when it cannot be reused."""
        if pooled.pid != self._getpid():
            # Opened before this process was forked, so it belongs to the parent.
            with self._lock:
                self._inherited.append(pooled)
            return

        if reusable and self._reset(pooled.connection):
            now = self._clock()
            with self._lock:
                if (pooled.pid == self._pid and len(self._idle) < self.max_idle
                        and not self._too_old(pooled, now)):
                    pooled.returned_at = now
                    self._idle.append(pooled)
                    return
        self._close(pooled.connection)

    def close_idle(self):
        """Close every idle connection."""
        with self._lock:
            idle, self._idle = self._idle, []
        for pooled in idle:
            self._close(pooled.connection)

    def _take_idle(self):
        now = self._clock()
        with self._lock:
            pid = self._getpid()
            if pid != self._pid:
                self._inherited.extend(self._idle)
                self._idle = []
                self._pid = pid
            expired = [pooled for pooled in self._idle if self._expired(pooled, now)]
            if expired:
                self._idle = [pooled for pooled in self._idle if not self._expired(pooled, now)]
            pooled = self._idle.pop() if self._idle else None
        return pooled, expired

    def _expired(self, pooled, now):
        return now - pooled.returned_at >= self.idle_seconds or self._too_old(pooled, now)

    def _too_old(self, pooled, now):
        return now - pooled.opened_at >= self.max_lifetime_seconds

    @staticmethod
    def _begin(connection):
        # pymssql begins a transaction when autocommit is turned off, as it does when a
        # connection opens. The request's transaction therefore starts now, not when the
        # connection went idle; see _reset. The round trip also shows the connection
        # still answers.
        try:
            connection.autocommit(False)
            return True
        except Exception:
            return False

    @staticmethod
    def _reset(connection):
        # Rolls back whatever the request left uncommitted, releasing its locks, and ends
        # the transaction pymssql otherwise keeps open. System-versioned tables stamp each
        # change with its transaction's start time, and SQL Server refuses a change stamped
        # earlier than the row's current version (error 13535). A transaction begun when
        # the connection went idle would be older than every change made meanwhile.
        try:
            connection.autocommit(True)
            return True
        except Exception:
            pass
        try:
            # The transaction was already gone, as after an error that aborts the batch, so
            # its rollback failed. rollback() tolerates that and begins a new one to end.
            connection.rollback()
            connection.autocommit(True)
            return True
        except Exception as error:
            logger.info("A database connection could not be rolled back, so it was closed: %s", error)
            return False

    @staticmethod
    def _close(connection):
        try:
            connection.close()
        except Exception:
            logger.debug("Closing a database connection failed.", exc_info=True)
