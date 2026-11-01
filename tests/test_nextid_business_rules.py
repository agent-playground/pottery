# --------------------------------------------------------------------------- #
#   test_nextid_business_rules.py                                             #
#                                                                             #
#   Copyright © 2015-2026, Rajiv Bakulesh Shah, original author.              #
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
'Business rule tests for NextID (docs/business-rules.md R5-R7).'


import concurrent.futures
import threading
from typing import Any
from typing import List

import pytest
from redis import Redis

from pottery import NextID


R5_KEY = 'r5-strictly-increasing'
R5_OTHER_KEY = 'r5-other-key'
R6_KEY = 'r6-concurrent-threads'
R7_INITIAL_VALUE_KEY = 'r7-initial-value'
R7_CHUNK_SIZE_KEY = 'r7-chunk-size'
R7_NO_REGRESSION_KEY = 'r7-no-regression'
R7_SKIP_REASON = (
    'R7 defect: NextID implements neither initial_value nor chunk_size '
    '(see pottery/nextid.py); assertions are preserved for agent-fix-bug. '
    'Reported on issue #18.'
)


def _nextid_with_r7_config(redis: Redis, *, key: str, **config: Any) -> NextID:
    'Build a NextID with the R7 configuration arguments that are missing today.'
    return NextID(key=key, masters={redis}, **config)


def test_r5_same_key_ids_strictly_increase(redis: Redis) -> None:
    'R5: consecutive IDs from the same key are strictly increasing and unique.'
    first = NextID(key=R5_KEY, masters={redis})
    second = NextID(key=R5_KEY, masters={redis})
    generators = [first, second] * 5

    observed = [next(generator) for generator in generators]

    assert observed == list(range(1, len(generators) + 1))
    assert all(later > earlier for earlier, later in zip(observed, observed[1:]))
    assert len(set(observed)) == len(observed)


def test_r5_different_keys_are_independent_sequences(redis: Redis) -> None:
    'R5: only generators that share a key share an ID sequence.'
    first = NextID(key=R5_KEY, masters={redis})
    second = NextID(key=R5_OTHER_KEY, masters={redis})

    assert [next(first) for _ in range(3)] == [1, 2, 3]
    assert [next(second) for _ in range(3)] == [1, 2, 3]
    assert [next(first) for _ in range(3)] == [4, 5, 6]


def test_r6_concurrent_threads_never_duplicate(redis_url: str, redis: Redis) -> None:
    'R6: threads generating IDs concurrently never see the same ID twice.'
    num_threads = 8
    ids_per_thread = 25
    barrier = threading.Barrier(num_threads)

    def generate_ids() -> List[int]:
        client = Redis.from_url(redis_url, socket_timeout=1)
        try:
            ids = NextID(key=R6_KEY, masters={client}, num_tries=100)
            barrier.wait()
            return [next(ids) for _ in range(ids_per_thread)]
        finally:
            client.close()

    with concurrent.futures.ThreadPoolExecutor(max_workers=num_threads) as executor:
        futures = [executor.submit(generate_ids) for _ in range(num_threads)]
        batches = [future.result() for future in futures]

    observed = [id_ for batch in batches for id_ in batch]

    assert len(observed) == num_threads * ids_per_thread
    assert len(set(observed)) == len(observed)
    assert min(observed) >= 1
    for batch in batches:
        assert all(later > earlier for earlier, later in zip(batch, batch[1:]))
    assert int(redis.get(f'nextid:{R6_KEY}') or 0) == max(observed)


@pytest.mark.skip(reason=R7_SKIP_REASON)
def test_r7_initial_value_is_honored(redis: Redis) -> None:
    'R7: initial_value sets the lower bound of the first allocated ID.'
    ids = _nextid_with_r7_config(redis, key=R7_INITIAL_VALUE_KEY, initial_value=1000)

    observed = [next(ids) for _ in range(5)]

    assert observed[0] >= 1000
    assert all(later > earlier for earlier, later in zip(observed, observed[1:]))
    assert len(set(observed)) == len(observed)


@pytest.mark.skip(reason=R7_SKIP_REASON)
def test_r7_chunk_size_is_honored(redis: Redis) -> None:
    'R7: chunk_size never breaks the uniqueness or ordering of issued IDs.'
    ids = _nextid_with_r7_config(redis, key=R7_CHUNK_SIZE_KEY, chunk_size=5)

    observed = [next(ids) for _ in range(25)]

    assert min(observed) >= 1
    assert all(later > earlier for earlier, later in zip(observed, observed[1:]))
    assert len(set(observed)) == len(observed)


@pytest.mark.skip(reason=R7_SKIP_REASON)
def test_r7_never_rewinds_below_issued_ids(redis: Redis) -> None:
    'R7: a second generator on the same key never reissues an allocated ID.'
    first = _nextid_with_r7_config(
        redis,
        key=R7_NO_REGRESSION_KEY,
        initial_value=100,
        chunk_size=5,
    )
    issued = [next(first) for _ in range(12)]

    second = _nextid_with_r7_config(
        redis,
        key=R7_NO_REGRESSION_KEY,
        initial_value=100,
        chunk_size=5,
    )
    next_id = next(second)

    assert next_id > max(issued)
    assert next_id not in issued
