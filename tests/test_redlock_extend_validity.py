# --------------------------------------------------------------------------- #
#   test_redlock_extend_validity.py                                           #
#                                                                             #
#   Licensed under the Apache License, Version 2.0 (the "License");           #
#   you may not use this file except in compliance with the License.          #
#   You may obtain a copy of the License at:                                  #
#       http://www.apache.org/licenses/LICENSE-2.0                            #
#                                                                             #
#   Unless required by applicable law or agreed to in writing, software       #
#   distributed under the License is distributed on an "AS IS" BASIS,         #
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  #
#   See the License for the specific language governing permissions and       #
#   limitations under the License.                                            #
# --------------------------------------------------------------------------- #
'''Characterization and expected-behaviour tests for Redlock.extend().

Source of these tests (G2 triage, specs/quint/TRIAGE.md, all four `real`):

  * specs/quint/traces/as_is_extend_success_without_validity.itf.json
  * specs/quint/traces/as_is_even_extend_success_without_validity.itf.json
  * specs/quint/traces/as_is_slow_extend_success_without_validity.itf.json
  * specs/quint/traces/as_is_late_extend_no_compensation.itf.json

Rule under test (specs/quint/RULES.md INV-6, confirmed in G1 A3):

    extend succeeds only when a strict majority of masters PEXPIRE the token
    AND, at completion, auto_release_time - drift - elapsed_since_extend_start
    is still positive.  Otherwise every node that still holds the token is
    compensated with a token-checked release, and ExtendUnlockedLock is raised.

Current code (pottery/redlock.py:503-553) only counts PEXPIRE successes: it
starts no timer, performs no completion-time check, and does not compensate.
The tests below replay the four traces on the real synchronous Redlock code
using an in-memory, logically-clocked master double.  No Redis, database,
network or deployment environment is used.

Each `test_repro_*` test is EXECUTED and green: it asserts the *current wrong*
behaviour.  When extend() is fixed, invert its assertions and unskip the
matching `test_fixed_*` test (which asserts the expected behaviour).
'''


import concurrent.futures
import threading
from typing import Callable
from typing import Iterable
from typing import Literal
from typing import cast

import pytest
from redis import Redis

import pottery.redlock as redlock_module
from pottery import ExtendUnlockedLock
from pottery import Redlock


BuildLock = Callable[..., 'tuple[_FakeCluster, Redlock]']


class _SynchronousExecutor(concurrent.futures.ThreadPoolExecutor):
    '''A BailOutExecutor whose __exit__ waits for every master.

    The real synchronous Redlock returns at quorum and leaves the remaining
    SET/PEXPIRE calls running in background threads (ENV-11).  Waiting for
    them here keeps the replay deterministic; it does not change which calls
    succeed or the quorum outcome.
    '''

    def __exit__(self, *exc_info: object) -> Literal[False]:
        self.shutdown(wait=True)
        return False


class _FakeCluster:
    '''A logically-clocked set of independent in-memory Redis masters.

    `now_ms` is the client's monotonic clock and is only moved explicitly by
    the tests or by the simulated extend latency.  Key expiry is absolute, as
    in the Quint model (specs/quint/model.qnt).
    '''

    def __init__(self, num_masters: int, auto_release_time: float) -> None:
        self.now_ms = 0
        self.extend_op_start_ms: int | None = None
        self.extend_latency_ms = 0
        self._lock = threading.Lock()
        self.masters = [_FakeMaster(self) for _ in range(num_masters)]

    def schedule_extend(self, *, start_ms: int, latency_ms: int) -> None:
        self.now_ms = start_ms
        self.extend_op_start_ms = None
        self.extend_latency_ms = latency_ms

    def begin_extend(self) -> int:
        '''Pin the operation start, before any simulated response latency.'''
        with self._lock:
            if self.extend_op_start_ms is None:
                self.extend_op_start_ms = self.now_ms
            return self.extend_op_start_ms

    def end_extend(self) -> None:
        '''The client observes completion only after the slow responses.'''
        with self._lock:
            assert self.extend_op_start_ms is not None
            self.now_ms = self.extend_op_start_ms + self.extend_latency_ms


