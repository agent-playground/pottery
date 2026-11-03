# Model map — pottery Redlock Lean 驗證帳本

> 本檔是人類／G3 的檢視入口；`verify-lean.sh` 只檢查機械部分。若某個 claim 沒有寫在這裡，就不在覆蓋範圍內。
> 語言：繁體中文（zh-Hant）。

- **Verified at commit：** `2d7c70abdc000e337dfd9e26b0af2a151cdac07d`（`2d7c70a`，2026-10-28，base branch `master`）
- **Rules of record：** `specs/lean/RULES.md`（G1 confirmed 2026-11-03 by `philipz`；轉錄自唯讀的 `specs/quint/RULES.md`）
- **G2 input：** `specs/quint/TRIAGE.md`（actor `philipz`，`2026-11-03T00:27:25.123Z`）
- **Toolchain：** Lean `4.35.0`（`lean-toolchain`：`leanprover/lean4:v4.35.0`）；Mathlib：**no**
- **Phase：** `proofs`（G3 已簽核；5 條 headline theorem 全部證明，專案零 `sorry`）
- **G3 sign-off：** 已簽核，唯一證據 `specs/lean/G3-SIGNOFF.md`：簽核者 `philipz`，時間 `2026-11-03T02:22:53.189Z`，結果 `approved`。
- **Proofs gate（2026-11-03）：** `verify-lean.sh` 全綠：build、direct compile、coverage、guardrail（0 hits）、axiom audit（5/5，僅 `propext`／`Classical.choice`／`Quot.sound`）全 PASS；`metrics-baseline.txt` 與 current 逐項 delta 0。詳見 `REPORT.md` §8。

## Claim boundary（模型層級 vs 程式層級）

- Lean 證明的是 **Lean 模型** `Specs/Model.lean` 的性質，不是 Python 程式本身。
- `MODEL-MAP.md` 的 `file:line` 是模型轉錄的依據；模型與程式的一致性是人審 claim，不是 Lean 證明的結果。
- CF-1／CF-2 的 witness 在 Lean 內**可達**（`reachable_w1s13`、`reachable_w2s4` 已證明），但「真實 Python 執行緒／網路排程會走到該交錯」**沒有**被 Lean 證明；它依賴 A-1 時序抽象。`REPORT.md` §4 明寫此限制。
- **本輪已完成的證明是模型層級：** `at_most_one_valid_holder` 與兩條契約定理都是對 `Specs/Model.lean` 的定理；它們不證明 Python 程式已修好，也不證明真實排程可達 CF-1／CF-2 的交錯。

## Verified sources

| 檔案 | 行 | 模型對應 |
|---|---:|---|
| `pottery/redlock.py` | 278-285 | `SET key token PX ART NX`；`applyAcquire` 的 master 效果 |
| `pottery/redlock.py` | 315-316 | `drift = ART*0.01 + .002`；`Drift = 4`（ART=200 ms） |
| `pottery/redlock.py` | 322-325 | 新 token、續約計數歸零、`ContextTimer`；`nextToken`、`lastAcquireStart` |
| `pottery/redlock.py` | 325-348 | 同步 quorum 即返回、`validity > 0`；`applyAcquire` 的 `ok` |
| `pottery/redlock.py` | 350-353 | acquire 失敗補償；`applyAcquire` 的失敗分支 |
| `pottery/redlock.py` | 503-553 | `extend()`：quorum 即成功、無完成檢查、無補償；`applyExtend false` |
| `pottery/redlock.py` | 555-599 | `release()`：token 比對 `DEL`、quorum 才成功；`applyRelease` |
| `pottery/redlock.py` | 113-120 | acquired Lua（`GET` 比對 + `PTTL`）；`holds` |
| `pottery/redlock.py` | 128-134 | extend Lua（`GET` 比對 + `PEXPIRE`）；`renewHolders` |
| `pottery/redlock.py` | 142-148 | release Lua（`GET` 比對 + `DEL`）；`releaseToken` |
| `pottery/timer.py` | 106, 123-127 | 單調時鐘與毫秒 `elapsed`；`now` |
| `pottery/executor.py` | 53-58 | `BailOutExecutor` 不等待 in-flight；`StepAsIs` 允許 quorum 即返回 |
| `pottery/base.py` | 320-331 | `raise_on_redis_errors`；本模型將錯誤抽象為命令未生效（A-4） |
| `pottery/aioredlock.py` | 249-270, 456-477, 496-516 | 非同步對照；本模型以同步語意為契約（A-5） |
| `README.md` | 327, 331-335, 369-375 | 租期範例、5 masters、臨界區責任；固定實例與 ENV-8 |

