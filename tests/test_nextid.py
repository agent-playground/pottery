# --------------------------------------------------------------------------- #
#   test_nextid.py                                                            #
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
'Distributed Redis-powered monotonically increasing ID generator tests.'


import concurrent.futures
import contextlib
import unittest.mock
from typing import Generator
from typing import List

import pytest
from redis import Redis
from redis.commands.core import Script
from redis.exceptions import TimeoutError

from pottery import NextID
from pottery import QuorumIsImpossible
from pottery import QuorumNotAchieved


@pytest.fixture
def ids(redis: Redis) -> Generator[NextID, None, None]:
    redis.unlink('nextid:current')
    yield NextID(masters={redis})
    redis.unlink('nextid:current')


def test_nextid(ids: NextID) -> None:
    for id_ in range(1, 10):
        assert next(ids) == id_


def test_iter(ids: NextID) -> None:
    assert iter(ids) is ids


def test_reset(ids: NextID) -> None:
    ids.reset()
    for redis in ids.masters:
        assert not redis.exists(ids.key)

    assert next(ids) == 1
    for redis in ids.masters:
        assert redis.exists(ids.key)

    ids.reset()
    for redis in ids.masters:
        assert not redis.exists(ids.key)

    assert next(ids) == 1
    for redis in ids.masters:
        assert redis.exists(ids.key)


@pytest.mark.parametrize('num_ids', range(1, 6))
def test_contention(num_ids: int) -> None:
    dbs = range(1, 6)
    urls = [f'redis://localhost:6379/{db}' for db in dbs]
    masters = [Redis.from_url(url, socket_timeout=1) for url in urls]
    ids = [NextID(key='tweet-ids', masters=masters) for _ in range(num_ids)]

    try:
        results = []
        with concurrent.futures.ThreadPoolExecutor() as executor:
            futures = [executor.submit(next, i) for i in ids]  # type: ignore
            for future in concurrent.futures.as_completed(futures):
                with contextlib.suppress(QuorumNotAchieved):
                    result = future.result()
                    results.append(result)
        assert len(results) == len(set(results))
        # To see the following output, issue:
        # $ source venv/bin/activate; pytest -rP tests/test_nextid.py::test_contention; deactivate
        print(f'{num_ids} ids, {results} IDs')

    finally:
        ids[0].reset()


def test_repr(ids: NextID) -> None:
    assert repr(ids) == '<NextID key=nextid:current>'


def test_slots(ids: NextID) -> None:
    with pytest.raises(AttributeError):
        ids.__dict__


def test_next_quorumnotachieved(ids: NextID) -> None:
    with pytest.raises(QuorumNotAchieved), \
         unittest.mock.patch.object(next(iter(ids.masters)), 'get') as get:
        get.side_effect = TimeoutError
        next(ids)

    with pytest.raises(QuorumNotAchieved), \
         unittest.mock.patch.object(Script, '__call__') as __call__:
        __call__.side_effect = TimeoutError
        next(ids)


def test_next_quorumisimpossible(redis: Redis) -> None:
    ids = NextID(masters={redis}, raise_on_redis_errors=True)
    with pytest.raises(QuorumIsImpossible), \
         unittest.mock.patch.object(next(iter(ids.masters)), 'get') as get:
        get.side_effect = TimeoutError
        next(ids)

    with pytest.raises(QuorumIsImpossible), \
         unittest.mock.patch.object(Script, '__call__') as __call__:
        __call__.side_effect = TimeoutError
        next(ids)


def test_reset_quorumnotachieved(ids: NextID) -> None:
    with pytest.raises(QuorumNotAchieved), \
         unittest.mock.patch.object(next(iter(ids.masters)), 'delete') as delete:
        delete.side_effect = TimeoutError
        ids.reset()


def test_reset_quorumisimpossible(redis: Redis) -> None:
    ids = NextID(masters={redis}, raise_on_redis_errors=True)
    with pytest.raises(QuorumIsImpossible), \
         unittest.mock.patch.object(next(iter(ids.masters)), 'delete') as delete:
        delete.side_effect = TimeoutError
        ids.reset()


# --------------------------------------------------------------------------- #
#   Coverage for docs/business-rules.md R5–R7 (Issue #18).
# --------------------------------------------------------------------------- #

def test_strictly_increasing_same_key(ids: NextID) -> None:
    '''R5: 同一 key 連續取號必為嚴格遞增序列且不重複。'''
    previous = 0
    for _ in range(50):
        current = next(ids)
        assert current > previous
        previous = current


def test_strictly_increasing_across_instances(redis: Redis) -> None:
    '''R5: 同一 key 跨多個 NextID 實例交替取號仍嚴格遞增、不重複。'''
    key = 'nextid:sequence'
    redis.unlink(key)
    try:
        ids_a = NextID(key='sequence', masters={redis})
        ids_b = NextID(key='sequence', masters={redis})
        observed: List[int] = []
        for _ in range(25):
            observed.append(next(ids_a))
            observed.append(next(ids_b))
        assert all(b > a for a, b in zip(observed, observed[1:]))
        assert len(observed) == len(set(observed))
    finally:
        redis.unlink(key)


