# pottery Redlock — Lean 驗證報告（階段③ `proofs`）

> 工作項：GitHub Issue #47（`agent-playground/pottery`），任務類型 `agent-verify-lean`。
> 基準分支：`master`；base commit `2d7c70a`（`2d7c70abdc000e337dfd9e26b0af2a151cdac07d`，2026-10-28）。
> 本輪只做 `proofs` 階段（`.factory/run/verify-phase` = `proofs`）；G3 簽核證據為
> `specs/lean/G3-SIGNOFF.md`（`philipz`，`2026-11-03T02:22:53.189Z`，`approved`）。
> 輸出語言：繁體中文（zh-Hant）。規則輸入：`specs/quint/RULES.md`、`specs/quint/TRIAGE.md`、
> `specs/quint/GRILL-ANSWERS.md`（唯讀）。

## 1. 摘要

- **5 條 headline theorem 全部完成證明，專案零 `sorry`。** 沒有新增 axiom、bodyless
  `opaque`、`native_decide`、`unsafe`、`extern`、`@[implemented_by]`。
- 新增 `Specs/Invariants.lean`：以 `ReachableAsIs` 的歸納不變量 `Inv` 證明 INV-1；另外
  直接展開 `applyExtend true` 的 `ok = quorumOk && valid` 與 `releaseToken` 補償語意，
  證明兩條 INV-6 契約定理。
- 兩條 G2 反例（CF-1／CF-2）的 witness 可達性已在 Lean 內證明；它們是 **模型層級** 的
  反例。**「真實 Python 執行緒／網路排程會走到該交錯」沒有被 Lean 證明**，依賴 A-1
  時序抽象；本報告不會把它寫成程式層級結論。
- 閘門全綠：`lake build`、direct compile、compile coverage、guardrail（0 hits）、
  axiom audit（5/5，僅 `propext`／`Classical.choice`／`Quot.sound`）、dashboard
  baseline/current（delta 0）。
- **不是「Redlock 已驗證」：** Lean 證明的是 `Specs/Model.lean` 的模型；模型與 Python
  的一致性、CF-1／CF-2 的程式可達性、任意 `n`／`ART` 的推廣都仍在覆蓋範圍外（§9）。

## 2. 輸入與轉錄

| 輸入 | 用途 |
|---|---|
| `specs/quint/RULES.md` | G1 確認的 ENV／INV／ACT／OUT；`specs/lean/RULES.md` 逐條轉錄與 Lean 相關者 |
| `specs/quint/GRILL-ANSWERS.md:6-54` | A1（有效持有語意）、A3（extend 完成檢查與補償）、A4、A5、A6 |
| `specs/quint/TRIAGE.md` | G2 判定：`as_is_extend_success_without_validity`、`as_is_late_extend_no_compensation` 兩條 `toLean = yes`，皆 `real`、`security = no` |
| `specs/quint/traces/as_is_extend_success_without_validity.itf.json` | CF-1 的 ITF 來源 |
| `specs/quint/traces/as_is_late_extend_no_compensation.itf.json` | CF-2 的 ITF 來源 |
| `pottery/*.py`、`README.md` | `file:line` 證據；base commit `2d7c70a` |

沒有重新訪談、沒有修改 G1 規則、沒有把 G2 判為 `toLean = no` 的反例另立 headline
theorem。`specs/lean/RULES.md` 與 `specs/lean/G3-SIGNOFF.md` 在 proofs 階段是唯讀輸入，
本輪未修改。

## 3. 模型設計

檔案：`Specs/Model.lean`（statements 階段建立，本輪未改）。

- **固定實例（A-2）：** `NumMasters = 5`、`AutoReleaseTime = 200 ms`、`Drift = 4 ms`、
  `ValidityWindow = 196 ms`、`NumClients = 2`、`MaxOpDelay = 205 ms`、`Quorum = 3`、
  `NumExtensions = 3`。與 Quint 的 `as_is` 實例一致。
