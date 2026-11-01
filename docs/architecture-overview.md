# Pottery 架構總覽（S6：README＋架構總覽）

| 項目 | 內容 |
| --- | --- |
| 工作項 | [agent-playground/pottery#12](https://github.com/agent-playground/pottery/issues/12)（S 流程 S6，`agent-write-docs`） |
| 基準 | `software-factory` trunk；文件內容以 repo 內原始碼逐條核對（引用的 `檔案:行號` 均可直接開啟檢視） |
| 上游依據 | [S4／A0 報告](research/7-a0-scale-readiness.md)、[S5／A1–A4 報告](research/9-s5-a1-a4-inventory.md)（兩份皆已合併并经人類審查） |
| 狀態 | 待 HG3 人工審查；§7 的「推斷設計決策」**未獲人類確認** |
| 日期 | 2026-11-01 |

> **本文件不是規格來源**：依 `docs/29` §10.2，照實作撰寫的文件不得作為 Quint 不變量的 `source`。業務規則由人類於 S7 撰寫。

---

## 1. 系統定位

- **單一 PyPI 函式庫**：`pottery` 版本 3.0.1（`setup.py:34`），只有一個可部署單元，無服務、批次或前端。
- **唯一外部系統是 Redis**：所有持久狀態都在 Redis keyspace；本套件本身無資料庫、無 migration、無 schema 檔。預設連線 `redis://localhost:6379/0`，可在 import 前以環境變數 `REDIS_URL` 覆寫（`pottery/base.py:52-53`；**只在 import 時讀一次**，之後改環境變數無效）。
- **宣稱的 Python 版本存在不一致（既存事實，非本文件新增）**：`setup.py:71` 宣告 `python_requires='>=3.10, <4'`，但 classifiers（`setup.py:62-66`）與 CI 矩陣（`.github/workflows/python-package.yml:17`）只涵蓋 3.11–3.15。此矛盾由 S5 報告 §2.3.4 記錄，處置待人類裁定。

## 2. 分層與五個 context

以「對外行為邊界」切分成 5 個 context（沿用已合併的 A1 報告 §2.1.1 之切法）：

| Context | 模組 | 職責 |
| --- | --- | --- |
| **C1 容器** | `dict.py`、`list.py`、`set.py`、`counter.py`、`deque.py` | 以 Redis hash／list／set 實作 `collections.abc` 介面；`RedisCounter` 繼承 `RedisDict`（`counter.py`）、`RedisDeque` 繼承 `RedisList` 與 `collections.deque`（`deque.py:33`） |
| **C2 機率結構** | `bloom.py`、`hyper.py` | `BloomFilter(BloomFilterABC, Container)`（`bloom.py:206`）、`HyperLogLog(Container)`（`hyper.py:42`） |
| **C3 快取** | `cache.py` | `redis_cache()` 裝飾器與 `CachedOrderedDict`（`cache.py:73,195`），值存放於 `RedisDict` |
| **C4 分散式協調** | `redlock.py`、`aioredlock.py`、`nextid.py`、`aionextid.py`、`executor.py` | 分散式鎖、單調遞增 ID、quorum 提前返回的執行器 |
| **C5 核心管線** | `base.py`、`monkey.py`、`annotations.py`、`exceptions.py`、`timer.py`、`__init__.py`、`py.typed` | 連線／key／codec／WATCH 管線、全域 json patch、型別別名、例外階層、毫秒計時器、公開匯出面 |

模組間的 import 方向（`from .<module>` 掃描結果，圖與依賴清單詳見 A1 報告 §2.1.1–§2.1.3）：C1–C4 全部向下依賴 C5 的 `base.py`；非同步模組（`aioredlock.py`、`aionextid.py`）**繼承同步模組的 `Scripts` 與類別常數**（`aioredlock.py:62-64,149`；`aionextid.py:39-40,43`），形成同步／非同步的強耦合——改同步側的 Lua 腳本會同時影響兩邊。

## 3. 三條核心執行路徑

### 3.1 容器路徑（樂觀併發）

1. **key／value codec**：每個容器對應一個 Redis key；value 一律 `json.dumps(decoded_value, sort_keys=True)` 編碼（`base.py:141-144`），讀回 `json.loads`（`base.py:146-155`）。
2. **跨命令原子性**：多命令操作包在 `_watch()` 的 `pipeline.watch(...)` → `MULTI` → `execute()` 交易管線裡（`base.py:187-204`），失敗拋 `WatchError` 由呼叫側處理——這是容器正確性的唯一保護層。
3. **隨機 key 的生命周期**：未指定 key 時產生 `pottery:<uuid>` 前綴的隨機 key（`base.py:58,91`）；`__del__` 偵測到隨機前綴就 `redis.unlink(key)` 並發 warning（`base.py:97-105`）。**指定 key 的容器不受此影響。**

### 3.2 協調路徑（Lua ＋ 多 master quorum）

1. **Lua 腳本**：`Redlock` 與 `NextID` 各自透過 `Scripts` mixin 註冊伺服器端原子腳本（`redlock.py:76`、`nextid.py:55`）；鎖的 value 是持有者 `_uuid`。
2. **key 命名空間**：`Redlock` 用 `_KEY_PREFIX = 'redlock'`（`redlock.py:228`）、`NextID` 用 `'nextid'`（`nextid.py:141`）；`AIORedlock` 直接沿用 `Redlock._KEY_PREFIX`（`aioredlock.py:149`）；key 由 `f'{self._KEY_PREFIX}:{value}'` 組成（`base.py:318`）——同步與非同步鎖看到的是同一把鎖。
3. **多數決**：quorum 條件寫成 `數量 > len(self.masters) // 2`（如 `redlock.py:343`、`nextid.py:239`、`aioredlock.py:262`）。
4. **提前返回**：同步路徑用 `BailOutExecutor`（`ThreadPoolExecutor` 子類，`__exit__` 以 `shutdown(wait=False)` 不等待未完成 future，`executor.py:26-58`）在凑夠多數時立即返回。
5. **鎖的預設參數**：`auto_release_time=10`（秒）、`num_extensions=3`、`_CLOCK_DRIFT_FACTOR=0.01`（`redlock.py:229-232`）。
6. **例外階層**：容器側 `PotteryError` 系（`KeyExistsError`、`RandomKeyError`、`QueueEmptyError`）；協調側 `PrimitiveError` 系（`QuorumNotAchieved`、`QuorumIsImpossible`、`TooManyExtensions`、`ExtendUnlockedLock`、`ReleaseUnlockedLock`）；警告 `PotteryWarning`／`InefficientAccessWarning`（`exceptions.py:28-71`）。
7. **同步／非同步語意差異（注意）**：非同步 `AIORedlock` 的 quorum 檢查在收齊所有 master 結果之後才進行（`aioredlock.py:250` 起），與同步的提前返回不同；`locked()` 的 TTL 選法亦異。此差異已被 S5 報告列為候選發現 F2／F4，**本文件不将其描述為「正確行為」**，處置待人類裁定。

### 3.3 全域副作用（import 時即生效）

`import pottery` 會載入 `monkey.py`，**無條件替換整個 process 的 `json.dumps`**，預設使用 `PotteryEncoder`（`monkey.py:33-55`，patch 於 `monkey.py:55`）；其效果是容器物件可直接被 `json.dumps()` 序列化（先轉 `to_dict()`／`to_list()`）。這是刻意換取易用性的高 blast-radius 設計：副作用不只影響 pottery 的使用者，也影響同 process 內所有 `json.dumps` 呼叫。

## 4. 狀態所有權：Redis vs. client 記憶體

| 狀態 | 位置 | 證據 | 含意 |
| --- | --- | --- | --- |
| 容器內容（hash／list／set／string） | Redis | `dict.py`、`list.py`、`set.py` 的 key 操作 | 跨 process 共享 |
| key 名稱 | client 屬性＋Redis key | `base.py:56-77` | 隨機 key 隨實例銷毀被刪 |
| `RedisDeque.maxlen` | **僅 client**（`self._maxlen`） | `deque.py:50,72` | 同一 key 用不同 `maxlen` 的兩個實例各自套用不同上限，無錯誤或警告 |
| `BloomFilter.num_elements`／`false_positives` | **僅 client** | `bloom.py:100-101` | 同 key 不同 n／p 會以不同 bit 數與 hash 次數讀寫同一條 bit string |
| `Redlock` 的 lease 參數 | client；僅 `_uuid` 寫入 Redis value | `redlock.py:239-277` | 各 client 可持有不同 TTL 參數 |
| `CachedOrderedDict._num_tries`／`timeout` | **僅 client** | `cache.py:218-226` | 同一 key 的 timeout 由最後寫入者決定 |
| 全域預設 client | `base._default_redis`，import 時建立 | `base.py:52-53` | `REDIS_URL` 只在 import 時生效一次 |

> 「參數不與 Redis key 綁定」是 API 契約缺口（S5 報告 F3），修復或明文化由後續工作項處理；本文件如實記錄現況，不承諾尚不存在的保護。

## 5. 公開 API 面

`pottery/__init__.py:58-90` 的 `__all__` 是對外契約，共 **28 個名稱**：

- 容器 5：`RedisDict`、`RedisList`、`RedisSet`、`RedisCounter`、`RedisDeque`
- 機率結構 2：`BloomFilter`、`HyperLogLog`
- 快取 2：`redis_cache`、`CachedOrderedDict`
- 協調 5：`Redlock`、`AIORedlock`、`synchronize`、`NextID`、`AIONextID`
- 設施 2：`ContextTimer`、`PotteryEncoder`（`annotations.py` 的型別別名不匯出）
- 例外／警告 12：`PotteryError`、`KeyExistsError`、`RandomKeyError`、`QueueEmptyError`、`PrimitiveError`、`QuorumIsImpossible`、`QuorumNotAchieved`、`TooManyExtensions`、`ExtendUnlockedLock`、`ReleaseUnlockedLock`、`PotteryWarning`、`InefficientAccessWarning`

`pottery/__init__.py` 是 H7 高風險路徑（`.github/factory/risk-paths.yml`）：增刪匯出名稱即破壞性變更，一律人類審查。

## 6. 測試與驗證如何對應本文件

| 本文件的論述 | 可驗證方式 |
| --- | --- |
| 全部行為性描述 | 引用的 `檔案:行號` 就地可查；`README.md` 的使用範例是**可執行契約**——`tests/test_doctests.py::test_readme` 對 Redis db 1 逐一執行 README 的 `>>>` 範例 |
| 測試需要 Redis | `tests/conftest.py:44-52`：session 級 fixture 取 `redis://localhost:6379/<1–15 隨機 db>`；除此之外無其他外部服務 |
| CI 指令 | `.github/workflows/python-package.yml`：`pytest --verbose --cov-config=.coveragerc --cov=pottery --cov=tests`＋mypy／flake8／isort／bandit；**workflow 目前只綁 `master` 分支**（`:6-10`），對 `software-factory` 的 PR 不會觸發——既存缺口，S5 報告 §3.3 已列人類工作項 W7 |
| Linux 開發環境 | README「開發環境（Linux／CI 同款指令）」一節（S6 同 PR 新增；`Makefile:37-54` 的 `make install` 依賴 macOS Homebrew／pyenv，Linux 不適用） |

## 7. 推斷的設計決策（未獲人類確認）

以下由程式碼與測試回推，**全部為推斷**，逐條詳情與證據見 A1 報告 §2.1.6；依 `docs/29` §10.2 不得作為規格來源，僅供人類撰寫業務規則時參考：

1. 一個容器一個 Redis key、值用 JSON，參數一致性留給呼叫者。
2. 容器用樂觀併發（WATCH），鎖與 ID 用 Lua＋多 master quorum。
3. 同步優先、非同步是鏡像（共用 `Scripts` 與類別常數，parity 靠人工維持）。
4. 同步鎖延遲貼近「多數節點」而非最慢節點（`BailOutExecutor`）。
5. 以全域 monkey patch `json.dumps` 換取易用性，接受整個 process 的副作用。
6. 公開 API 集中在 `__init__.py`，以 `__all__` 作為契約代理。

## 8. 已知缺口（本文件不掩蓋）

| 缺口 | 現況 | 出處 |
| --- | --- | --- |
| `python_requires` 3.10 vs CI 3.11–3.15 | 待人類裁定 | §1；S5 §2.3.4 |
| CI trigger 不含 `software-factory` | 人類工作項（H5 guardrail） | §6；S5 §3.3 W7 |
| F1 偶數 master 的 `QuorumIsImpossible` 門檻 off-by-one | 候選發現，待 `agent-fix-bug` | S5 §2.5.1 |
| F2／F3／F4 async parity、共享 key 參數、TTL 選法 | 候選發現，先由 add-tests 釘語意 | S5 §2.5.2–§2.5.4 |
| 無 `CODEOWNERS` | 人類工作項 | S4 §5.8、S5 §7.7 |