class _FakeMaster:
    '''Minimal in-memory stand-in for the Redis operations Redlock uses.'''

    def __init__(self, cluster: _FakeCluster) -> None:
        self.cluster = cluster
        self.store: dict[str, tuple[object, int]] = {}

    def _alive(self, name: str, at_ms: int | None = None) -> bool:
        at_ms = self.cluster.now_ms if at_ms is None else at_ms
        entry = self.store.get(name)
        return entry is not None and entry[1] > at_ms

    def get(self, name: str, at_ms: int | None = None) -> object | None:
        if not self._alive(name, at_ms):
            return None
        return self.store[name][0]

    def set(self, name: str, value: object, *, px: int | None = None,
            nx: bool = False, **kwargs: object) -> bool | None:
        if nx and self._alive(name):
            return None
        assert px is not None
        self.store[name] = (value, self.cluster.now_ms + px)
        return True

    def delete(self, name: str) -> int:
        return 1 if self.store.pop(name, None) is not None else 0

    def remaining_ms(self, name: str) -> int:
        if not self._alive(name):
            return 0
        return self.store[name][1] - self.cluster.now_ms


class _FakeScript:
    '''Stand-in for the three Lua scripts registered by Redlock.

    The extend script places the PEXPIRE effect at the operation start (the
    conservative worst case used by specs/quint/model.qnt) and only reports
    completion after the simulated latency.
    '''

    def __init__(self, kind: str) -> None:
        self.kind = kind

    def __call__(self, *, keys: tuple[str, ...], args: tuple[object, ...],
                 client: _FakeMaster) -> int:
        name = keys[0]
        token = args[0]
        if self.kind == 'acquired':
            if client.get(name) == token:
                return client.remaining_ms(name)
            return 0
        if self.kind == 'extend':
            cluster = client.cluster
            op_start_ms = cluster.begin_extend()
            extended = 0
            if client.get(name, at_ms=op_start_ms) == token:
                # PEXPIRE at operation start (worst-case request latency).
                ttl_ms = args[1]
                assert isinstance(ttl_ms, int)
                client.store[name] = (token, op_start_ms + ttl_ms)
                extended = 1
            cluster.end_extend()
            return extended
        if self.kind == 'release':
            if client.get(name) == token:
                return client.delete(name)
            return 0
        raise AssertionError(f'unknown fake script kind: {self.kind}')


class _ClusterTimer:
    '''ContextTimer replacement backed by the cluster's logical clock.'''

    def __init__(self, cluster: _FakeCluster) -> None:
        self.cluster = cluster
        self._started: int | None = None
        self._stopped: int | None = None

    def __enter__(self) -> '_ClusterTimer':
        self._started = self.cluster.now_ms
        return self

    def __exit__(self, *exc_info: object) -> Literal[False]:
        self._stopped = self.cluster.now_ms
        return False

    def elapsed(self) -> int:
        assert self._started is not None
        stopped = self.cluster.now_ms if self._stopped is None else self._stopped
        return stopped - self._started


@pytest.fixture
def cluster_and_lock(monkeypatch: pytest.MonkeyPatch) -> BuildLock:
    '''Build a Redlock wired to a fresh in-memory cluster.

    Returns (cluster, lock).  The fake Lua scripts and the logical-clock timer
    are patched only for the duration of the test.
    '''
    def build(*, num_masters: int, auto_release_time: float,
              acquire_at_ms: int = 0) -> tuple[_FakeCluster, Redlock]:
        cluster = _FakeCluster(num_masters, auto_release_time)
        cluster.now_ms = acquire_at_ms
        for attr, kind in (
            ('_acquired_script', 'acquired'),
            ('_extend_script', 'extend'),
            ('_release_script', 'release'),
        ):
            monkeypatch.setattr(
                Redlock,
                attr,
                _FakeScript(kind),
                raising=False,
            )
        monkeypatch.setattr(
            redlock_module,
            'ContextTimer',
            lambda: _ClusterTimer(cluster),
        )
        monkeypatch.setattr(
            redlock_module,
            'BailOutExecutor',
            _SynchronousExecutor,
        )
        lock = Redlock(
            key='printer',
            masters=cast(Iterable[Redis], cluster.masters),
            auto_release_time=auto_release_time,
        )
        assert lock.acquire()
        return cluster, lock
    return build


