# pottery Redlock — Lean 驗證規則（G1 轉錄）

> 本檔是 Lean 階段（ADR-029 §5 階段③）的規則輸入。規則本身已在 G1 確認，
> 本檔只**轉錄**，不重新訪談、不修改規則文字；來源是唯讀的
> `specs/quint/RULES.md`、`specs/quint/GRILL-ANSWERS.md` 與 G2 的
> `specs/quint/TRIAGE.md`。輸出語言：繁體中文（zh-Hant）。

- **模組／入口點：** `pottery/redlock.py`（同步 Redlock）、`pottery/aioredlock.py`（非同步對照）；唯讀。
- **Owner：** philipz
- **Confirmed by：** philipz，2026-11-03；G1 答案見 `specs/quint/GRILL-ANSWERS.md`（A1、A3），G2 反例分類見 `specs/quint/TRIAGE.md`（actor `philipz`，`2026-11-03T00:27:25.123Z`）。
- **Status：** `confirmed`（G1）；Lean 定理敘述等待 G3 簽核。
- **Acceptance：** headline 定理敘述完整且 `lake build` 通過；G3 簽核後，proofs 階段零 `sorry`、零新 axiom、`verify-lean.sh` 全綠，且 `MODEL-MAP.md` 的 statement snapshot 未經核准變更。
- **G3 sign-off：** 見 `specs/lean/G3-SIGNOFF.md`（服務端於 G3 簽核後寫入）

## 來源與轉錄範圍

| 來源 | 用途 |
|---|---|
| `specs/quint/RULES.md` | G1 確認的 ENV／INV／ACT／OUT；本文逐條轉錄與 Lean 相關者 |
| `specs/quint/GRILL-ANSWERS.md:6-54` | A1（有效持有語意）、A3（extend 完成檢查與補償）、A4（不重 SET 少數節點）、A5（fencing 範圍外）、A6（同步語意為契約） |
| `specs/quint/TRIAGE.md` | G2 判定：`as_is_extend_success_without_validity`、`as_is_late_extend_no_compensation` 兩條 `toLean = yes`，皆 `real`、`security = no` |
| `specs/quint/traces/as_is_extend_success_without_validity.itf.json` | CF-1 的 ITF 來源 trace |
| `specs/quint/traces/as_is_late_extend_no_compensation.itf.json` | CF-2 的 ITF 來源 trace |
| `pottery/redlock.py`、`pottery/aioredlock.py`、`pottery/timer.py`、`pottery/executor.py` | `file:line` 證據；base commit `2d7c70a` |

G2 只把上述兩條反例送進 Lean；本階段**沒有**把 INV-9（`locked()`）、INV-10（例外優先序）或其他候選發現轉成 headline theorem。這不是重新分類，只是 Lean 階段的範圍切分（見「明確不驗證」）。

## 環境假設（ENV）

- **ENV-1（confirmed）叢集與 quorum：** 5 個獨立 Redis master；quorum 是嚴格多數 `floor(5/2)+1 = 3`，對應 `num_masters_* > len(masters)//2`。證據：`pottery/redlock.py:343`、`pottery/redlock.py:544`、`pottery/redlock.py:591`、`README.md:331-335`。
- **ENV-2（confirmed）時間：** 客戶端以單調時鐘計時（`timeit.default_timer()`）；drift 為 `auto_release_time*0.01 + 0.002` 秒，本實例 `ART=200 ms` 時為 `4 ms`。伺服器時鐘跳躍不建模。證據：`pottery/timer.py:106`、`pottery/timer.py:123-127`、`pottery/redlock.py:315-316`。
- **ENV-3（confirmed）Redis 原子性：** 單一 master 的單一 key 操作線性一致；`SET NX PX` 與三個 Lua 腳本各自原子，腳本先比對 token。證據：`pottery/redlock.py:113-148`、`pottery/redlock.py:278-285`。
- **ENV-4（confirmed）Redis 錯誤：** 個別 master 可失敗；預設 `raise_on_redis_errors=False`。Lean 模型把失敗抽象成「該命令未生效」，不建模 `RedisError` 事件（A-4）。證據：`pottery/base.py:320-331`、`pottery/redlock.py:238`、`pottery/redlock.py:332-341`。
- **ENV-5（confirmed）租期：** master 在 PTTL 到期後刪除 key；模型以 `now < expiry` 表示 key 仍存在。證據：`pottery/redlock.py:282`、`pottery/redlock.py:447-501`。
- **ENV-6（confirmed）續約次數：** 每次成功 acquire 重置計數；預設上限 3。證據：`pottery/redlock.py:232`、`pottery/redlock.py:322-323`、`pottery/redlock.py:523-524`、`pottery/redlock.py:545`。
- **ENV-7（confirmed）資料持久性與 fencing：** 租期內 master 不重啟、不遺失 key；沒有 fencing token；節點資料遺失下的嚴格互斥不在承諾內（G1 A5、OUT-1）。證據：`pottery/redlock.py:128-148`、`specs/quint/GRILL-ANSWERS.md:42-46`。
- **ENV-8（confirmed）臨界區長度：** 呼叫端負責在有效期內結束臨界區；library 不通知、不中止超期臨界區（G1 A1、OUT-2）。證據：`README.md:369-375`、`specs/quint/GRILL-ANSWERS.md:10-14`。