- **狀態：** `now`（單調毫秒）、`masters : Fin 5 → { owner : Option Nat, expiry : Nat }`、
  `clients : Fin 2 → ClientState`、`nextToken`（模型自加的配發計數器，witness 定理不引用）。
- **token：** `Option Nat` 抽象（A-3）；只保留「相同／不同」與「新鮮配發」。
- **`holds`／`holders`：** master 的 `owner` 等於該 client 的 token，且 `now < expiry`
  （Lua 的 `GET == ARGV[1]` 加 `PTTL > 0`）。
- **`applyAcquire`：** `chosen` 是 free masters 的 nodup 清單；`ok = (chosen.length ≥ 3) ∧
  (finish < start + 196)`；成功寫入 `expiry = start + 200` 與 `beliefEnd = start + 196`；
  失敗以本次新 token 補償 release。
- **`applyExtend false`（as-is）：** `ok = renewals ≥ 3`；沒有完成檢查、沒有補償；成功時
  `expiry = start + 200`、`beliefEnd = start + 196`、`extensions + 1`
  （`pottery/redlock.py:526-546`）。
- **`applyExtend true`（INV-6 契約）：** `ok = renewals ≥ 3 ∧ finish < start + 196`；
  失敗或晚完成時 `releaseToken` 刪除所有仍持有本 token 的 key，`beliefEnd = 0`（G1 A3）。
- **`applyRelease`：** 對所有 token 相符的 key 執行 `DEL`；`ok = live holders ≥ 3`；
  成功時 `beliefEnd = 0`（`pottery/redlock.py:573-599`）。
- **`applyAdvance`：** 只推進 `now`；key 是否 live 由絕對 `expiry` 判斷（ACT-13／ENV-5）。
- **`StepAsIs`／`ReachableAsIs`：** 四種轉移（acquire、extend、release、advance）；
  `StepContract` 只把 extend 換成契約版。

模型刻意不逐行搬 Python：不含 logging、retry/backoff、例外訊息、`locked()`、context
manager；只保留會改變 INV-1／INV-6 的決策。

## 4. 模型忠實度與假設

### 4.1 已對齊程式的決策

- quorum 是嚴格多數 3/5（`pottery/redlock.py:343,544,591`）。
- acquire 成功需 quorum **且** `finish < start + ART − drift`（`pottery/redlock.py:343-348`）。
- extend 只對仍持有本 token 的 master `PEXPIRE`，不對遺失 key 的少數節點重 `SET`
  （A4／OUT-3，`pottery/redlock.py:128-134`）。
- as-is extend 只檢查 quorum，沒有計時、沒有完成檢查、失敗不補償
  （`pottery/redlock.py:526-553`）。
- release 只刪 token 相符的 key，嚴格多數才回報成功（`pottery/redlock.py:573-599`）。
- 租期以絕對時間到期；客戶端有效期截止是 `操作開始 + 196 ms`（A1(b)、A3）。

### 4.2 時序抽象 A-1（**assumption**）

每個操作有 `delay`；master 端效果放在操作開始，完成時間是 `start + delay`。這代表
「命令已在開始時執行、回應在完成時才被讀到」的一種可達交錯。程式對 `extend()` 沒有
`ContextTimer`，也沒有任何 `deadline − now` 的明確 timer 可以約束轉移，所以模型沒有
可寫成這類上界的欄位；A-1 是本模型選擇的時序抽象，不是從程式推導出的 constraint。

**CF-1／CF-2 依賴 A-1，Lean 沒有證明程式能走到它。** 具體地說：

- CF-1：模型讓 `start=1133`、`finish=1338`，3 個 `PEXPIRE` 在開始時成功、回應在完成時
  才被讀到；真實 Python 執行緒排程是否會讓 `extend()` 等到 1338 ms 才看到第 3 個成功，
  Lean 沒有證明。
- CF-2：模型讓 `start=267`、`finish=465`，3 個 key 在 `expiry=467` 仍 live；真實網路
  是否會把回應延遲到 465 ms，Lean 沒有證明。

