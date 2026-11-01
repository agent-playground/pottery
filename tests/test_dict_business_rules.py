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
'''Business rule tests for RedisDict (docs/business-rules.md R8-R10).

R8 covers the boundary behavior of empty collections, nonexistent keys, and
overwrites against native Redis hash semantics; R9 covers the reversibility
of the JSON serialization (including the bytes/str boundary); R10 covers
TTL application with no orphan keys left behind.
'''


import time
from typing import Dict

import pytest
from redis import Redis
from redis.exceptions import ResponseError

from pottery import RedisDict
from pottery.annotations import JSONTypes


R8_EMPTY_KEY = 'r8-empty'
R8_NO_KEY_CREATION_KEY = 'r8-no-key-creation'
R8_NONEXISTENT_KEY = 'r8-nonexistent'
R8_OVERWRITE_KEY = 'r8-overwrite'
R8_DELETE_LAST_KEY = 'r8-delete-last'
R8_WRONG_TYPE_KEY = 'r8-wrong-type'
R9_JSON_TYPES_KEY = 'r9-json-types'
R9_NON_STRING_KEYS_KEY = 'r9-non-string-keys'
R9_BYTES_STR_KEY = 'r9-bytes-str'
R9_RAW_STORAGE_KEY = 'r9-raw-storage'
R10_EXPIRE_KEY = 'r10-expire'
R10_RECREATE_KEY = 'r10-recreate-after-expiry'
R10_MISSING_KEY_KEY = 'r10-expire-missing-key'


def test_r8_empty_dict_boundaries(redis: Redis) -> None:
    'R8: an empty RedisDict behaves like an empty dict and a Redis hash miss.'
    d = RedisDict(redis=redis, key=R8_EMPTY_KEY)

    assert len(d) == 0
    assert list(d) == []
    assert sorted(d.keys()) == []
    assert list(d.values()) == []
    assert list(d.items()) == []
    assert d.to_dict() == {}
    assert d == {}
    assert 'anything' not in d
    assert d.get('anything') is None
    assert d.get('anything', 42) == 42
    with pytest.raises(KeyError):
        d['anything']
    with pytest.raises(KeyError):
        del d['anything']


def test_r8_empty_construction_writes_no_redis_key(redis: Redis) -> None:
    'R8: constructing an empty RedisDict must not create the underlying key.'
    RedisDict(redis=redis, key=R8_NO_KEY_CREATION_KEY)
    RedisDict({}, redis=redis, key=f'{R8_NO_KEY_CREATION_KEY}:mapping')

    assert redis.exists(R8_NO_KEY_CREATION_KEY) == 0
    assert redis.exists(f'{R8_NO_KEY_CREATION_KEY}:mapping') == 0


def test_r8_nonexistent_key_reads_as_empty(redis: Redis) -> None:
    'R8: attaching a RedisDict to a nonexistent key reads as an empty dict.'
    d = RedisDict(redis=redis, key=R8_NONEXISTENT_KEY)

    assert len(d) == 0
    assert redis.hlen(R8_NONEXISTENT_KEY) == 0
    assert 'one' not in d
    assert d.get('one') is None
    with pytest.raises(KeyError):
        d['one']


def test_r8_overwrite_last_write_wins(redis: Redis) -> None:
    'R8: re-assigning a key replaces the value, like native Redis HSET.'
    d = RedisDict(redis=redis, key=R8_OVERWRITE_KEY, field='first')

    d['field'] = 'second'
    d['field'] = ['a', 1]

    assert d['field'] == ['a', 1]
    assert d == {'field': ['a', 1]}
    assert redis.hlen(R8_OVERWRITE_KEY) == 1
    assert redis.hget(R8_OVERWRITE_KEY, '"field"') == b'["a", 1]'


def test_r8_deleting_last_item_removes_redis_key(redis: Redis) -> None:
    'R8: Redis drops a hash whose last field is deleted (no empty orphan).'
    d = RedisDict(redis=redis, key=R8_DELETE_LAST_KEY, one=1, two=2)

    del d['one']
    assert redis.exists(R8_DELETE_LAST_KEY) == 1
    del d['two']

    assert redis.exists(R8_DELETE_LAST_KEY) == 0
    assert len(d) == 0
    assert d.to_dict() == {}


def test_r8_wrong_type_key_raises_response_error(redis: Redis) -> None:
    'R8: hash operations on a string-typed key raise WRONGTYPE, as Redis does.'
    redis.set(R8_WRONG_TYPE_KEY, 'plain-string-value')
    d = RedisDict(redis=redis, key=R8_WRONG_TYPE_KEY)

    with pytest.raises(ResponseError):
        len(d)
    assert redis.get(R8_WRONG_TYPE_KEY) == b'plain-string-value'