### Lean 建模假設（assumption）

- **A-1（assumption）操作時序抽象：** 每個 acquire/extend/release 有 `delay`；master 端效果放在操作開始，完成時間是 `start + delay`。這代表「命令已在開始時執行、回應在完成時才被讀到」的一種可達交錯；程式沒有對 extend 設 timer，所以沒有可寫成 `deadline - now` 的明確上界可以約束它。Lean 只證明模型；真實網路是否走到此交錯，Lean 沒有證明（見 `REPORT.md` §4）。
- **A-2（assumption）固定實例：** 本階段固定 `n=5`、`ART=200 ms`、`DRIFT=4 ms`、`NUM_CLIENTS=2`、`MAX_OP_DELAY=205 ms`，與 Quint 的 `as_is` 實例一致。程式沒有這些上限；固定實例只讓 witness 具體化，不代表通用證明。
- **A-3（assumption）token 抽象：** token 以 `Option Nat` 表示，只保留「相同／不同」與「新鮮配發」的性質；witness 定理不提及 token 數值。
- **A-4（assumption）Redis 錯誤：** 以「命令未生效」抽象（ENV-4）；不建模「命令已生效但回應逾時」。
- **A-5（assumption）同步語意為契約：** 模型採同步 `BailOutExecutor` 的 quorum 即返回語意（G1 A6①）；非同步等待全部 master、`locked()` 的 min/median 差異不建模。
- **A-6（assumption）`locked()` 省略：** G2 沒有把 INV-9 送進 Lean；模型不建 `locked()` 查詢與回報值。
- **A-7（assumption）提早返回後的 in-flight 操作：** 同步 quorum 即返回後，背景 SET／PEXPIRE 可能尚未完成（ENV-11）。模型不建模這些 in-flight 操作；它們只可能留下本 token 的 stale key，不會產生第二個 token，屬 liveness，不影響 INV-1／INV-6 的 counterexample。證據：`pottery/executor.py:53-58`、`pottery/redlock.py:325-348`。

## 規則

### R1 — INV-1：同一時間最多一個有效持有者

- **Statement：** 對任意可達狀態 `s`，`validHolderCount s = |{ c | s.now < beliefEnd(c) }| ≤ 1`。`beliefEnd(c)` 的語意是 G1 A1(b)：`[成功完成 acquire/extend, 該次操作開始 + ART − DRIFT)`。
- **Source of truth：** `specs/quint/GRILL-ANSWERS.md:10-14`（A1 選 b）、`specs/quint/RULES.md` INV-1；程式證據 `pottery/redlock.py:343-348`、`pottery/redlock.py:315-316`。
- **Positive example：** 成功 acquire 後，只有該客戶端在有效期內（`Examples.lean`：`validHolderCount w2s3 = 1`）。
- **Negative example（violation）：** 兩個不同客戶端同時在各自 `beliefEnd` 之前，且各自持有多數 token；這被多數交集 + `SET NX` 排除。
- **Boundaries：** 初始狀態（0 個持有者）、release 成功（beliefEnd 歸零）、租期到期（`now ≥ expiry`）、失敗 acquire（beliefEnd 歸零）、as-is 晚完成 extend（beliefEnd 可能已過）。
- **Lean：** `Redlock.at_most_one_valid_holder`；模型定義 `validHolderCount`、`ReachableAsIs`。