A-1 沒有引入「模型比程式寬，所以反例一定發生」的推論；它只是把 witness 固定在一個
模型允許的交錯。**模型層級的 Lean 證明不能單獨推出程式層級的可達性。**

### 4.3 其他 assumption

- **A-2 固定實例：** `n=5`、`ART=200 ms`、`NUM_CLIENTS=2`；不是對任意 `n`／`ART` 的
  通用證明。
- **A-3 token 抽象：** `Option Nat`；witness 不引用 token 數值。
- **A-4 Redis 錯誤：** 命令失敗視為未生效；不建模「已生效但回應逾時」。
- **A-5 同步語意為契約：** 以同步 `BailOutExecutor` 的 quorum 即返回為準（G1 A6①）；
  非同步等待全部 master、`locked()` min/median 差異不建模。
- **A-6 `locked()` 省略：** G2 沒有把 INV-9 送 Lean。
- **A-7 提早返回後的 in-flight 操作：** 同步 quorum 即返回後，背景 SET／PEXPIRE 可能
  尚未完成（ENV-11）；模型不建模，只可能留下本 token 的 stale key，不產生第二個 token。

## 5. RULES → headline theorem 對照（proofs 結果）

| Rule | Theorem | 類型 | 證明狀態 | 來源 |
|---|---|---|---|---|
| INV-1 | `Redlock.at_most_one_valid_holder` | 安全不變量（模型層級） | **已證**（`inv_reachable` + `atMostOne_of_inv`） | `specs/quint/RULES.md` INV-1；`pottery/redlock.py:343-348` |
| INV-6 第一句 | `Redlock.as_is_late_extend_reports_success` | as-is 反例（CF-1） | **已證**（witness 可達 + `decide`） | G2 `toLean = yes`；`pottery/redlock.py:526-546`；trace 1 |
| INV-6 補償句 | `Redlock.as_is_late_extend_no_compensation` | as-is 反例（CF-2） | **已證**（witness 可達 + `decide`） | G2 `toLean = yes`；`pottery/redlock.py:526-553`；trace 2 |
| INV-6 第一句（契約） | `Redlock.contract_extend_success_implies_validity` | 修正版契約 | **已證**（`applyExtend true` 的 `ok` 展開） | G1 A3；`specs/quint/GRILL-ANSWERS.md:26-30` |
| INV-6 補償句（契約） | `Redlock.contract_late_extend_compensates` | 修正版契約 | **已證**（`releaseToken` 補償語意） | G1 A3；`specs/quint/GRILL-ANSWERS.md:26-30` |

完整 statement snapshot 見 `MODEL-MAP.md` 的「Rule coverage」表；本輪沒有弱化或改寫任何
headline statement。

### 5.1 證明結構

- `Specs/Invariants.lean` 定義 `Inv`：
  - `quorum`：`Valid s c → Quorum ≤ (holders s c).length`；
  - `expiry`：`Valid s c → holds s c m → beliefEnd c < expiry m`；
  - `clientsBelow`／`ownersBelow`：client token 與 master owner 都 `< nextToken`；
  - `injective`：不同 client 不會持有相同 token；
  - `beliefLe`：`beliefEnd ≤ now + ValidityWindow`。
- `inv_init`、`inv_step_acquire`、`inv_step_extend`、`inv_step_release`、`inv_step_advance`
  逐條檢查四種轉移；`inv_step` 分派 `StepAsIs`，`inv_reachable` 對 `ReachableAsIs` 歸納。
- `atMostOne_of_inv`：兩個有效持有者各需 ≥3 個 live key；token 不同 ⇒ holder 集合不相交
  ⇒ `3 + 3 ≤ 5` 矛盾。計數用 `List.countP` 與自證的
  `countP_add_countP_le_of_disjoint`，沒有使用 Mathlib。
- 兩條契約定理直接對 `applyExtend true` 的 Bool 條件與 `releaseToken` 展開；補償定理用
  `releaseToken_owner_ne_self` 證明補償後沒有任何 master 仍持有本 client 的 token。