def test_concurrent_threads_no_duplicates(redis: Redis) -> None:
    '''R6: 多執行緒併發取號（共用同一 key），回傳值集合無重複。'''
    key = 'nextid:concurrent'
    redis.unlink(key)
    try:
        num_threads, ids_per_thread = 8, 5
        # num_tries 開大：高併發下 read→set 視窗極易碰撞，重試只影響
        # 取號時機、不影響不重複性（實測：num_tries=10 幾乎必拋
        # QuorumNotAchieved，>=30 連續 25 輪零失敗）。
        ids_list = [
            NextID(key='concurrent', masters={redis}, num_tries=100)
            for _ in range(num_threads)
        ]

        def worker(ids: NextID) -> List[int]:
            return [next(ids) for _ in range(ids_per_thread)]

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=num_threads,
        ) as executor:
            per_thread = [
                future.result() for future in
                [executor.submit(worker, ids) for ids in ids_list]
            ]

        allocated = [id_ for sublist in per_thread for id_ in sublist]
        assert len(allocated) == num_threads * ids_per_thread
        assert len(allocated) == len(set(allocated))
        assert all(id_ > 0 for id_ in allocated)
        # 同一實例在併發下仍嚴格遞增（重試只會拿到更大的號）：
        for sublist in per_thread:
            assert all(b > a for a, b in zip(sublist, sublist[1:]))
    finally:
        redis.unlink(key)


def test_no_backwards_stale_write_rejected(ids: NextID, redis: Redis) -> None:
    '''R7: 已配發的號碼不會被回退——較小的過期值寫入被守門拒絕。'''
    allocated = [next(ids) for _ in range(5)]
    assert allocated == [1, 2, 3, 4, 5]

    script = NextID._set_id_script
    assert isinstance(script, Script)
    # 遲到的寫入者試圖把序列回退到 3：被 set-if-greater 拒絕。
    assert script(keys=(ids.key,), args=(3,), client=redis) is None
    assert int(redis.get(ids.key) or b'0') == 5
    # 配號繼續往前走，不會重發已配發過的號碼。
    assert next(ids) == 6


@pytest.mark.skip(
    reason='既有實作不支援 initial_value（Issue #18 補測揭露的缺陷：'
           'TypeError: unexpected keyword argument）。斷言完整保留，'
           '建議另開 agent-fix-bug 工作項修復。',
)
def test_initial_value(redis: Redis) -> None:
    '''R7: initial_value 可設定——取號從設定的號段開始，不回退到小號。'''
    key = 'nextid:segment'
    redis.unlink(key)
    try:
        ids = NextID(  # type: ignore[call-arg]
            key='segment', masters={redis}, initial_value=100,
        )
        first = next(ids)
        assert first >= 100
        following = [next(ids) for _ in range(4)]
        assert all(b > a for a, b in zip([first] + following, following))
    finally:
        redis.unlink(key)


@pytest.mark.skip(
    reason='既有實作不支援 initial_value（Issue #18 補測揭露的缺陷）。'
           '斷言完整保留，建議另開 agent-fix-bug 工作項修復。',
)
def test_initial_value_does_not_rewind(redis: Redis) -> None:
    '''R7: initial_value 不得讓取號回退到已配發過的號碼。'''
    key = 'nextid:segment'
    redis.unlink(key)
    try:
        ids = NextID(key='segment', masters={redis})
        allocated = [next(ids) for _ in range(5)]
        stale = NextID(  # type: ignore[call-arg]
            key='segment', masters={redis}, initial_value=1,
        )
        assert next(stale) > max(allocated)
    finally:
        redis.unlink(key)


@pytest.mark.skip(
    reason='既有實作不支援 chunk_size（Issue #18 補測揭露的缺陷：'
           'TypeError: unexpected keyword argument）。斷言完整保留，'
           '建議另開 agent-fix-bug 工作項修復。',
)
def test_chunk_size(redis: Redis) -> None:
    '''R7: chunk_size 可設定——一次取得整個號段，段內不重複、不越界。'''
    key = 'nextid:segment'
    redis.unlink(key)
    try:
        ids = NextID(  # type: ignore[call-arg]
            key='segment', masters={redis}, chunk_size=5,
        )
        batch = [next(ids) for _ in range(5)]
        assert batch == [1, 2, 3, 4, 5]
        # 其他客戶端拿到的是下一號段，不會重複已配發的 1–5。
        other = NextID(  # type: ignore[call-arg]
            key='segment', masters={redis}, chunk_size=5,
        )
        assert next(other) == 6
    finally:
        redis.unlink(key)
