"""The per-process SQL connection pool behind db_connection()."""

import logging
import threading
import types

import pytest

from db_pool import ConnectionPool


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class Connection:
    """Records what the pool does with a connection, as pymssql would see it."""

    def __init__(self, opener, name):
        self.opener = opener
        self.name = name
        self.begins = 0  # autocommit(False): BEGIN TRAN
        self.ends = 0  # autocommit(True): ROLLBACK TRAN
        self.rollbacks = 0
        self.transaction_open = True  # pymssql begins one as the connection opens
        self.closed = False
        self.dead = False

    def autocommit(self, status):
        if self.dead:
            raise RuntimeError("DBPROCESS is dead or not enabled")
        if status:
            if not self.transaction_open:
                raise RuntimeError("The ROLLBACK TRANSACTION request has no corresponding BEGIN TRANSACTION.")
            self.ends += 1
            self.transaction_open = False
        else:
            self.begins += 1
            self.transaction_open = True

    def rollback(self):
        # pymssql ignores a rollback with no transaction to roll back, then begins one.
        if self.dead:
            raise RuntimeError("DBPROCESS is dead or not enabled")
        self.rollbacks += 1
        self.transaction_open = True

    def close(self):
        if not self.closed:
            self.closed = True
            self.opener.closed_one()


class Opener:
    """Stands in for get_db_connection and tracks how many connections are open at once."""

    def __init__(self):
        self.opened = []
        self.open_now = 0
        self.most_open = 0
        self._lock = threading.Lock()

    def __call__(self):
        with self._lock:
            connection = Connection(self, f"connection-{len(self.opened) + 1}")
            self.opened.append(connection)
            self.open_now += 1
            self.most_open = max(self.most_open, self.open_now)
        return connection

    def closed_one(self):
        with self._lock:
            self.open_now -= 1


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def opener():
    return Opener()


@pytest.fixture
def pool(clock):
    return ConnectionPool(max_idle=3, idle_seconds=120, max_lifetime_seconds=1800, clock=clock)


# ================================================================== reuse


def test_a_returned_connection_waits_with_no_transaction_and_begins_one_when_reused(pool, opener):
    first = pool.acquire(opener)
    pool.release(first)

    # Rolled back, and no transaction left open while it waits.
    assert first.connection.ends == 1
    assert not first.connection.transaction_open

    again = pool.acquire(opener)

    assert again.connection is first.connection
    assert len(opener.opened) == 1
    # The request's transaction begins as it is handed out, never while it waited.
    assert first.connection.begins == 1
    assert first.connection.transaction_open
    assert not first.connection.closed


def test_the_most_recently_returned_connection_is_reused_first(pool, opener):
    older, newer = pool.acquire(opener), pool.acquire(opener)
    pool.release(older)
    pool.release(newer)

    assert pool.acquire(opener).connection is newer.connection


def test_no_connection_is_handed_out_when_none_can_be_opened(pool):
    assert pool.acquire(lambda: None) is None


def test_no_more_than_max_idle_connections_are_kept(pool, opener):
    busy = [pool.acquire(opener) for _ in range(4)]
    for pooled in busy:
        pool.release(pooled)

    assert pool.idle_count == 3
    assert [pooled.connection.closed for pooled in busy] == [False, False, False, True]


def test_close_idle_closes_every_idle_connection(pool, opener):
    busy = [pool.acquire(opener) for _ in range(2)]
    for pooled in busy:
        pool.release(pooled)

    pool.close_idle()

    assert pool.idle_count == 0
    assert all(pooled.connection.closed for pooled in busy)


# ========================================================= discarding


def test_a_connection_whose_block_failed_is_closed_rather_than_reused(pool, opener):
    first = pool.acquire(opener)

    pool.release(first, reusable=False)

    assert first.connection.closed
    assert first.connection.ends == 0
    assert pool.acquire(opener).connection is not first.connection


def test_a_connection_that_cannot_roll_back_is_closed(pool, opener):
    first = pool.acquire(opener)
    first.connection.dead = True

    pool.release(first)

    assert first.connection.closed
    assert pool.idle_count == 0


def test_a_connection_whose_transaction_was_already_rolled_back_is_kept(pool, opener):
    first = pool.acquire(opener)
    # An error that aborts the batch rolls the transaction back on the server.
    first.connection.transaction_open = False

    pool.release(first)

    assert not first.connection.closed
    assert first.connection.rollbacks == 1
    assert not first.connection.transaction_open
    assert pool.idle_count == 1


def test_a_connection_that_stopped_answering_is_replaced_without_failing_the_request(pool, opener, caplog):
    first = pool.acquire(opener)
    pool.release(first)
    first.connection.dead = True  # a failover or a gateway restart while it sat idle

    with caplog.at_level(logging.WARNING, logger="linuxbroker.api.db_pool"):
        replacement = pool.acquire(opener)

    assert replacement.connection is opener.opened[1]
    assert first.connection.closed
    assert "stopped answering" in caplog.text


# ============================================================ time limits