## 6. 反例 witness

### 6.1 CF-1：as-is extend 晚完成仍回報成功

- ITF：`specs/quint/traces/as_is_extend_success_without_validity.itf.json`（14 states，
  最後 index 13）。
- Lean witness：`Specs/Witnesses.lean` 的 `w1s13`；`reachable_w1s13` 已由 Lean 證明
  （17 個具體 `StepAsIs` 中的 13 個）。
- 最終值：`now = 1338`、`lastExtendStart = 1133`、`lastExtendEnd = 1338`、
  `lastExtendOk = true`、`lastExtendRenewals = 3`、`beliefEnd = 1329`；A3 截止 =
  `1133 + 196 = 1329`，完成時間 1338 已超出。
- 對應程式：`extend()` 在 quorum 時 `self._extension_num += 1; return`，沒有完成檢查
  （`pottery/redlock.py:526-546`）。
- 模型層級：Lean 已機器證明此狀態在 `ReachableAsIs` 下可達；**程式層級：依賴 A-1，
  Lean 沒有證明真實排程能走到它。**

### 6.2 CF-2：晚完成且沒有補償

- ITF：`specs/quint/traces/as_is_late_extend_no_compensation.itf.json`（5 states，最後
  index 4）。
- Lean witness：`w2s4`；`reachable_w2s4` 已證明。
- 最終值：`now = 465`、`lastExtendStart = 267`、`lastExtendEnd = 465`、
  `lastExtendOk = true`、`holders = 3`、`beliefEnd = 463`；A3 截止 =
  `267 + 196 = 463`，完成時間 465 已超出，但 3 個 master 的 key（`expiry = 467`）仍持有
  token。
- 對應程式：as-is `extend()` 失敗或晚完成時沒有補償 release
  （`pottery/redlock.py:548-553`）。
- 模型層級：Lean 已機器證明此狀態可達；**程式層級：依賴 A-1，Lean 沒有證明真實排程
  能走到它。**

### 6.3 Witness 欄位與真實程式的對應

| 模型欄位 | 真實程式對應 |
|---|---|
| `now`、`lastExtendStart/End` | `ContextTimer` 的毫秒時間；`extend()` 的開始與返回時刻 |
| `lastExtendOk` | `extend()` 是否正常返回（相對於拋 `ExtendUnlockedLock`／`TooManyExtensions`） |
| `lastExtendRenewals` | `num_masters_extended`，即 `PEXPIRE` 回報成功的 master 數（`pottery/redlock.py:532-545`） |
| `holders` | master 的 key 是否仍存有本 client 的 token 且 PTTL > 0 |
| `beliefEnd` | A1(b) 的本地有效期截止，不是程式欄位，但由 `start + ART − drift` 決定 |

witness 定理沒有提及 `nextToken`、token 數值或任何只為模型方便而加的計數器。

## 7. 契約定理（修正版 INV-6）

- `contract_extend_success_implies_validity`：契約 extend 成功必然
  `lastExtendEnd < lastExtendStart + 196`。
- `contract_late_extend_compensates`：契約 extend 在 `finish ≥ start + 196` 時，對所有
  仍持有 token 的 master 補償後，`holders` 為 0。

這些是**模型層級**的契約性質；它們不主張 Python 程式已修好，也不主張 as-is 程式會自動
滿足契約。若要落到程式，仍需另行實作修復並重新驗證（見 §10）。

## 8. 閘門結果（proofs 階段）

| 檢查 | 結果 | 證據 |
|---|---|---|
| `lake build`（clean） | **PASS** | `Build completed successfully (8 jobs)`；clean build 牆鐘 **2.55 s** |
| `Specs/Proofs.lean` 直接編譯 | **PASS** | `lake env lean Specs/Proofs.lean`，exit 0 |
| compile coverage | **PASS** | 5 個其他 `.lean` 檔直接編譯通過 |
| guardrail 掃描 | **PASS** | 7 個 `.lean` 檔、**0 hits**（無 `sorry`／axiom／`native_decide`／`unsafe`／`extern`／`implemented_by`） |
| axiom audit | **PASS** | 5/5 headline theorem 有 `#print axioms`；僅 `propext`、`Classical.choice`、`Quot.sound` |
| dashboard baseline + current | **PASS** | `metrics-baseline.txt` 與 current 逐項 **delta 0** |
| headline `sorry` | **0** | proofs 階段要求；已達成 |
| Mathlib | **未安裝** | 只用 Lean core |