### R2 — INV-6 第一句：extend 成功需 quorum 且完成時仍在有效期內

- **Statement：** 若 `extend` 回報成功，則（a）嚴格多數 master 的 `PEXPIRE` 成功，且（b）完成時 `completion < start + ART − DRIFT`。**As-is 現況違反 (b)**：`pottery/redlock.py:526-546` 只在 quorum 時遞增計數並返回，沒有計時、沒有完成檢查。
- **Source of truth：** `specs/quint/GRILL-ANSWERS.md:26-30`（A3「是」）、`specs/quint/RULES.md` INV-6／ACT-9；G2 反例 `as_is_extend_success_without_validity`（`specs/quint/TRIAGE.md`，`toLean = yes`）。
- **Positive example：** `applyExtend true` 在 `start=267`、`delay=0` 時成功，`267 < 267+196`（`Examples.lean`）。
- **Negative example（violation）：** CF-1：`start=1133`、`finish=1338`、`beliefEnd=1329`，as-is 仍回報成功；Lean 定理 `as_is_late_extend_reports_success`。
- **Boundaries：** `finish = start + ART − DRIFT`（恰在邊界，應失敗）、`quorum` 恰好 3、`extensions = NUM_EXTENSIONS`（TooManyExtensions，不送命令）、token 為空（未持有）、`delay` 0 與 `MAX_OP_DELAY`。
- **Lean：** `Redlock.as_is_late_extend_reports_success`（as-is 反例）、`Redlock.contract_extend_success_implies_validity`（契約）。

### R3 — INV-6 補償句：晚完成或失敗的 extend 要釋放已續約節點

- **Statement：** 若 `extend` 未達 quorum 或完成時已超出 A3 有效期，則對**所有仍持有本 token 的節點**執行 token 比對的 release（只刪 token 相符的 key）；補償失敗只記錄，最後拋 `ExtendUnlockedLock`。**As-is 現況違反**：`pottery/redlock.py:548-553` 沒有補償。
- **Source of truth：** `specs/quint/GRILL-ANSWERS.md:26-30`（A3）、`specs/quint/RULES.md` INV-6／ACT-10；G2 反例 `as_is_late_extend_no_compensation`（`specs/quint/TRIAGE.md`，`toLean = yes`）。
- **Positive example：** `applyExtend true` 在 `start=267`、`delay=198` 時失敗，補償後 `holders = 0`（`Examples.lean`）。
- **Negative example（violation）：** CF-2：`start=267`、`finish=465`、`beliefEnd=463`，as-is 回報成功且 3 個 master 仍持有 token；Lean 定理 `as_is_late_extend_no_compensation`。
- **Boundaries：** 失敗原因是 quorum 不足或完成超期；補償對象包含本次 PEXPIRE 成功與未成功但仍持有 token 的節點；補償本身失敗只記錄（本模型不建模補償失敗，A-4）。
- **Lean：** `Redlock.as_is_late_extend_no_compensation`（as-is 反例）、`Redlock.contract_late_extend_compensates`（契約）。

### R4 — INV-2（支撐 R1）：acquire 成功需 quorum 且完成時有效

- **Statement：** acquire 回報成功只有嚴格多數 `SET NX` 成功，且完成時 `finish < start + ART − DRIFT`。
- **Source of truth：** `specs/quint/RULES.md` INV-2／ACT-3；`pottery/redlock.py:343-348`、`pottery/aioredlock.py:262-267`。
- **Positive example：** trace 2 的 `w2s3`：3 個 SET 成功、`267 < 239+196`。
- **Negative example（violation）：** 2 個 SET 成功卻回報成功；或 `finish ≥ start+196` 仍回報成功。
- **Boundaries：** 同步 quorum 即返回（`chosen` 可為任何 free 子集）、失敗補償、`validity = 0`。
- **Lean：** 由 `applyAcquire` 定義與 `StepAsIs` 的 `chosen` 條件轉錄；沒有獨立 headline theorem（它支撐 R1）。

### R5 — INV-8（支撐模型）：release 成功需 quorum