def test_r9_roundtrip_all_json_types(redis: Redis) -> None:
    'R9: every JSON-supported value type survives write/read unchanged.'
    original: Dict[JSONTypes, JSONTypes] = {
        'none': None,
        'true': True,
        'false': False,
        'zero': 0,
        'negative': -17,
        'float': 3.5,
        'empty-string': '',
        'quotes': 'say "hi" and \'ho\'\n中文字符\ttab',
        'list': [1, 2.5, 'three', None, True],
        'nested': {'a': [1, {'b': 2}], 'c': None},
    }

    d = RedisDict(original, redis=redis, key=R9_JSON_TYPES_KEY)

    assert d.to_dict() == original
    for key, value in original.items():
        assert d[key] == value
        d[key] = value
    assert d == original


def test_r9_roundtrip_non_string_keys(redis: Redis) -> None:
    'R9: int/float keys round-trip and stay distinct from their str twins.'
    original: Dict[JSONTypes, JSONTypes] = {
        0: 'int-zero',
        '0': 'str-zero',
        1.5: 'float',
        '1.5': 'str-float',
        'plain': 'str',
    }

    d = RedisDict(original, redis=redis, key=R9_NON_STRING_KEYS_KEY)

    assert d.to_dict() == original
    assert d[0] == 'int-zero'
    assert d['0'] == 'str-zero'
    assert d[1.5] == 'float'
    assert len(d) == 5


def test_r9_roundtrip_across_bytes_and_str_clients(redis: Redis, redis_url: str) -> None:
    'R9: values round-trip through both a bytes and a str Redis client.'
    decoded_redis: Redis = Redis.from_url(
        redis_url,
        socket_timeout=1,
        decode_responses=True,
    )
    try:
        initial: Dict[JSONTypes, JSONTypes] = {'text': 'héllo', 'num': 42}
        from_bytes = RedisDict(initial, redis=redis, key=R9_BYTES_STR_KEY)
        from_str = RedisDict(redis=decoded_redis, key=R9_BYTES_STR_KEY)

        assert from_bytes['text'] == 'héllo'
        assert from_bytes['num'] == 42
        assert from_str['text'] == 'héllo'
        assert from_str['num'] == 42
        assert from_bytes == from_str
        assert from_str.to_dict() == {'text': 'héllo', 'num': 42}
    finally:
        decoded_redis.close()


def test_r9_raw_storage_is_json_encoded(redis: Redis) -> None:
    'R9: fields and values are stored as their JSON encodings.'
    d = RedisDict(redis=redis, key=R9_RAW_STORAGE_KEY)

    d['answer'] = 42
    d['text'] = 'hi'

    assert sorted(redis.hkeys(R9_RAW_STORAGE_KEY)) == [b'"answer"', b'"text"']
    assert redis.hget(R9_RAW_STORAGE_KEY, '"answer"') == b'42'
    assert redis.hget(R9_RAW_STORAGE_KEY, '"text"') == b'"hi"'


def test_r10_expire_removes_dict_and_leaves_no_orphans(redis: Redis) -> None:
    'R10: once the TTL passes, the key is gone entirely, with no orphan data.'
    d = RedisDict(redis=redis, key=R10_EXPIRE_KEY, one=1, two=2)
    redis.pexpire(R10_EXPIRE_KEY, 120)

    assert 0 < redis.pttl(R10_EXPIRE_KEY) <= 120
    assert d['one'] == 1
    time.sleep(0.3)

    assert redis.exists(R10_EXPIRE_KEY) == 0
    assert redis.ttl(R10_EXPIRE_KEY) == -2
    assert len(d) == 0
    assert 'one' not in d
    assert d.to_dict() == {}
    with pytest.raises(KeyError):
        d['one']
    orphaned = list(redis.scan_iter(match=R10_EXPIRE_KEY))
    assert orphaned == []


def test_r10_recreate_after_expiry_has_no_stale_ttl(redis: Redis) -> None:
    'R10: writing after expiry recreates the key without the old TTL.'
    d = RedisDict(redis=redis, key=R10_RECREATE_KEY, one=1)
    redis.pexpire(R10_RECREATE_KEY, 120)
    time.sleep(0.3)
    assert redis.exists(R10_RECREATE_KEY) == 0

    d['two'] = 2

    assert redis.exists(R10_RECREATE_KEY) == 1
    assert redis.ttl(R10_RECREATE_KEY) == -1
    assert d.to_dict() == {'two': 2}


def test_r10_expire_on_missing_key_is_noop(redis: Redis) -> None:
    'R10: setting a TTL on a nonexistent key does nothing, as Redis does.'
    d = RedisDict(redis=redis, key=R10_MISSING_KEY_KEY)

    assert not redis.expire(R10_MISSING_KEY_KEY, 60)
    assert redis.exists(R10_MISSING_KEY_KEY) == 0

    d['one'] = 1
    assert redis.exists(R10_MISSING_KEY_KEY) == 1
    assert redis.ttl(R10_MISSING_KEY_KEY) == -1