閘門命令（在 `specs/lean` 執行；與 task template 的 `--dir specs/lean` 等價）：

```bash
bash <lean-formal-verification>/scripts/verify-lean.sh \
  --dir . --main Specs/Proofs.lean --audit Audit.lean \
  --theorems headline-theorems.txt --baseline metrics-baseline.txt
```

最終輸出：`RESULT : PASS`，`duration : 4s`。完整逐項數字見 `metrics-baseline.txt` 與
`MODEL-MAP.md` 的 checklist。

## 9. 模型層級 vs 程式層級（結論邊界）

- **Lean 已經機器檢查的：** 5 條 headline theorem、`ReachableAsIs` 的歸納不變量 `Inv`、
  兩個 ITF witness 狀態的可達性、`Specs/Examples.lean` 的非空洞具體值。
- **Lean 沒有證明的：** 真實 Python 執行緒／網路排程能否產生 A-1 的「命令早執行、回應
  晚到」交錯；任意 `n`／`ART`／`num_extensions` 的通用定理；Python 程式已實作 INV-6
  契約；INV-9 `locked()` 與 INV-10 例外優先序。
- **不能從本輪推出的：** 「Redlock 已驗證」、「CF-1／CF-2 在真實程式一定可重現」、
  「修正版程式已正確實作」。`at_most_one_valid_holder` 是**模型層級**的安全定理；
  CF-1／CF-2 是**模型層級**的反例，其程式可達性依賴 A-1。
- **G2 的分類不是 Lean 重新判定的：** `real`／`security = no` 來自
  `specs/quint/TRIAGE.md`；本輪只轉錄與證明，沒有改寫。

## 10. 未決事項（open questions）

1. **程式可達性：** CF-1／CF-2 依賴 A-1（命令早執行、回應晚到）。Lean 沒有證明真實
   Python 執行緒／網路排程會走到這個交錯；是否需要在後續工作項補一個明確的排程假設或
   環境模型？
2. **通用性：** 本階段固定 `n=5`、`ART=200 ms`。是否需要在後續工作項推廣到任意 `n` 與
   任意合法 `ART`，或維持 G2 trace 的具體實例即可？
3. **程式修復：** 本輪只證明模型層級的契約（`applyExtend true`）；Python 的 as-is
   `extend()` 尚未修改。是否另開 `agent-fix-bug` 工作項實作完成檢查與補償，再用同一組
   定理重新驗證？
4. **範圍切分：** G2 未把 INV-9（`locked()`）與 INV-10（例外優先序）送 Lean；是否要在
   後續工作項另立 Lean 階段？

## 11. 變更清單

本輪只新增／修改 `specs/lean/**` 與 CI 管的 `.factory/run/report.json`；未修改
`src/**`、`.github/**`、`specs/quint/**`、`docs/**` 或依賴。`specs/lean/G3-SIGNOFF.md`
與 `specs/lean/RULES.md` 是唯讀還原輸入，未修改。完整清單見 `.factory/run/report.json`
的 `changedPaths`。

## 12. 結論

`proofs` 階段的產出已齊備：5 條 headline theorem 全部有零 `sorry` 的 Lean 證明，
`verify-lean.sh` 全綠，axiom audit 只含 allowlist 的三個標準公理，dashboard
baseline/current delta 0。G3 簽核已由服務端寫入 `G3-SIGNOFF.md`。本輪**不**宣稱
Redlock 已驗證：所有結論都是模型層級，CF-1／CF-2 的程式可達性仍依賴 A-1，且未證明。
