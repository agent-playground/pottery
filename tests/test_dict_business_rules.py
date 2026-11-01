# --------------------------------------------------------------------------- #
#   test_dict_business_rules.py                                               #
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
'Business rule tests for RedisDict (docs/business-rules.md R8-R10).'


import json
import time
from typing import Dict

import pytest
from redis import Redis

from pottery import KeyExistsError
from pottery import RedisDict
from pottery.annotations import JSONTypes


R8_EMPTY_KEY = 'r8-empty'
R8_MISSING_KEY = 'r8-missing'
R8_OVERWRITE_KEY = 'r8-overwrite'
R8_DELETE_KEY = 'r8-delete'
R8_REINIT_KEY = 'r8-reinit'

R9_VALUES_KEY = 'r9-values'
R9_BYTES_KEY = 'r9-bytes'
R9_TEXT_CLIENT_KEY = 'r9-text-client'

R10_EXPIRY_KEY = 'r10-expiry'
R10_REUSE_KEY = 'r10-reuse'

R9_PAYLOAD: Dict[JSONTypes, JSONTypes] = {
    'string': 'hello',
    'unicode': 'caf\u00e9 \u2192 \u6f22',
    'empty-string': '',
    'integer': 42,
    'float': 1.5,
    'boolean': True,
    'none': None,
    'list': [1, 'two', False, None, {'nested': 3}],
    'mapping': {'inner': ['x', 2.5], 'empty': {}},
}


def _wait_for_key_to_expire(redis: Redis, key: str) -> None:
    'Wait for Redis to evict a key, up to a generous CI-friendly deadline.'
    deadline = time.monotonic() + 5.0
    while redis.exists(key) and time.monotonic() < deadline:
        time.sleep(0.01)


def test_r8_empty_dict_matches_missing_redis_hash(redis: Redis) -> None:
    'R8: an empty RedisDict behaves like a missing Redis hash.'
    d = RedisDict(redis=redis, key=R8_EMPTY_KEY)

    assert len(d) == 0
    assert d.to_dict() == {}
    assert list(d) == []
    assert list(d.keys()) == []
    assert list(d.values()) == []
    assert list(d.items()) == []
    assert bool(d) is False
    assert d == {}
    assert d.get('missing') is None
    assert d.get('missing', 42) == 42
    assert 'missing' not in d
    assert redis.exists(d.key) == 0
    assert redis.hlen(d.key) == 0
    assert redis.hgetall(d.key) == {}


def test_r8_missing_key_operations_match_redis(redis: Redis) -> None:
    'R8: HGET/HDEL return nothing for missing fields; Python maps to KeyError.'
    d = RedisDict(redis=redis, key=R8_MISSING_KEY)

    with pytest.raises(KeyError, match='missing'):
        d['missing']
    with pytest.raises(KeyError, match='missing'):
        del d['missing']
    with pytest.raises(KeyError, match='missing'):
        d.pop('missing')
    assert d.pop('missing', 'fallback') == 'fallback'
    with pytest.raises(KeyError):
        d.popitem()
    assert d == {}
    assert redis.exists(d.key) == 0


def test_r8_overwrite_updates_field_without_growing_hash(redis: Redis) -> None:
    'R8: HSET overwrites an existing field instead of appending a duplicate.'
    d = RedisDict(redis=redis, key=R8_OVERWRITE_KEY, alpha=1)
    assert redis.hlen(d.key) == 1

    d['alpha'] = 2
    assert d['alpha'] == 2
    assert len(d) == 1
    assert redis.hlen(d.key) == 1

    d['beta'] = 2
    d['beta'] = 3
    assert d['beta'] == 3
    assert len(d) == 2
    assert redis.hlen(d.key) == 2

    d.update(alpha=4, gamma=5)
    assert d.to_dict() == {'alpha': 4, 'beta': 3, 'gamma': 5}
    assert redis.hlen(d.key) == 3


def test_r8_deleting_or_clearing_all_fields_removes_redis_key(redis: Redis) -> None:
    'R8: Redis drops a hash once its last field is removed, leaving no key.'
    d = RedisDict(redis=redis, key=R8_DELETE_KEY, only='value')
    assert redis.exists(d.key) == 1

    del d['only']
    assert len(d) == 0
    assert d.to_dict() == {}
    assert redis.exists(d.key) == 0
    assert redis.hlen(d.key) == 0

    d.update(one=1, two=2)
    assert redis.exists(d.key) == 1
    d.clear()
    assert len(d) == 0
    assert redis.exists(d.key) == 0