## Rule coverage — headline theorems

每個 headline theorem 的 statement snapshot 如下；proofs 階段不得弱化或改寫，否則回到 G3。

| Rule | Headline theorem | Statement snapshot（phase 2，未變更） | Model definition | Source file:line | 為什麼覆蓋規則 |
|---|---|---|---|---|---|
| R1 / INV-1 | `Redlock.at_most_one_valid_holder` | `theorem at_most_one_valid_holder (s : State) (h : ReachableAsIs s) : AtMostOneValidHolder s` | `validHolderCount`、`AtMostOneValidHolder`、`ReachableAsIs` | `pottery/redlock.py:343-348`、`pottery/redlock.py:315-316` | 對所有 as-is 可達狀態，`now < beliefEnd` 的客戶端數 ≤ 1 |
| R2 / INV-6 第一句（as-is 反例） | `Redlock.as_is_late_extend_reports_success` | `theorem as_is_late_extend_reports_success : ReachableAsIs w1s13 ∧ w1s13.now = 1338 ∧ ((w1s13.clients 1).lastExtendOk = true) ∧ ((w1s13.clients 1).lastExtendStart = 1133) ∧ ((w1s13.clients 1).lastExtendEnd = 1338) ∧ ((w1s13.clients 1).lastExtendRenewals = 3) ∧ ((w1s13.clients 1).lastExtendEnd ≥ (w1s13.clients 1).lastExtendStart + ValidityWindow)` | `applyExtend false`、`w1s13` | `pottery/redlock.py:526-546` | 晚完成（1338 ≥ 1133+196）仍回報成功，且 3 個 PEXPIRE 成功 |
| R3 / INV-6 補償句（as-is 反例） | `Redlock.as_is_late_extend_no_compensation` | `theorem as_is_late_extend_no_compensation : ReachableAsIs w2s4 ∧ w2s4.now = 465 ∧ ((w2s4.clients 0).lastExtendOk = true) ∧ ((w2s4.clients 0).lastExtendStart = 267) ∧ ((w2s4.clients 0).lastExtendEnd = 465) ∧ ((holders w2s4 0).length = 3) ∧ ((w2s4.clients 0).lastExtendEnd ≥ (w2s4.clients 0).lastExtendStart + ValidityWindow)` | `applyExtend false`、`w2s4`、`holders` | `pottery/redlock.py:526-553` | 晚完成（465 ≥ 267+196）仍回報成功，且 3 個 key 仍持有 token（沒有補償） |
| R2 / INV-6 第一句（契約） | `Redlock.contract_extend_success_implies_validity` | `theorem contract_extend_success_implies_validity (s : State) (c : ClientId) (delay : Nat) (hdelay : delay ≤ MaxOpDelay) (hext : (s.clients c).extensions < NumExtensions) : (((applyExtend true s c delay).clients c).lastExtendOk = true) → (((applyExtend true s c delay).clients c).lastExtendEnd < ((applyExtend true s c delay).clients c).lastExtendStart + ValidityWindow)` | `applyExtend true` | `specs/quint/GRILL-ANSWERS.md:26-30` | 契約 extend 成功必然在 A3 窗口內完成 |
| R3 / INV-6 補償句（契約） | `Redlock.contract_late_extend_compensates` | `theorem contract_late_extend_compensates (s : State) (c : ClientId) (delay : Nat) (hdelay : delay ≤ MaxOpDelay) (hext : (s.clients c).extensions < NumExtensions) (hlate : ¬ (s.now + delay < s.now + ValidityWindow)) : ((holders (applyExtend true s c delay) c).length = 0)` | `applyExtend true`、`releaseToken` | `specs/quint/GRILL-ANSWERS.md:26-30` | 契約晚完成會補償所有仍持有 token 的節點，留下 0 個 live holder |

Helper lemmas（不是 headline theorem）：`Specs/Witnesses.lean` 的 `reachable_w1s13`、`reachable_w2s3`、`reachable_w2s4` 與 17 個 `step_w*`；它們只是非空洞 witness 的可達性證明，不是對程式的 claim。