def test_idle_connections_are_closed_before_the_outbound_load_balancer_forgets_them(pool, opener, clock):
    first = pool.acquire(opener)
    pool.release(first)
    clock.advance(119)
    reused = pool.acquire(opener)
    assert reused.connection is first.connection
    pool.release(reused)

    clock.advance(120)
    replacement = pool.acquire(opener)

    assert replacement.connection is not first.connection
    assert first.connection.closed
    # It was closed without being tried: an idle connection past the limit may no longer answer at all.
    assert first.connection.begins == 1


def test_an_idle_connection_past_its_lifetime_is_not_reused(pool, opener, clock):
    first = pool.acquire(opener)
    clock.advance(1750)  # one long request
    pool.release(first)
    assert pool.idle_count == 1

    clock.advance(60)  # idle for only a minute, but 1810 seconds old
    replacement = pool.acquire(opener)

    assert replacement.connection is not first.connection
    assert first.connection.closed


def test_a_connection_past_its_lifetime_is_closed_when_it_comes_back(pool, opener, clock):
    first = pool.acquire(opener)
    clock.advance(1800)

    pool.release(first)

    assert first.connection.closed
    assert pool.idle_count == 0


# ================================================================ forking


def forked_pool(clock):
    process = {"pid": 100}
    return ConnectionPool(max_idle=3, idle_seconds=120, max_lifetime_seconds=1800, clock=clock,
                          getpid=lambda: process["pid"]), process


def test_a_forked_process_leaves_its_parents_idle_connections_alone(clock, opener):
    pool, process = forked_pool(clock)
    parents = pool.acquire(opener)
    pool.release(parents)

    process["pid"] = 200  # gunicorn --preload forked a worker after the pool was used
    childs = pool.acquire(opener)

    assert childs.connection is not parents.connection
    # The parent's connection shares its socket: never tried, never closed.
    assert parents.connection.begins == 0
    assert not parents.connection.closed

    pool.release(childs)
    assert pool.acquire(opener).connection is childs.connection


def test_a_connection_opened_before_a_fork_is_neither_pooled_nor_closed_after_it(clock, opener):
    pool, process = forked_pool(clock)
    parents = pool.acquire(opener)

    process["pid"] = 200
    pool.release(parents)

    assert not parents.connection.closed
    assert pool.idle_count == 0


# ======================================================== db_connection()


@pytest.fixture
def pooled_api(app_module, monkeypatch, clock):
    opener = Opener()
    pool = ConnectionPool(max_idle=2, idle_seconds=120, max_lifetime_seconds=1800, clock=clock)
    slots = threading.BoundedSemaphore(2)
    monkeypatch.setattr(app_module, "_db_pool", pool)
    monkeypatch.setattr(app_module, "_db_slots", slots)
    monkeypatch.setattr(app_module, "get_db_connection", opener)
    return types.SimpleNamespace(pool=pool, opener=opener, slots=slots)


def slots_free(slots, count):
    taken = [slots.acquire(timeout=0) for _ in range(count)]
    for ok in taken:
        if ok:
            slots.release()
    return all(taken)


def test_db_connection_reuses_one_connection_across_blocks(app_module, pooled_api):
    with app_module.db_connection() as first:
        pass
    with app_module.db_connection() as second:
        pass

    assert second is first
    assert len(pooled_api.opener.opened) == 1
    assert slots_free(pooled_api.slots, 2)


def test_db_connection_closes_the_connection_when_its_block_raises(app_module, pooled_api):
    with pytest.raises(RuntimeError, match="boom"):
        with app_module.db_connection() as conn:
            raise RuntimeError("boom")

    assert conn.closed
    assert pooled_api.pool.idle_count == 0
    assert slots_free(pooled_api.slots, 2)


def test_db_connection_frees_its_slot_when_sql_is_unreachable(app_module, pooled_api, monkeypatch):
    monkeypatch.setattr(app_module, "get_db_connection", lambda: None)

    with pytest.raises(app_module.DatabaseUnavailable):
        with app_module.db_connection():
            pass

    assert slots_free(pooled_api.slots, 2)


def test_idle_and_busy_connections_stay_within_the_slot_count(app_module, pooled_api):
    errors = []

    def work():
        try:
            for _ in range(50):
                with app_module.db_connection() as conn:
                    assert not conn.closed
        except Exception as error:  # pragma: no cover - reported below
            errors.append(error)

    threads = [threading.Thread(target=work) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    assert pooled_api.opener.most_open <= 2
    assert slots_free(pooled_api.slots, 2)


def test_requests_share_pooled_connections(app_module, client, fake_db, monkeypatch):
    monkeypatch.setattr(app_module, "_db_pool", ConnectionPool(max_idle=2, idle_seconds=120,
                                                               max_lifetime_seconds=1800))

    assert client.get("/api/vms").status_code == 200
    assert client.get("/api/vms").status_code == 200

    assert len(fake_db.connections) == 1
    # Ended after the first request, begun for the second, ended after it.
    assert fake_db.connections[0].autocommit_calls == [True, False, True]
    assert not fake_db.connections[0].closed


def test_the_pool_can_be_turned_off(app_module, client, fake_db):
    # The unit tests run with DB_POOL_ENABLED=false, as an operator can.
    assert app_module._db_pool is None

    client.get("/api/vms")
    client.get("/api/vms")

    assert len(fake_db.connections) == 2
    assert all(connection.closed for connection in fake_db.connections)
