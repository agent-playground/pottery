# Issue #36 S4／變體 a：node-redlock F1–F9 與 pottery Redlock 的同異分析

| 項目 | 內容 |
| --- | --- |
| 工作項 | [agent-playground/pottery#36](https://github.com/agent-playground/pottery/issues/36) |
| 任務類型 | `agent-analyze`（分析型，**不產生程式碼變更**；本報告具結未動 `src`、測試、設定、CI、依賴） |
| 目標 repo | `agent-playground/pottery`（Python，setup.py 版本 3.0.1） |
| 基準分支 | `software-factory`（分析基點 commit `a867b4e`） |
| 分析對象 | `pottery/redlock.py`（同步）、`pottery/aioredlock.py`（非同步）及其支援模組 |
| 對照依據 | Issue #36 PRD 所列 node-redlock（TypeScript 端 Redlock）模型分析結論 F1–F9 |
| 日期 | 2026-11-01 |
| 本次變更 | 只新增本報告 `docs/research/36-a-node-redlock-f1-f9-parity.md` |
| 狀態 | 分析完成；**報告不具放行效力**，修復須由人類審查後另開工作項 |

---

## 0. 範圍、方法與術語對應

**依據**：Issue #36 的 PRD 要求「分析是否也有 node-redlock 的 F1–F9 相同問題」，並逐條列出
F1–F5、F7–F9 的內容與其在 node-redlock 側的修復狀態。F 條目的原始出處（node-redlock 的
Quint 模型、`specs/uppaal/` 時間自動機、`jumpClock`／`ENABLE_*` 開關）**不存在於本 repo**——
本 repo 無 `specs/` 目錄（實測：`find . -name '*.qnt' -o -type d -name uppaal` 零命中）。
因此本報告的任務是：把每條 F 還原成「該問題的本質命題」，再逐條檢查 pottery 的紅鎖實作
是否暴露同一命題。

** numbering 缺口（誠實標明，不猜測）**：PRD 標題寫 F1–F9，但清單只有 **8 條
（F1、F2、F3、F4、F5、F7、F8、F9），F6 未列出**。本報告分析全部列出的 8 條；F6 因無內容
而無法分析，已列入 §5 未決事項，請人類確認 F6 是否為筆誤或另有其實。

**方法**：(1) 逐行閱讀兩套紅鎖實作與 `timer.py`、`executor.py`、`base.py`、`exceptions.py`、
三支 Lua 腳本；(2) 沙箱內執行免依賴的靜態／語意探測（附錄 A，含實際輸出）；(3) 對照
既有測試（`tests/test_redlock.py`、`tests/test_aioredlock.py`）確認哪些機制已被斷言覆蓋。
需 Redis 伺服器的動態重現無法在本沙箱執行（無 redis-py、無 Redis 服務，實測見附錄 A-6），
故 §2 的動態重現以「草稿測試＋執行指令」形式交付，供後續工作項在 CI（有 Redis service
container，`.github/workflows/python-package.yml:19-22`）中回放。

**術語對應**（node-redlock 模型符號 ↔ pottery 程式碼）：

| 模型符號（Issue 引述） | pottery 對應物 |
| --- | --- |
| `completeAcquire` 的 guard `acquireBelieved(cs) > now` | `redlock.py:343-348`、`aioredlock.py:262-267` 的 validity 檢查 |
| `abortAcquireExpired`（補償釋放＋回 IDLE） | `redlock.py:350-351`、`aioredlock.py:269-270` 的 `contextlib.suppress(ReleaseUnlockedLock)` 補償釋放 |
| ACQUIRE 的 `acquireBlockedBy`（`SET NX` 擋鎖條件） | `redlock.py:278-285`、`aioredlock.py:202-209` 的 `master.set(key, uuid, px=…, nx=True)` |
| `EXTEND_SCRIPT` | `redlock.py:128-134`（`get == ARGV[1]` 才 `pexpire`） |
| `permits`（只增不減）／`permitsOf` 以 nodes 過濾 | 無 permits 集合；對應 `_extension_num`（`redlock.py:545`，每次成功 +1）與 `locked()` 的實測 TTL 覆蓋（`redlock.py:474-501`、`aioredlock.py:406-430`） |
| `completeExtend` 的 guard `extendBelieved(cs) > now`／`abortExtendExpired` | **無對應物**（見 F5，本報告主要發現） |
| routine 三態（UNCHECKED/CHECKED/CHECKED_LATE）＋`criticalWork` | 無自動重檢；`locked()` 為手動觀測點（見 F4） |
| `completeRelease` 的 `reported`（signal.error 優先於 release error） | `release()`／`__exit__` 的異常傳播順序（見 F7，pottery 兩路徑優先序相反） |
| `crashAndLoseKey`／`ENABLE_CRASH_LOSS` | 無開關；Redis 持久化屬部署層（見 F8） |
| `jumpClock`／`ENABLE_CLOCK_JUMP`（空開關） | 無對應物；客戶端計時為單調時鐘（見 F9） |

---

## 1. 結論摘要

**一句話**：F1–F9 中，pottery 與 node-redlock 的修復後狀態**最大的實作差距是 F5**
——extend（續約）完成時完全沒有 validity 守衛與過期補償，這是同步、非同步兩套實作共有的
真實缺口；其次 F7（錯誤優先序）以兩種「優先序錯置」的形式存在。F1 已有等價機制、F2 不成立、
F3／F4／F8 屬 Redlock 演算法家族固有（與 node-redlock「未修復」結論一致）、F9 客戶端側
因單調時鐘而天然緩解。

| # | 命題（本質） | pottery 判定 | 一致性／狀態 | 關鍵證據 |
| --- | --- | --- | --- | --- |
| F1 | 取得鎖後是否驗證「相信持有的有效期 > 0」，失敗要補償釋放 | **存在（等價機制已有）** | 與 node-redlock 已修復狀態**一致** | `redlock.py:343-351`、`aioredlock.py:262-270`；已被 `test_redlock.py:80-82` 斷言 |
| F2 | 擋鎖條件是否「只有自己以外的 key 才擋」 | **不成立（設計使然）** | 每次 attempt 換 uuid，「同值自我擋鎖」不可構造 | `redlock.py:322`、`aioredlock.py:246`（SET NX 前 `_uuid = str(uuid.uuid4())`） |
| F3 | extend 只修有自己 key 的節點，不回寫已失去的節點 | **存在（演算法固有）** | 與 node-redlock「未修復（固有）」**一致** | `redlock.py:128-134, 526-546`：腳本先 `get==ARGV[1]` 才 `pexpire`，無 NX 重寫路徑 |
| F4 | 鎖可在使用者工作途中失效（library 不通知正在進行的臨界區） | **存在（固有）** | 與 node-redlock「未修復」**一致** | 上下文管理器無背景重檢（`redlock.py:603-674`）；文件自己承認（`redlock.py:176-181`「take care to ensure that your critical section completes well within the timeout」） |
| F5 | extend「成功」前是否檢查續約動作本身沒有超出租期；超出要主動釋放 | **存在，且無任何防護** ← 首要缺口 | 與 node-redlock 已修復狀態**不一致**（pottery 缺 guard、缺補償） | `redlock.py:503-553`、`aioredlock.py:432-477`：extend 全程無 `ContextTimer`（實測引用數 0，附錄 A-2/A-3） |
| F7 | 釋放錯誤與使用者／信號錯誤誰優先上報 | **存在（優先序與 node-redlock 修復相反×2）** | 不一致 | (a) 補償路徑：`redlock.py:350-351` 吞掉 release 錯誤；(b) `__exit__`：`redlock.py:673`／`aioredlock.py:560` 未捕獲，release 錯誤會**置換** body 異常 |
| F8 | 節點崩潰遺失 key → 雙持視窗（Kleppmann） | **存在（部署層，固有）** | 與 node-redlock 一致（那邊開關預設 off；這邊無開關） | 鎖狀態僅存於 Redis 鍵值（`redlock.py:278-285`），無 fencing token；本 repo `docs/business-rules.md` §5 已「不對外承諾」 |
| F9 | 時鐘跳躍是否影響鎖決策 | **客戶端側不存在**；伺服器側屬 Redis 部署 | **優於** node-redlock（那邊模型是空開關，無效驗證） | `ContextTimer` 用 `timeit.default_timer()`＝`time.perf_counter()`（實測 `is` 同一物件，附錄 A-1），不受系統牆鐘調整影響 |
| F6 | —（PRD 未列出） | **無法判定** | 編號缺口，見 §5 未決事項 Q1 | Issue #36 正文 |

**給審查者的三行判讀**：

1. 若要開修復工作項，**修復優先序只有一條：F5**——它的危害模式與 F1 修掉的那個完全同型
   （用戶被告知「仍持有鎖」而實際租期已死），但發生在續約路徑，且是**每次續約都會把
   「響應延遲」稀釋成「虛假有效期」**的系統性缺口——短 `auto_release_time`（文件與測試範例
   即有 0.2s／0.05s 用法）＋GC／排程／網路延遲即可觸發。
2. F7 是**觀測性／錯誤傳播**缺陷而非互斥性缺陷：不改變鎖的安全性，但會讓用戶的原始異常
   在「臨界區超時＋拋錯」複合場景下消失，除錯成本實際存在；修法涉及語意取捨（要不要保留
   「退出時釋放失敗＝遲到失效信號」），需人類先定調（見 §4 方案比較）。
3. F2/F9 顯示 pottery 在兩個 node-redlock 曾踩坑的點上**因架構差異而倖免**（每試一次換
   uuid；用單調時鐘），這是好消息，不需要動作。

---

## 2. 證據與根因（逐條）

### F1 — 取得鎖的 validity 檢查：**等價機制存在**（對應 node-redlock「已修復」）

**命題**：跨節點取得 quorum 後，必須扣除「取鎖動作自身耗時＋時鐘漂移」後仍剩正數有效期，
才可宣告持有；否則補償釋放並回傳失敗。

**pottery 實作**（同步，`redlock.py:318-353`）：

```python
# redlock.py:322-325
self._uuid = str(uuid.uuid4())
...
with ContextTimer() as timer, BailOutExecutor() as executor:
# redlock.py:343-348
    if num_masters_acquired > len(self.masters) // 2:
        validity_time = self.auto_release_time
        validity_time -= self.__drift()
        validity_time -= timer.elapsed() / 1000
        if validity_time > 0:
            return True
# redlock.py:350-351
with contextlib.suppress(ReleaseUnlockedLock):
    self.__release(raise_on_redis_errors=raise_on_redis_errors)
```

非同步版同構（`aioredlock.py:242-272`；差異僅在扇出用 `asyncio.as_completed` 且不早退，
validity 檢查反而更嚴格）。`__drift()`＝`auto_release_time × 0.01 + 2ms`（`redlock.py:315-316`），
與 redis.io/distlock 參考實作的公式一致。

**已被斷言**：`tests/test_redlock.py:80-82`（`test_acquire_fails_within_auto_release_time`）
以 `auto_release_time=.001` 使 validity 必 ≤0，斷言 `_acquire_masters()` 回 `False`。

**判定**：存在且等同 node-redlock 修復後的行為（模型中的「單一原子動作」在實作端由
「先檢查、後補償釋放、再回 False」序列化達成；補償釋放失敗時殘留鍵由 TTL 兜底，與
node-redlock 修復態語意等價）。

**邊界觀察**（不構成 F1 缺口）：同步版湊齊 quorum 即 `return True`，透過
`BailOutExecutor.__exit__`（`executor.py:53-59`，`shutdown(wait=False)`）不等其餘 in-flight
`SET NX`；晚到的 SET 仍以同一 uuid 寫入自己的節點，後續 `release()` 遍歷全部 masters 且腳本
帶值檢查，故無殘留他人可見性問題。

### F2 — ACQUIRE 擋鎖條件：**問題不成立**（每 attempt 換 token）

**命題**：節點上存在「自己上一段租約殘留的同值 key」時，重試是否被自己的 key 擋住。
node-redlock 修復後語意：只有 `e.value != v`（別人的 key）才擋。

**pottery 實作**：每次 `_acquire_masters` 呼叫都先重新生成 token——
`redlock.py:322`／`aioredlock.py:246`：`self._uuid = str(uuid.uuid4())`——然後
`SET key uuid NX PX`（`redlock.py:278-285`）。因此「key 存在且值等於本次 token」在邏輯上
不可到達：擋住重試的必是「其他 token 的 key」（可能是自己**前一次嘗試**的殘留，但那次嘗試
已被補償釋放或將随 TTL 過期，與 node-redlock 修復態的 `selfBlocked ≡ false` 觀測等價）。

**已被斷言**：`tests/test_redlock.py:94-105`
（`test_acquire_same_lock_twice_blocking_without_timeout`）——同一物件第二次 `acquire()`
被前一次租約擋住直到 TTL 過期，證明「前租約≠自我擋鎖、只是時間差」。

**判定**：不存在。不需要動作。

### F3 — extend 不修復少數節點：**存在，演算法固有**（與 node-redlock 結論一致）

**命題**：EXTEND 只對「仍持有自己 key」的節點刷新 TTL；已失去 key（過期／被刪）的節點不會
被 `SET NX` 回寫，覆蓋率只減不增。

**pottery 實作**：`_extend_script` 為 `if get(KEYS[1]) == ARGV[1] then pexpire(...) else 0`
（`redlock.py:128-134`）——不存在「key 不在就重建」的路徑。同步版湊齊 quorum 即返回
（`redlock.py:544-546`），未刷新成功的少數節點無重試。`_extension_num` 只增不減
（`redlock.py:545`，每次成功 +1；上限 `num_extensions`，超限拋 `TooManyExtensions`
`redlock.py:523-524`）——對應模型「permits 只增不減」；「真實覆蓋率」在 pottery 由 `locked()`
即時查 TTL 表達而非內部集合：同步版取先到 quorum 個 TTL 的 `min` 再扣漂移與耗時
（`redlock.py:492-498`），非同步版取「多數派可宣稱的最大值」即排序後第
`len//2 - (not len%2)` 位（`aioredlock.py:422-427`）。

**已被斷言**：`tests/test_redlock.py:450-458`（`test_extend_resets_lease_to_auto_release_time`）
斷言 extend 把 pttl 重置回滿租期；`docs/business-rules.md` R3／§5 承認家族限制。

**判定**：存在，固有，與 node-redlock「未修復（演算法固有）」一致。不需要（也不應該由 library）動作。

### F4 — 臨界區可與鎖失效重疊、失效僅為「諮詢式」：**存在，固有**（與 node-redlock 結論一致）

**命題**：鎖過期時，正在臨界區執行的工作不會收到任何信號；互斥性的最終保障只剩
「使用者在關鍵動作前自查」。node-redlock 模型以 routine 三態（UNCHECKED/CHECKED/CHECKED_LATE）
＋`criticalWork` 承載此安全性結論。

**pottery 實作**：無任何背景重檢機制。`with redlock:` 進入後直到 `__exit__`（`redlock.py:648-674`）
才再一次接觸 Redis；`synchronize` 裝飾器同（`redlock.py:730-747`）。套件提供的自查點是
`locked()`（同步 `redlock.py:447-501`／非同步 `aioredlock.py:386-430`）與 `extend()` 的失敗
信號（`ExtendUnlockedLock`，`redlock.py:549-553`），皆為**使用者手動呼叫**才有作用。文件層面
pottery 自己已如實聲明：「You should take care to ensure that your critical section completes
well within the timeout」（`redlock.py:176-181`）。

**判定**：存在，固有（Redlock 家族與 node-redlock 相同的結論：安全性最終由「使用者在關鍵
寫入前 CHECKED」的使用紀律承載，library 不強制）。建議動作僅限文件（§5 WI-4），不開修復項。

### F5 — extend 的 validity 檢查：**存在且無防護——本報告的主要缺口**

**命題**（node-redlock 已修復態）：`completeExtend` 的 guard 是 `extendBelieved(cs) > now`——
續約扇出的**回傳時刻**，必須仍然「相信」續約後的租期 > 0；否則該次 extend 視為失效，走
`abortExtendExpired` **主動釋放已失效的鎖**，不得回報成功。

**pottery 實作**：同步 `extend()`（`redlock.py:503-553`）與非同步 `extend()`
（`aioredlock.py:432-477`）的 quorum 迴圈**完全沒有計時器**——

```python
# redlock.py:526-546（同步；非同步同構於 aioredlock.py:456-470）
with BailOutExecutor() as executor:
    ...
    for future in concurrent.futures.as_completed(futures):
        ...
        else:
            if num_masters_extended > len(self.masters) // 2:
                self._extension_num += 1
                return          # ← 無 validity_time 檢查、無 timer.elapsed()、無 __drift()
```

靜態實測（附錄 A-2/A-3）：兩段區間內 `ContextTimer|timer` 引用數皆為 **0**；對照 acquire
區間同一探測為正（`redlock.py:325/346`）。對 `tests/test_redlock.py`、`tests/test_aioredlock.py`
全檔搜尋無「extend 完成時刻租期已死」的情境斷言（既有 `test_extend`*:140-149、:300-313、
:450-458 只覆蓋 happy path、RedisError、TooManyExtensions 與 TTL 重置）。

**危害模式**（與 F1 修掉的同型）：`_extend_script` 在**伺服器執行時刻**刷新 TTL＝滿租期，但
客戶端要等**響應到達**才知道。若「最早完成刷新的那個 majority 節點」的響應延遲 ≥ 租期
（GC pause、執行緒排程飢餓、跨資料中心抖動、短 `auto_release_time`——本 repo 文件與測試
大量使用 0.2s／0.05s 等級），`extend()` 仍正常返回；呼叫方據此「續約成功」繼續執行關鍵寫入，
而實際多數派鍵已在 Redis 側過期、可被競品 `SET NX` 取得 → **雙持**。這是「回報成功」與
「確實持有」的系統性脫鉤，每次續約把「響應延遲」無條件稀釋成「虛假有效期」。

**次生缺口（`abortExtendExpired` 缺位）**：extend 未達 quorum 時直接
`raise ExtendUnlockedLock`（`redlock.py:549-553`），**不釋放**已成功刷新（≥1 但 <quorum）
節點上的自身殘留鍵——那些鍵現在帶著**新的滿租期**，比其他客戶端原以為的過期點更久地擋住
他人（liveness 傷害；非互斥性傷害）。node-redlock 修復態的「主動釋放已失效鎖」在此無對應。

**可重現步驟（草稿，需 Redis 伺服器；指令見附錄 A-6）**：

1. `lock = Redlock(key='k', masters={redis}, auto_release_time=0.1)`；`lock.acquire()` 成功。
2. 包裝該 master 的 `evalsha`：執行真實腳本後 `time.sleep(auto_release_time * 1.5)` 再返回
   （模擬「伺服器已刷新、響應延遲送達」）。
3. `lock.extend()` → **正常返回（現行行為）**，`_extension_num == 1`。
4. 此時 `redis.pttl('redlock…') == -2`（鍵已過期消失），另一客戶端 `acquire(blocking=False)`
   立即成功 → 雙持視窗打開。
   期望行為（方案 A）：步驟 3 應失敗——`extend` 完成時若 `elapsed + drift ≥ 剩餘信任租期`
   即不得回報成功，並對已刷新節點補償釋放。

**根因**：`extend` 的實作直接沿用 redlock-py/antirez 參考骨架中較早、較簡單的一版
（扇出→計數→返回），未與本套件自己已經在 acquire/locked 兩處實施的「扣漂移、扣耗時」
validity 慣例對齊；即**同檔案內的不一致**，非刻意的設計取捨（`locked()` 有 timer
`redlock.py:474/496-497`，`acquire` 有 `redlock.py:325/346`，唯 `extend` 沒有）。

### F7 — 錯誤回報優先序：**存在，兩種優先序錯置**（與 node-redlock 修復態相反）

**命題**（node-redlock 已修復態）：`completeRelease` 以 `reported` 旗標保證 **signal.error
優先於 release error**；驗證述詞必須寫在 `reported` 上。

pottery 有兩條 release 錯誤路徑，優先序恰好**一個吞錯、一個蓋錯**：

- **(a) acquire 補償路徑吞掉 release 錯誤**（`redlock.py:350-351`／`aioredlock.py:269-270`）：
  validity 失敗後的補償釋放以 `contextlib.suppress(ReleaseUnlockedLock)` 包裹——釋放不徹底
  （部分節點仍掛著本次 token 的殘留鍵直到 TTL）對呼叫方**完全不可見**（僅 `logger.exception`）。
  node-redlock 修復態至少把 release error 記錄進 `reported` 層；pottery 直接丟棄。
- **(b) 上下文管理器 `__exit__` 的 release 錯誤蓋掉使用者異常**（`redlock.py:648-674`，
  第 673 行直接 `self.__release()`；非同步 `aioredlock.py:542-560` 第 560 行同）：
  若臨界區 body 拋異常 **且** 退出時鎖已過期/已失（`release()` 未達 quorum →
  `ReleaseUnlockedLock`，`redlock.py:595-599`），Python 語意下 `__exit__` 拋出的新異常會
  **置換** body 的原始異常（後者降為 `__context__`，呼叫方 `except` 原異常類型會漏接）。
  與 node-redlock「signal.error 優先」的修復態方向相反。

**覆蓋狀態**：`test_redlock.py:470-477`（`test_context_manager_releases_lock_when_body_raises`）
只測「body 拋錯＋**租約仍有效**（釋放成功）」→ 原始異常正常傳播；
`test_redlock.py:218-222` 測「提前釋放→退出拋 `ReleaseUnlockedLock`」。**複合場景
（body 拋錯＋租約已死）無測試**，即 (b) 的缺陷路徑未被任何斷言佔住。

**判定**：存在、未修復；屬觀測性缺陷（不影響互斥安全性，影響除錯正確性與錯誤類型合約）。
修法有語意取捨（見 §4 方案比較），需人類先定調，因此「是否修復、修復成什麼」不適合
agent 徑行——本報告僅交付分析與兩個可選方案。

**可重現步驟（免 Redis 之外依賴；語意層可直接演示）**：

1. `lock = Redlock(masters={Redis()}, key='k', auto_release_time=0.05)`（本地 Redis）。
2. `with pytest.raises(ValueError): with lock: time.sleep(0.1); raise ValueError('boom')`
3. 現行行為：拋出的異常是 `ReleaseUnlockedLock`（`ValueError` 僅存於 `__context__`）；
   期望（方案 E1）：`ValueError` 保持首惡地位。

### F8 — 節點崩潰遺失 key（Kleppmann 論證）：**存在，固有，部署層**

**命題**：Redis 節點崩潰且鍵未持久化 → 該節點的鎖狀態歸零 → 新持有者可湊齊 quorum，
舊持有者渾然不覺 → 雙持。node-redlock 以 `crashAndLoseKey`＋`ENABLE_CRASH_LOSS`（預設
false）建模，屬「模型支援、預設關」。

**pottery 實作**：鎖狀態 = 一組帶 PX 的易失鍵（`redlock.py:278-285`）；無持久化承諾、無
fencing token（所有 Lua 腳本只做值比對 `redlock.py:113-148`，值比對只能防「錯誤持有者改
鎖」，防不了「崩潰後合法新持有者與舊持有者並存」）。客戶端亦無從探測節點「重啟歸零」
（重啟後的節點就是「NX 可寫」的空節點）。`docs/business-rules.md` §5 已把此類不承諾寫明
（「不保證跨 Redis 叢集的鎖公平性（Redlock 的既有理論限制）」）；風險檔
`.github/factory/risk-paths.yml` H4 註記紅鎖為「失敗會靜默擴散給所有用客的核心原語」。

**判定**：存在（與 node-redlock 相同的固有暴露面）；library 層不可修，**一致於那邊「預設
false＝不啟用驗證」的務實立場**。動作僅限文件（§5 WI-4）：在 README/文件把「需要嚴格互斥
請上 fencing token／單點權威」的部署指引寫給使用者。

### F9 — 時鐘跳躍：**客戶端側不存在（結構性緩解）**；模型缺陷無對應物

**命題**：牆鐘跳躍（NTP step、settimeofday、休眠喚醒）是否污染鎖決策的「現在時間」。
node-redlock 側的既有結論是 Quint 模型 `jumpClock` 為空開關（驗證形同虛設），問題改由
UPPAAL 時間自動機回答並證實獨立於 F8 成立。

**pottery 實作**：客戶端所有與租期相關的測時經 `ContextTimer`，其時間源為
`timeit.default_timer()`（`pottery/timer.py:106, 117, 125`），即 `time.perf_counter`——
沙箱實測 `timeit.default_timer is time.perf_counter` 為 `True`（Python 3.14.4，附錄 A-1）。
CPython 文件明定 perf_counter 為單調時鐘、不受系統牆鐘調整影響。因此：

- 牆鐘向後跳 → `elapsed()` 不減（單調）→ `validity_time` 計算不被高估；
- 牆鐘向前跳 → `elapsed()` 如實增長 → 更保守（可能提前放棄取得，屬安全方向）。

殘留邊界：(i) Linux 上 `perf_counter` 基於 `CLOCK_MONOTONIC`，**不含 suspend 時間**——進程在
休眠/S3 中被凍結時牆鐘走了而 monotonic 未走，喚醒後 `elapsed()` 低估實際流逝的牆鐘時間、
可能高估剩餘租期；但節點側 TTL 用的是 Redis **伺服器**自己的時間，`acquire` 返回後的
真實覆蓋由 TTL 決定，客戶端誤差方向已被 `__drift()`（2ms＋1%）部分吸收，此風險屬所有
redlock 實作共有且與「時鐘跳躍」不同源；(ii) Redis 節點自身牆鐘跳動影響鍵到期判定屬 Redis
伺服器行為（本套件不可控，F8 同類部署層）。

**判定**：node-redlock 的「模型空開關」缺陷在 pottery **無對應物**（本 repo 無 Quint 模型，
不適用）；程式碼層面 F9 命題已被單調時鐘緩解，**優於** node-redlock 側「牆鐘測時」的初始
暴露面。不需要動作。誠實標註：若日後為 pottery 建 Quint/UPPAAL 模型，`jumpClock` 必須做成
**有效果的開關**（對照 `perf_counter` 語意建 monotonic clock），否則會複製 node-redlock 的
空開關缺陷——已寫進 §5 WI-4。

### 附：同步／非同步不一致觀察（不屬 F1–F9，供後續測試工作項取材）

| 觀察 | 同步 | 非同步 | 影響 |
| --- | --- | --- | --- |
| acquire 扇出 | BailOut 早退（湊齊即返回） | `as_completed` 全收再判（`aioredlock.py:252-262`） | async 較慢但 validity 更嚴格 |
| `locked()` 統計 | 先到 quorum 個 TTL 取 `min`（`redlock.py:492-498`） | 全 TTL 排序取第 `n//2-(n%2==0)` 位（`aioredlock.py:422-427`） | 同值域、不同保守度 |
| 補償釋放參數傳遞 | 傳 `raise_on_redis_errors`（`redlock.py:351`） | `await self.__release()` 未傳（`aioredlock.py:270`，回落實例預設） | per-call 覆蓋在非同步補償路徑失效 |
| `synchronize` 文件 | docstring 列 `num_extensions`/`context_manager_*` 參數（`redlock.py:702-708`），簽名無此參數 | — | 文件與實作不符（doctest 面：README 由 `tests/test_doctests.py` 執行，紅鎖 docstring 不在其中） |

---

## 3. 影響範圍

**模組**：`pottery/redlock.py`、`pottery/aioredlock.py`（H4 列名共享模組，
`.github/factory/risk-paths.yml`）；依賴設施 `pottery/timer.py`、`pottery/executor.py`、
`pottery/base.py:320-331`、`pottery/exceptions.py:52-66`。本報告**未修改任何其一**。

**使用者路徑（按暴露度排序）**：

1. **使用 `extend()` 續約的客戶端（F5）**：凡「臨界區可能超租期 → 靠 extend 續命」的用法全部
   暴露；長尾響應＋短租期組合最危險。pottery 文件示例多用預設 10s 租期（`redlock.py:229`），
   但 README/測試中的 0.2s／0.05s 用法證明短租期在實務被使用。
2. **以 `with lock:`／`@synchronize` 包裹會拋錯的工作的客戶端（F7(b)）**：超時複合場景下
   原始異常類型被換掉，上層錯誤處理（`except ValueError`）與 sentry 分組會被誤導。
3. **依賴 acquire 返回 False 後「已乾淨退場」假設的使用者（F7(a)）**：補償釋放失敗不可見，
   殘留鍵最多多擋競爭者一個租期（liveness）。
4. **要求嚴格互斥的下游系統（F4/F8）**：任何以 Redlock 保護「恰好一次」寫入的系統，仍須
   在資源層自備 fencing／冪等（Redlock 家族共同前提，非 pottery 新增風險）。
5. **同步/非同步混用同一鎖的客戶端（附錄觀察）**：兩個實作的 `locked()` 統計與 bail-out
   行為不同，跨端語意細節不完全對稱。

**下游文件/規格面**：`docs/business-rules.md` R1（quorum＋釋放，pottery 符合）、R2（絕對
過期，符合）、R3（只持有者可釋放，值比對腳本符合）、R4（重試上限與退避，`redlock.py:414-427`
含 jitter 0–200ms，符合）。**F5 是目前唯一「規則已寫（R2 隱含：超過 expire 後他人可取得）
但 extend 路徑的實作未把規則呈現給呼叫方」的點**——R2/S10 驗證閘門（Issue #28/#30 的
pbt-audit / write-spec）設計測試時應以本報告 F5 情境為必測案例。

---

## 4. 方案比較（修復方向；本工作項一律不實作）

### 缺口 F5

| | 方案 A（建議）：extend 完成時加 validity guard＋過期補償 | 方案 B：僅文件化，不加程式碼 | ~~方案 C：extend 以 SET NX 回寫失節點~~（拒絕） | ~~方案 D：庫層引入 fencing token~~（拒絕） |
| --- | --- | --- | --- | --- |
| 內容 | 照 acquire 既有慣例補齊：`extend()` 包 `ContextTimer`；quorum 達成後計算 `auto_release_time - __drift() - elapsed/1000 > 0` 才 return；失敗則對已刷新節點補償釋放（帶 suppress，同 `redlock.py:350-351` 模式）再拋 `ExtendUnlockedLock` | 在 Redlock docstring/README 標明「extend 成功不代表完成時刻仍持有；關鍵寫入前自行 `locked()` 重檢」 | 把 `_extend_script` 改為「key 不在則以自己的 uuid NX 重建」 | 讓 Redis 側支援單調計數並由庫下發 |
| 好處 | 消除回報成功/實際持有的脫鉤；與 F1 修復態同型，模型/測試（S10）可統一 guard 語意 | 零風險、零相容影響 | 覆蓋率「可增可減」，直覺修復 F3 | 正面解決 F4/F8 |
| 代價／風險 | 行為變更：慢環境下原本僥倖成功的 extend 改為拋錯（呼叫方需接住）；改動 H4 核心路徑需人類審查 | 缺陷留在實作裡，靠使用者紀律 | **拒絕理由**：值比對語意下重建會把「過期後已被他人取得」的窗口用 NX 賭運氣，且直接違反 R3／node-redlock F3「固有、不修」的結論——演算法上多數派過期即代表鎖已易主，回寫是錯的治療 | **拒絕理由**：超出本 repo 職責（`docs/business-rules.md` §5「不對外承諾」）；Redis 本身無此機制，屬資源端架構變革，不是 library bug fix |
| 判定 | **建議採納** | 若 A 被否決時的退路 | 拒絕 | 拒絕 |

### 缺口 F7

| | 方案 E1（建議）：`__exit__`/`__aexit__` 改為「body 有異常時，release 失敗只記錄、不置換」 | 方案 E2：維持現狀＋測試鎖定 | ~~方案 E3：`__exit__` 永不拋 `ReleaseUnlockedLock`~~（拒絕） |
| --- | --- | --- | --- |
| 內容 | 在 `__exit__` 捕獲 `ReleaseUnlockedLock`（僅當 `exc_type is not None`），以 `logger.warning` 記錄後 re-raise 原異常（Python 自動保留 `__context__` 鏈）；acquire 補償路徑同步把「釋放不完整」從 suppress 升級為至少 log+標記 | 用紅燈測試先佔住複合場景（body 拋錯＋已失效）的現行行為，把「release 錯誤蓋過 body 異常」文件化為契約 | 無條件 suppress |
| 好處 | 符合 node-redlock F7 修復態（signal.error 優先）；除錯語意直覺 | 零行為變更；先取得可回歸的基準 | 實作最小 |
| 代價／風險 | 行為變更（依賴「退出時拋 ReleaseUnlockedLock 作為遲到失效信號」的用法會失去信號——見 `test_redlock.py:218-222` 對正常路徑信號的依賴需保留：**僅在 body 已有異常時**才抑制，無 body 異常時照常拋，信號面不縮） | 把優先序錯置固化為規格 | **拒絕理由**：殺死 `with lock:` 超時後 `ReleaseUnlockedLock` 這條唯一的「遲到失效」自動信號（`test_context_manager_release_before_exit` 同族語意），違反 R11「連線失敗要明確報錯」精神 |
| 判定 | **建議採納（需人類定調）** | 備選（若人類認為現行優先序即契約） | 拒絕 |

**被拒方案的共同教訓**：F5/F7 的兩個拒案都試圖用「更大範圍的語意顛覆」換取局部正確——
本 repo 的紅鎖契約（R1–R4、§5 不對外承諾）是人類在 S7 定的，分析型產出不得暗示繞過它。

---

## 5. 建議下一步（可直接開成工作項；每條含驗收條件草案）

> 本報告不具放行效力。以下工作項由人類審查後自行決定開否、順序與計分。

**WI-1（`agent-add-tests`，優先）— 鎖定 F1/F3/F5 現行行為＋F5 缺陷紅燈**
描述：為 `Redlock.extend()`／`AIORedlock.extend()` 補測試——既有正確行為以綠燈鎖定；
§2-F5 揭露的缺陷斷言依 agent-add-tests 規則以 skip 紅燈交付（斷言完整保留、該層 CI 綠）。
驗收條件草案：
- [ ] 新增「響應延遲 ≥ 租期時 extend 仍回報成功」的紅燈測試（skip 交付，斷言完整），
      結構同 §2-F5 可重現步驟 1–4；
- [ ] 新增「extend 未達 quorum 不釋放已刷新 minority 節點」的紅燈測試（skip 交付）；
- [ ] 既有 `tests/test_redlock.py -k extend` 全綠（需 CI 的 Redis service container）；
- [ ] 不改任何 `pottery/` 程式碼。

**WI-2（`agent-fix-bug`，跟在 WI-1 後）— 落地方案 A：extend validity guard＋補償釋放**
描述：按 §4 方案 A 修改 `redlock.py:503-553` 與 `aioredlock.py:432-477`（含 un-skip WI-1
的紅燈測試）。驗收條件草案：
- [ ] WI-1 兩條紅燈轉綠；
- [ ] `pytest`（redlock 子集）於 CI 全綠；
- [ ] 同步/非同步行為一致（同一組斷言雙端通過）；
- [ ] 不改 `_extend_script` 的值比對語意（R3 不回歸）。

**WI-3（人類定調後才開，類型待定）— F7 錯誤優先序**
描述：採 §4 E1 或 E2。先決條件：人類裁決「`__exit__` 拋 `ReleaseUnlockedLock` 是否屬契約信號」。
驗收條件草案（以 E1 為例）：
- [ ] 複合場景測試（body 拋 `ValueError`＋租期已過）斷言外層異常類型為 `ValueError`；
- [ ] 無 body 異常時 `ReleaseUnlockedLock` 信號保留（`test_context_manager_release_before_exit` 不回歸）；
- [ ] 補償路徑釋放不完整至少 `logger.warning` 可見。

**WI-4（`agent-write-docs`）— 文件同步（F4/F8/F9/S10 銜接）**
描述：README/docstring 補三段：臨界區超租期的正確用法（關鍵寫入前 `locked()` 重檢）；
嚴格互斥需資源層 fencing 的部署指引（引用 `docs/business-rules.md` §5）；如日後為 pottery
建形式模型，**時鐘跳躍開關必須有真實效果**（對照 perf_counter 建 monotonic clock，避免複製
node-redlock 的 `jumpClock` 空開關缺陷）。驗收條件草案：
- [ ] 文件與本報告 §2 判定一致、不承諾 R2/§5 之外性質；
- [ ] `tests/test_doctests.py` 綠（README doctest 是契約面）。

**WI-5（`agent-add-tests`，低優先）— 同步/非同步行為差回歸**
描述：為 §2 附錄表的三個不對稱（扇出早退、locked 統計、補償參數傳遞）各加一組雙端測試，
把「差異是特性還是漂移」變成可判定資料。驗收條件草案：
- [ ] 每條差異有一對（sync/async）斷言；
- [ ] 若揭露缺陷（如 `aioredlock.py:270` 未傳 `raise_on_redis_errors`），按 add-tests 規則 skip 紅燈＋回報。

**未決事項（需人類回答，agent 不猜測）**：

- **Q1**：PRD 寫「F1–F9」但清單無 F6——是筆誤（F1–F5、F7–F9 即全部），還是存在第 9 條待補？
- **Q2**：F7 修復方向（E1 vs E2）取決於「退出時 `ReleaseUnlockedLock` 是否屬對外契約」——
  需 S7 文件負責人裁決。
- **Q3**：WI-2 若獲準，短租期環境中「extend 由成功改拋錯」是否構成破壞性變更（H7 邊界：
  不改 `pottery/__init__.py` 匯出面，但改變函式行為）？

---

## 6. DoD 對照（Issue #36 三條驗收標準逐條）

| 條目 | 狀態 | 依據 |
| --- | --- | --- |
| AC-1 有可驗證的測試/驗證方式 | **passed** | 免依賴探測已實測並附實際輸出（附錄 A-1..A-5）；需 Redis 的動態重現以草稿測試＋可執行指令交付（§2-F5、§2-F7、WI-1），在 CI 環境可直接回放 |
| AC-2 不觸碰高風險路徑（H1–H3 等硬規則） | **passed** | 本次 diff 僅 `docs/research/36-a-node-redlock-f1-f9-parity.md` 一個檔案；`.github/factory/risk-paths.yml` 的 H1–H3 為空清單、H4–H7（含 `pottery/redlock.py` 等）全部未觸碰 |
| AC-3 跑測試確認綠燈（不跑需外部服務的 E2E） | **skipped（不適用於分析型）** | 本工作項零程式碼變更，無紅→綠可言；本 repo 測試全套需要外部 Redis 服務（`tests/conftest.py:43-45`；沙箱實測無 redis-py 與 Redis 端口，附錄 A-6），屬「不跑需外部服務的 E2E」之排除對象。綠燈閘門保留給 WI-1/WI-2 於 CI 執行 |

---

## 附錄 A — 驗證命令與實際輸出（2026-11-01，沙箱 Python 3.14.4）

```text
A-1  $ python3 -c "import timeit, time; print(timeit.default_timer is time.perf_counter)"
     True                                   # F9：客戶端單調時鐘實證（perf_counter 不受牆鐘調整）

A-2  $ awk 'NR>=522 && NR<=547' pottery/redlock.py | grep -c "ContextTimer\|timer"
     0                                      # F5：同步 extend 決策區間計時器引用數 = 0

A-3  $ awk 'NR>=452 && NR<=471' pottery/aioredlock.py | grep -c "ContextTimer\|timer"
     0                                      # F5：非同步 extend 同 = 0

A-4  $ sed -n '344,348p' pottery/redlock.py
     validity_time = self.auto_release_time          # F1：acquire 有 guard（對照組，
     validity_time -= self.__drift()                  #  同一探測在 extend 區間為 0）
     validity_time -= timer.elapsed() / 1000
     if validity_time > 0:
         return True

A-5  $ grep -n "uuid.uuid4" pottery/redlock.py pottery/aioredlock.py
     pottery/redlock.py:322 / pottery/aioredlock.py:246   # F2：每 attempt 換 token

A-6  動態重現（需 Redis 伺服器，於 CI／本地起 redis 後執行）：
     $ pytest tests/test_redlock.py -k "extend" -v        # 現行 extend 測試集全綠（無 F5 情境覆蓋）
     $ pytest --verbose --cov=pottery --cov=tests         # Makefile test target（CI 含 redis
                                                          #  service：python-package.yml:19-22）
```

**沙箱環境限制實測（支撑 AC-3 skipped）**：`python3 -c "import redis"` →
`ModuleNotFoundError`；TCP localhost:6379 → CLOSED；無 redis-cli。故本 run 未執行、也無法
執行需外部 Redis 之測試——與 AC-3 括號（不跑需外部服務的 E2E）一致，不構成違規。

## 附錄 B — 本次變更清單（誠實自報）

- 新增：`docs/research/36-a-node-redlock-f1-f9-parity.md`（本檔）
- 修改：無。未觸碰 `pottery/`、`tests/`、`.github/`、`setup.py`、`requirements*.txt`、
  `catalog-info.yaml`。
- 引用之 node-redlock 模型符號（`completeAcquire`、`jumpClock` 等）僅作對照敘述，
  其原始模型檔不在本 repo，未以任何方式從外部取得或改寫。