- **Statement：** release 對所有 master 執行 token 比對的 `DEL`；只有嚴格多數刪除成功才回報成功，否則拋 `ReleaseUnlockedLock`。
- **Source of truth：** `specs/quint/RULES.md` INV-8／ACT-11；`pottery/redlock.py:573-599`、`pottery/aioredlock.py:496-516`。
- **Positive example：** 持有 3 個 token key 時 release，`dels = 3 ≥ quorum`。
- **Negative example（violation）：** 只刪到 2 個 key 卻回報成功。
- **Boundaries：** release 會刪除所有 token 相符的 key（即使少於 quorum），但只有 quorum 才回報成功；release 失敗不改 beliefEnd（但若仍有效，模型的不變量要求它仍持有 quorum）。
- **Lean：** `applyRelease`；沒有獨立 headline theorem（它支撐 R1）。

## G1／G2 轉錄紀錄

| # | 問題 | 答案 | 出處／日期 |
|---|---|---|---|
| A1 | 「有效持有」以哪個時點為準？ | (b) `acquire`/`extend` 成功後，依 `ART − drift − elapsed` 算出的截止前 | `specs/quint/GRILL-ANSWERS.md:10-14`；2026-11-03 |
| A3 | extend 完成檢查與補償範圍？ | 是；quorum + 完成時有效；否則補償所有仍持有 token 的節點 | `specs/quint/GRILL-ANSWERS.md:26-30`；2026-11-03 |
| A4 | 少數節點遺失 key 時 extend 要重 SET 嗎？ | 不；設計取捨（OUT-3） | `specs/quint/GRILL-ANSWERS.md:34-38`；2026-11-03 |
| A5 | 節點重啟／fencing 納入模型嗎？ | 不；設計取捨／範圍外（OUT-1） | `specs/quint/GRILL-ANSWERS.md:42-46`；2026-11-03 |
| A6 | 同步／非同步差異？ | 以同步語意為契約；`locked()` 只要求安全上界 | `specs/quint/GRILL-ANSWERS.md:50-54`；2026-11-03 |
| G2 | 哪些反例送 Lean？ | `as_is_extend_success_without_validity`、`as_is_late_extend_no_compensation`；皆 `real`、`security = no` | `specs/quint/TRIAGE.md`；2026-11-03 |

## 明確不驗證（Lean 階段）

- **OUT-1（confirmed）無 fencing 的嚴格互斥：** 節點崩潰／重啟遺失 key 的雙持有者；不加入 `MasterRestart`。
- **OUT-2（confirmed）臨界區超期：** library 不通知、不中止；臨界區在有效期內結束是 ENV-8。
- **OUT-3（confirmed）extend 修復少數節點：** 不對遺失 key 的少數節點重新 `SET`。
- **OUT-4（confirmed）跨叢集公平性、代管 Redis 認證、Redis 內部實作、Byzantine、replication/failover、伺服器時鐘跳躍。**
- **OUT-5（confirmed）同步／非同步 `locked()` 的數值相等。**
- **OUT-6（confirmed）liveness／吞吐量／等待時間上界／任意分割下的最終取得。**
- **OUT-7（confirmed）例外訊息與 `redis_errors` 內容。**
- **Lean 階段另外不建模：** INV-9 `locked()`（G2 未送 Lean）、INV-10 例外優先序（控制流，不是鎖狀態）、重試／backoff／timeout（liveness）、非同步等待全部 master 的實作差異、per-master 時序 skew。

## 未決事項（open questions）

1. **G3 簽核：** 本階段只有定理敘述與模型；proofs 尚未開始。G3 是否接受 A-1 的時序抽象作為 witness 的模型邊界？
2. **程式可達性：** Lean 證明的是模型 trace；CF-1／CF-2 依賴 A-1（命令早執行、回應晚到）。Lean 沒有證明真實 Python 執行緒／網路排程會走到這個交錯。
3. **通用性：** 本階段固定 `n=5`、`ART=200 ms`。是否需要在 proofs 階段推廣到任意 `n` 與任意合法 `ART`，或維持 G2 trace 的具體實例即可？

## 變更政策

程式或規則變更導致定理不再成立時，**不得**為了讓證明過關而弱化已確認的定理。應停下、回報哪條規則／哪個 statement 改變，交由 G3／owner 重新確認；proofs 階段不得自行修改 statement snapshot。