def test_r8_empty_constructor_reads_existing_hash(redis: Redis) -> None:
    'R8: an empty constructor is a read-only view; populated init still guards.'
    original = RedisDict(redis=redis, key=R8_REINIT_KEY, one=1, two=2)

    clone = RedisDict(redis=redis, key=original.key)
    assert clone.to_dict() == {'one': 1, 'two': 2}
    assert len(clone) == 2

    with pytest.raises(KeyExistsError):
        RedisDict(redis=redis, key=original.key, three=3)
    assert original.to_dict() == {'one': 1, 'two': 2}


def test_r9_json_values_roundtrip_unchanged(redis: Redis) -> None:
    'R9: every JSON value written through RedisDict reads back equal.'
    d = RedisDict(redis=redis, key=R9_VALUES_KEY)
    for key, value in R9_PAYLOAD.items():
        d[key] = value

    for key, value in R9_PAYLOAD.items():
        assert d[key] == value
    assert d.to_dict() == R9_PAYLOAD
    assert dict(d.items()) == R9_PAYLOAD
    assert set(d) == set(R9_PAYLOAD)
    assert len(d) == len(R9_PAYLOAD)


def test_r9_persisted_values_are_json_bytes_and_reload_equal(redis: Redis) -> None:
    'R9: Redis stores JSON bytes; a fresh RedisDict decodes them reversibly.'
    d = RedisDict(redis=redis, key=R9_BYTES_KEY)
    d.update(R9_PAYLOAD)

    raw = redis.hgetall(d.key)
    assert len(raw) == len(R9_PAYLOAD)
    assert all(
        isinstance(field, bytes) and isinstance(value, bytes)
        for field, value in raw.items()
    )
    assert {
        json.loads(field): json.loads(value)
        for field, value in raw.items()
    } == R9_PAYLOAD

    reloaded = RedisDict(redis=redis, key=d.key)
    assert reloaded.to_dict() == R9_PAYLOAD


def test_r9_bytes_and_text_redis_clients_roundtrip(redis: Redis,
                                                   redis_url: str,
                                                   ) -> None:
    'R9: values written via bytes-decoding and text-decoding clients agree.'
    text_redis = Redis.from_url(
        redis_url,
        socket_timeout=1,
        decode_responses=True,
    )
    try:
        source = RedisDict(redis=redis, key=R9_TEXT_CLIENT_KEY)
        source.update(R9_PAYLOAD)

        decoded = RedisDict(redis=text_redis, key=source.key)
        assert decoded.to_dict() == R9_PAYLOAD
        for key, value in R9_PAYLOAD.items():
            assert decoded[key] == value

        decoded['written-as-text'] = 'ok'
        assert source['written-as-text'] == 'ok'
        assert decoded['written-as-text'] == 'ok'
    finally:
        text_redis.close()


def test_r10_expiration_removes_dict_and_backing_key(redis: Redis) -> None:
    'R10: once the hash TTL elapses, the dict is empty and no key survives.'
    d = RedisDict(redis=redis, key=R10_EXPIRY_KEY, a=1, b=2)
    assert redis.ttl(d.key) == -1
    assert redis.expire(d.key, 1) is True
    assert 0 <= redis.ttl(d.key) <= 1

    _wait_for_key_to_expire(redis, d.key)

    assert redis.exists(d.key) == 0
    assert redis.hlen(d.key) == 0
    assert len(d) == 0
    assert d.to_dict() == {}
    assert list(d) == []
    assert d.get('a') is None
    assert 'a' not in d
    assert d == {}


def test_r10_reuse_after_expiration_has_no_stale_fields(redis: Redis) -> None:
    'R10: reusing an expired key starts clean; old fields do not linger.'
    d = RedisDict(redis=redis, key=R10_REUSE_KEY, stale='old')
    redis.pexpire(d.key, 100)

    _wait_for_key_to_expire(redis, d.key)
    assert redis.exists(d.key) == 0

    d['fresh'] = 'new'

    assert redis.exists(d.key) == 1
    assert redis.hlen(d.key) == 1
    assert d.to_dict() == {'fresh': 'new'}
    assert 'stale' not in d
    assert d.get('stale') is None