### 證明結構（proofs 階段新增）

- `Specs/Invariants.lean`：`Inv` 歸納不變量，包含五個支撐性質：
  `quorum`（有效持有者至少有 3 個 live token key）、`expiry`（有效期間內 key 的 expiry
  晚於 `beliefEnd`）、`clientsBelow`／`ownersBelow`（token 新鮮度）、`injective`
  （不同 client 的 token 不同）、`beliefLe`（`beliefEnd ≤ now + 196`）。
- `inv_init`、`inv_step_acquire`、`inv_step_extend`、`inv_step_release`、
  `inv_step_advance`、`inv_step`、`inv_reachable`：以 `ReachableAsIs` 歸納證明 `Inv`。
- `atMostOne_of_inv`：由「兩個有效持有者各需 3 個 live key、token 不同 ⇒ holder 集合
  不相交 ⇒ 3+3 > 5」導出 `AtMostOneValidHolder`。計數以
  `countP_add_countP_le_of_disjoint` 完成，沒有使用 Mathlib。
- `contract_extend_success_implies_validity`、`contract_late_extend_compensates`：
  直接對 `applyExtend true` 的 `ok = quorumOk && valid` 與 `releaseToken` 補償語意展開。

### 關鍵模型定義（摘要）

```lean
def validHolderCount (s : State) : Nat :=
  ((List.finRange NumClients).filter
    (fun c => decide (s.now < (s.clients c).beliefEnd))).length

def AtMostOneValidHolder (s : State) : Prop :=
  validHolderCount s ≤ 1
```

```lean
inductive ReachableAsIs : State → Prop where
  | init : ReachableAsIs initState
  | step {s s'} : ReachableAsIs s → StepAsIs s s' → ReachableAsIs s'
```

`StepAsIs` 的轉移：acquire（`chosen` 為 free masters 的 nodup 子集，quorum + `finish < start+196` 才成功）、extend（`applyExtend false`，quorum 即成功、不補償）、release（token 比對 DEL、quorum 才成功）、advance（環境推進時鐘）。`StepContract` 只把 extend 換成 `applyExtend true`。

## Non-vacuity witnesses

| Theorem | Witness | 具體值 | 佐證 |
|---|---|---|---|
| `at_most_one_valid_holder` | `w2s3`（成功 acquire 後） | `validHolderCount w2s3 = 1`；`reachable_w2s3` 已證 | `Specs/Examples.lean` 的 `example`；`Specs/Witnesses.lean` |
| `as_is_late_extend_reports_success` | `w1s13` | `now=1338`、`start=1133`、`end=1338`、`renewals=3`、`beliefEnd=1329` | `reachable_w1s13` 已證；trace 1 |
| `as_is_late_extend_no_compensation` | `w2s4` | `now=465`、`start=267`、`end=465`、`holders=3`、`beliefEnd=463` | `reachable_w2s4` 已證；trace 2 |
| `contract_extend_success_implies_validity` | `applyExtend true w2s3 0 0` | `lastExtendOk=true`；`267 < 267+196` | `Specs/Examples.lean` 的 `example` |
| `contract_late_extend_compensates` | `applyExtend true w2s3 0 198` | `finish=465 ≥ 463`；`holders=0` | `Specs/Examples.lean` 的 `example` |

**Witness 的每個 conjunct 都對應真實程式欄位：** 時間（monotonic ms）、`lastExtendOk`、`lastExtendStart/End`、`lastExtendRenewals`（PEXPIRE 成功數）、`holders`（master 的 token 是否等於該客戶端 token 且 key 仍 live）。witness 定理**沒有**提及 `nextToken`、token 數值或其他模型自加計數器。

## Abstraction ledger