# --------------------------------------------------------------------------- #
#   CF-1 / trace as_is_extend_success_without_validity                        #
#   n=5, ART=200 ms, drift=4 ms, quorum=3.                                    #
#   Trace: lastExtendStart=1133, lastExtendEnd=1338, beliefEnd=1329,          #
#   lastExtendOk=true, lastExtendRenewals=3.  The completion instant is      #
#   already past the start-anchored validity deadline.                        #
# --------------------------------------------------------------------------- #

def test_repro_extend_success_without_validity(cluster_and_lock: BuildLock) -> None:
    '''CURRENT BEHAVIOUR: a too-slow extend is reported as success.

    Trigger path: Redlock.extend() -> quorum of __extend_master() PEXPIREs ->
    immediate return, without checking completion-time validity.
    Expected after fix: ExtendUnlockedLock, and no node keeps this token.
    '''
    cluster, lock = cluster_and_lock(num_masters=5, auto_release_time=.2, acquire_at_ms=940)
    cluster.schedule_extend(start_ms=1133, latency_ms=205)

    lock.extend()  # Must raise ExtendUnlockedLock once INV-6 is implemented.

    assert lock._extension_num == 1
    assert lock.locked() == 0
    # At now=1338 the renewed keys (expiry=1333) are already gone; they were
    # never compensated by the failing extend.
    assert all(master.get(lock.key) is None for master in cluster.masters)


@pytest.mark.skip(reason='INV-6 not implemented; unskip once extend checks completion-time validity and compensates')
def test_fixed_extend_success_without_validity(cluster_and_lock: BuildLock) -> None:
    cluster, lock = cluster_and_lock(num_masters=5, auto_release_time=.2, acquire_at_ms=940)
    cluster.schedule_extend(start_ms=1133, latency_ms=205)

    with pytest.raises(ExtendUnlockedLock):
        lock.extend()

    assert lock._extension_num == 0
    assert all(master.get(lock.key) is None for master in cluster.masters)


# --------------------------------------------------------------------------- #
#   CF-1 / trace as_is_even_extend_success_without_validity                   #
#   n=4 (even), ART=200 ms, drift=4 ms, quorum=3.                             #
#   Trace: lastExtendStart=900, lastExtendEnd=1100, beliefEnd=1096,           #
#   lastExtendOk=true.  A strict majority of an even-sized cluster still      #
#   returns success although the completion instant equals the key expiry.    #
# --------------------------------------------------------------------------- #

def test_repro_even_extend_success_without_validity(cluster_and_lock: BuildLock) -> None:
    '''CURRENT BEHAVIOUR: even-sized cluster reports a late extend as success.

    Trigger path: Redlock.extend() -> 3 of 4 PEXPIREs succeed -> return.
    Expected after fix: ExtendUnlockedLock, and no node keeps this token.
    '''
    cluster, lock = cluster_and_lock(num_masters=4, auto_release_time=.2, acquire_at_ms=738)
    cluster.schedule_extend(start_ms=900, latency_ms=200)

    lock.extend()  # Must raise ExtendUnlockedLock once INV-6 is implemented.

    assert lock._extension_num == 1
    assert lock.locked() == 0
    # Completion (1100 ms) has reached the renewed expiry (1100 ms), yet the
    # as-is extend returned success and left no compensation behind.
    assert all(master.get(lock.key) is None for master in cluster.masters)


@pytest.mark.skip(reason='INV-6 not implemented; unskip once extend checks completion-time validity and compensates')
def test_fixed_even_extend_success_without_validity(cluster_and_lock: BuildLock) -> None:
    cluster, lock = cluster_and_lock(num_masters=4, auto_release_time=.2, acquire_at_ms=738)
    cluster.schedule_extend(start_ms=900, latency_ms=200)

    with pytest.raises(ExtendUnlockedLock):
        lock.extend()

    assert lock._extension_num == 0
    assert all(master.get(lock.key) is None for master in cluster.masters)