| 被丟棄的細節 | 出處 | 為什麼不影響已證性質 |
|---|---|---|
| 重試、backoff、timeout、`blocking` | `pottery/redlock.py:414-432` | 屬 liveness／等待時間（OUT-6）；不改變單次 acquire 的 quorum 與有效期判定 |
| `RedisError`、`QuorumIsImpossible`、`redis_errors` 內容 | `pottery/base.py:320-331`、`pottery/redlock.py:332-341` | 模型把失敗視為命令未生效（A-4）；這是對互斥安全最保守的解讀 |
| `locked()` 與 min/median TTL 差異 | `pottery/redlock.py:447-501`、`pottery/aioredlock.py:386-430` | G2 未把 INV-9 送 Lean；不影響 INV-1／INV-6 |
| context manager、`__exit__`／`__aexit__` 例外優先序 | `pottery/redlock.py:648-674`、`pottery/aioredlock.py:542-560` | INV-10 是控制流，不是鎖狀態；G2 未送 Lean |
| per-master 完成時間差、同步／非同步等待差異 | `pottery/redlock.py:325-348`、`pottery/aioredlock.py:249-270` | 以單一 `delay` 抽象（A-1）；同步語意為契約（A-5）。witness 的程式可達性未由 Lean 證明 |
| UUID token | `pottery/redlock.py:322` | 只保留「相同／不同」與新鮮配發；witness 不引用 token 數值（A-3） |
| extension limit 的 `TooManyExtensions` guard | `pottery/redlock.py:523-524` | `StepAsIs` 要求 `extensions < NumExtensions`；契約定理以 `hext` hypothesis 表示 |
| 節點重啟／資料遺失／fencing | `pottery/redlock.py:128-148` | ENV-7／OUT-1：不在承諾內；模型不加入 `MasterRestart` |
| 同步 quorum 提早返回後仍在背景執行的 SET／PEXPIRE | `pottery/executor.py:53-58`、`pottery/redlock.py:325-348` | ENV-11／A-7：只可能留下本 token 的 stale key，不會產生第二個 token；屬 liveness |
| 固定 `n=5`、`ART=200 ms`、`NUM_CLIENTS=2` | `README.md:327,331-335`、`specs/quint/instances.qnt` | A-2：具體 witness 的實例；不是通用證明 |

## Explicitly not covered

- 真實 Python 執行緒／網路排程能否產生 A-1 的「命令早執行、回應晚到」交錯；Lean 只證明模型。
- 任意 `n`、任意 `auto_release_time`、任意 `num_extensions` 的通用定理（本階段固定實例）。
- INV-9 `locked()` 的安全上界、INV-10 例外優先序、INV-3 token freshness 的獨立 theorem。
- 非同步 `AIORedlock` 的行為（以同步語意為契約，A-5）。
- liveness、公平性、等待時間上界、5 masters 容錯 2 個的可用性。
- 節點崩潰／重啟遺失 key、Byzantine master、replication/failover、伺服器時鐘跳躍。
- `RedisError` 的「命令已生效但回應逾時」情境。
- 例外訊息文字、欄位順序、`redis_errors` 內容。

## Verification gate checklist

- [x] `RULES.md` 有 confirmed-by、日期、出處與 acceptance
- [x] 每個 headline theorem 有 rule ID、精確 statement snapshot、`file:line`、非空洞 witness
- [x] 模型轉錄核心決策與狀態轉移，沒有逐行搬實作
- [x] Witness 可達性在 Lean 內已證（`reachable_w1s13`、`reachable_w2s3`、`reachable_w2s4`）
- [x] `lake build` 通過（clean build 8 jobs，2026-11-03）
- [x] 零 `sorry`（proofs 階段；guardrail 掃描 0 hits）
- [x] `verify-lean.sh` 全綠（build、direct compile、coverage、guardrail、axiom audit、audit completeness）
- [x] dashboard baseline + current（`metrics-baseline.txt`；逐項 delta 0）
- [x] G3 簽核（`specs/lean/G3-SIGNOFF.md`：`philipz`，`2026-11-03T02:22:53.189Z`，`approved`）
- [x] Owner 讀過 top-level statements 並接受（G3，同上）
- [ ] 獨立對抗式審查：由機制端獨立審查（見 `specs/lean/REVIEW.md`）；**尚未完成，不標成已完成**

## Review log

| 日期 | 審查者 | 種類 | 發現 | 處置 |
|---|---|---|---|---|
| 2026-11-03 | 機制端（待執行） | adversarial AI | 由機制端獨立審查（見 `specs/lean/REVIEW.md`） | 尚未完成；不標成已完成 |
| 2026-11-03T02:22:53.189Z | `philipz` | human（G3） | 定理敘述已讀並簽核 | `approved`；證據 `specs/lean/G3-SIGNOFF.md` |

## Re-sync log

| 日期 | Commit | 來源變更 | 受影響規則 | 受影響定理 | 備註 |
|---|---|---|---|---|---|
| — | — | 尚無 | — | — | 本階段首次建立 |