# --------------------------------------------------------------------------- #
#   CF-1 / trace as_is_slow_extend_success_without_validity                   #
#   n=5, ART=1000 ms, drift=12 ms, quorum=3.                                  #
#   Trace: lastExtendStart=5698, lastExtendEnd=6692, beliefEnd=6686,          #
#   lastExtendOk=true, lastExtendRenewals=5, renewed expiry=6698.             #
#   The same defect appears at the 1 s scale; five keys stay alive.           #
# --------------------------------------------------------------------------- #

def test_repro_slow_extend_success_without_validity(cluster_and_lock: BuildLock) -> None:
    '''CURRENT BEHAVIOUR: a 994 ms extend returns success with no validity.

    Trigger path: Redlock.extend() -> 5 PEXPIREs succeed -> return.
    Expected after fix: ExtendUnlockedLock, and no node keeps this token.
    '''
    cluster, lock = cluster_and_lock(num_masters=5, auto_release_time=1, acquire_at_ms=5043)
    cluster.schedule_extend(start_ms=5698, latency_ms=994)

    lock.extend()  # Must raise ExtendUnlockedLock once INV-6 is implemented.

    assert lock._extension_num == 1
    assert lock.locked() == 0
    # Like as_is_slow (expiry=6698, now=6692), the keys outlive completion:
    # the late extend did not compensate any of the five renewed nodes.
    assert all(master.get(lock.key) == lock._uuid for master in cluster.masters)


@pytest.mark.skip(reason='INV-6 not implemented; unskip once extend checks completion-time validity and compensates')
def test_fixed_slow_extend_success_without_validity(cluster_and_lock: BuildLock) -> None:
    cluster, lock = cluster_and_lock(num_masters=5, auto_release_time=1, acquire_at_ms=5043)
    cluster.schedule_extend(start_ms=5698, latency_ms=994)

    with pytest.raises(ExtendUnlockedLock):
        lock.extend()

    assert lock._extension_num == 0
    assert all(master.get(lock.key) is None for master in cluster.masters)


# --------------------------------------------------------------------------- #
#   CF-2 / trace as_is_late_extend_no_compensation                            #
#   n=5, ART=200 ms, drift=4 ms, quorum=3.                                    #
#   Trace: lastExtendStart=267, lastExtendEnd=465, beliefEnd=463,             #
#   lastExtendOk=true, lastExtendRenewals=3, keys expiry=467, now=465.        #
#   Completion is late but the three renewed keys are still alive: this is    #
#   the stale-key compensation gap.                                          #
# --------------------------------------------------------------------------- #

def test_repro_late_extend_no_compensation(cluster_and_lock: BuildLock) -> None:
    '''CURRENT BEHAVIOUR: late extend keeps the renewed keys (no compensation).

    Trigger path: Redlock.extend() -> quorum PEXPIRE -> return; the failure
    branch that would release every token holder is never taken.
    Expected after fix: ExtendUnlockedLock, and all token keys are released.
    '''
    cluster, lock = cluster_and_lock(num_masters=5, auto_release_time=.2, acquire_at_ms=239)
    cluster.schedule_extend(start_ms=267, latency_ms=198)

    lock.extend()  # Must raise ExtendUnlockedLock once INV-6 is implemented.

    assert lock._extension_num == 1
    assert lock.locked() == 0
    # Completion is 465 ms, the renewed keys expire at 467 ms: all five are
    # still alive and none was compensated.
    assert all(master.get(lock.key) == lock._uuid for master in cluster.masters)


@pytest.mark.skip(reason='INV-6 not implemented; unskip once extend checks completion-time validity and compensates')
def test_fixed_late_extend_no_compensation(cluster_and_lock: BuildLock) -> None:
    cluster, lock = cluster_and_lock(num_masters=5, auto_release_time=.2, acquire_at_ms=239)
    cluster.schedule_extend(start_ms=267, latency_ms=198)

    with pytest.raises(ExtendUnlockedLock):
        lock.extend()

    assert lock._extension_num == 0
    assert all(master.get(lock.key) is None for master in cluster.masters)
