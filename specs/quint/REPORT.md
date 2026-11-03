# pottery Redlock — Quint 模型驗證報告（階段②）

> 工作項：GitHub Issue #42（`agent-playground/pottery`），任務類型 `agent-verify-quint`。
> 基準分支：`master`；base commit `2d7c70a`。
> 規則輸入：`specs/quint/RULES.md`（G1 已確認，**唯讀**，本輪未修改）。語言：繁體中文（zh-Hant）。
> 本輪只執行 `quint typecheck`、`quint test`、`quint run`；**未執行 `quint verify`**（Apalache／Java 不在本階段工具鏈，ADR-029 §7）。

## 1. 摘要

- 依 `RULES.md` 建立同步 Redlock 的狀態機模型：`n` 個 master、`m` 個客戶端、單調毫秒時鐘、token 比對、quorum、租期到期、`locked()` 回報，以及 as-is 與 RX 兩種 `extend`。
- `model.qnt` 以 `STRICT_EXTEND=false` 保留 as-is 行為（ACT-9/ACT-10），以 `STRICT_EXTEND=true` 檢查已確認的 INV-6 修正版；`instances.qnt` 提供 5 個具體實例。
- `test.qnt` 為 INV-1～INV-10 各寫了正向情境 witness；`quint test` 全數通過。
- **候選發現 CF-1**：as-is 的 `extend` 在完成時已超出租期（`finish >= start + ART - DRIFT`）仍回報成功（違反 INV-6 第一句）。`as_is`、`as_is_even`、`as_is_slow` 三個實例都出現反例。
- **候選發現 CF-2**：as-is 的 `extend` 在上述晚完成情境沒有補償釋放，續約後的 key 仍留在多數節點（違反 INV-6 補償句）。
- `fixed` 實例在 5000 個抽樣 trace、`--max-steps 40` 下，INV-1～INV-9 全部沒有反例；as-is 在相同抽樣下也只有 INV-6 系列出現反例。
- 抽樣結果**不是證明**；「沒有反例」只表示在本次 `--max-samples`／`--max-steps`／seed 下未觀察到。

## 2. 模型設計與時間語意

- 狀態：`now`（單調毫秒）、`masters: MasterId -> {owner, expiry}`、`clients: ClientId -> ClientState`、`nextToken`、`issuedTokens`。
- `owner = 0` 表示沒有 key；`expiry <= now` 表示 key 已到期（對應 ACT-13／ENV-5）。
- 每個操作都有一個 `delay`（毫秒），`finish = now + delay`。master 端效果放在**操作開始**、完成時間放在 `finish`；這是對互斥安全最保守的抽象（key 相對完成時間最早過期），不是對真實系統的額外假設。
- `acquireWith`：`chosen` 是 SET NX 成功的 master 子集（可為任何 free 子集，對應同步 quorum 提早返回）；成功需 `|chosen| > n/2` 且 `finish < start + ART - DRIFT`。失敗時對 `chosen` 做 token 比對的補償 release（ACT-4）。
- `extendWith`：只有仍持有本 token 的 master 會被 PEXPIRE；`STRICT_EXTEND=false` 時 quorum 即成功（ACT-9），`true` 時還要求完成時仍在有效期內，否則補償 release 全部仍持有 token 的節點並回報失敗（INV-6）。
- `releaseWith`：刪除所有 token 相符的 key；嚴格多數成功才回報成功（ACT-11／INV-8）。
- `lockedWith`：以所有仍持有 token 的 master 的最小 TTL 計算 `max(minTTL - DRIFT - delay, 0)`；同步程式只取第一個 quorum 的最小值，因此模型回報值不會大於程式（保守）。
- `advanceTimeBy`：環境推進單調時鐘；`step` 另含不指定客戶端的 `advanceTime`。
- token 由 `nextToken` 單調配發，`issuedTokens` 記錄已配發集合；token `0` 保留給「未持有」。

## 3. RULES → 不變量對照

| 規則 | 模型／檢查 | 本輪結果 |
|---|---|---|
| INV-1 同一時間最多一個有效持有者 | `atMostOneValidHolder`；`inv1SingleValidHolderTest`、`act13ExpiryFreesLockTest` | as-is／fixed 抽樣均無反例 |
| INV-2 acquire 成功需 quorum 且完成時有效 | `acquireSuccessNeedsQuorumAndValidity`；`inv2AcquireValidityTest` | 無反例（成功與失敗分支都有 witness） |
| INV-3 每次嘗試使用全新 token | `tokensAreFresh`；`inv3FreshTokenTest` | 無反例 |
| INV-4 兩個不同 token 不可能同時各自擁有多數 | `noTwoTokenMajorities`；`inv4QuorumIntersectionTest` | 無反例 |
| INV-5 只有 token 持有者可 extend/release | `releaseToken`／`renewHolders` 的 `owner == token` 條件；`inv5TokenMatchTest` | 無反例（token 不符時 key 不變） |
| INV-6 extend 成功需 quorum 且完成時仍在有效期內；否則補償 | `extendSuccessNeedsQuorumAndValidity`、`failedExtendCompensated`、`lateExtendCompensated`；`asIsLateExtendWitnessTest`、`inv6FixedLateExtendTest`、`inv6FixedFastExtendTest` | **as-is 反例（CF-1、CF-2）**；fixed 無反例 |
| INV-7 續約次數上限 | `extensionLimit`；`inv7ExtensionLimitTest` | 無反例；第 4 次 extend 被擋下 |
| INV-8 release 成功需 quorum | `releaseSuccessNeedsQuorum`；`inv8ReleaseQuorumTest` | 無反例 |
| INV-9 `locked()` 不得超過安全上界 | `lockedReportWithinSafeBound`；`inv9LockedReportTest` | 無反例 |
| INV-10 body 例外優先 | `asIsExit`／`contractExit` 純函式；`inv10ExitPriorityTest` | 契約函式符合；as-is 函式在 body 例外＋release 失敗時回傳 `ReleaseException`（規則層觀察，見 §6.3） |

ACT 對照：

- ACT-1/2/3/4：`acquireWith`；ACT-5 的重試／timeout／backoff 屬 liveness（OUT-6），未建模。
- ACT-6：`lockedWith`；ACT-7/8/9/10：`extendWith`；ACT-11：`releaseWith`。
- ACT-12：以 INV-10 的純函式表示 `__exit__`／`__aexit__` 的例外優先序；未建模完整 context manager 狀態。
- ACT-13：`advanceTimeBy` + `act13ExpiryFreesLockTest`；ACT-15：`act15NonReentrantTest`。
- ACT-14：模型採同步語義（A6①）；非同步等待全部 master、`locked()` median、補償參數轉發的差異未建模（見 §8）。

## 4. 實例與常數理由

`RULES.md` 的 ENV-1 建議生產環境 `n=5`；程式對 master 數、客戶端數、租期、續約次數都沒有硬性上限或驗證（詳見 `model.qnt` 每個 `const` 上方的 `domain_justification`）。

| 實例 | `N_MASTERS` | `ART` (ms) | `DRIFT` | `NUM_CLIENTS` | `NUM_EXTENSIONS` | `MAX_OP_DELAY` | `STRICT_EXTEND` | 理由 |
|---|---:|---:|---:|---:|---:|---:|---|---|
| `as_is` | 5 | 200 | 4 | 2 | 3 | 205 | false | 生產建議 n=5；0.2 s 是 README／測試常用租期；205 ms 讓 `ART-DRIFT < delay < ART` 與 `delay >= ART` 都可達；as-is ACT-9 |
| `fixed` | 5 | 200 | 4 | 2 | 3 | 205 | true | 與 `as_is` 同常數，只切換 INV-6 RX |
| `as_is_even` | 4 | 200 | 4 | 2 | 3 | 205 | false | 偶數 master 的嚴格多數邊界（3/4，不是 2/4） |
| `as_is_slow` | 5 | 1000 | 12 | 2 | 3 | 1025 | false | 1 s 租期，檢查結果不依賴 0.2 s 尺度；drift 仍為整數 |
| `boundary_tiny` | 1 | 1 | 3 | 1 | 0 | 5 | true | 單 master 下界、1 ms 租期（drift > ART，acquire 必失敗，對應 tests 的 `.001` 案例）、`num_extensions=0` 下界 |

`DRIFT = ceil(ART/100) + 2`（毫秒）：程式為 `ART*0.01 + .002` 秒（`pottery/redlock.py:315-316`）。對 100 ms 的倍數（200、1000）是精確值；`ART=1 ms` 時為 3 ms（真值 2.01 ms），只會讓有效期更短，保留 `.001 s` 必失敗的行為。

`MAX_OP_DELAY` 是**模擬上界**，不是對程式的假設；程式沒有操作耗時上限（`pottery/timer.py:123-127`）。所有實例都讓 `delay > ART-DRIFT` 可達，否則 INV-6 的完成檢查不可能被觸發。

## 5. 命令與牆鐘秒數

以下均為本 workspace 的實際執行；牆鐘取自 `/usr/bin/time -f 'WALL:%e'`，並以 base commit `2d7c70a` 的程式碼與 `RULES.md` 為輸入。`quint run` 的反例命令刻意回傳非零，這是預期結果。

### 5.1 型別檢查

```bash
npx --no-install quint typecheck specs/quint/model.qnt       # WALL 1.75 s, exit 0
npx --no-install quint typecheck specs/quint/instances.qnt   # WALL 1.73 s, exit 0
npx --no-install quint typecheck specs/quint/test.qnt        # WALL 2.15 s, exit 0
```

### 5.2 情境 witness（`quint test`）

```bash
npx --no-install quint test specs/quint/test.qnt --main asIsTest --match '.*Test' --max-samples 10
# WALL 2.83 s, 12 passing, exit 0

npx --no-install quint test specs/quint/test.qnt --main fixedTest --match '.*Test' --max-samples 10
# WALL 2.24 s, 2 passing, exit 0

npx --no-install quint test specs/quint/test.qnt --main boundaryTest --match '.*Test' --max-samples 10
# WALL 2.25 s, 2 passing, exit 0
```

### 5.3 `quint run`：無反例的確認（抽樣）

```bash
npx --no-install quint run specs/quint/instances.qnt --main as_is \
  --invariants atMostOneValidHolder acquireSuccessNeedsQuorumAndValidity \
  tokensAreFresh noTwoTokenMajorities validHolderHasQuorum extensionLimit \
  releaseSuccessNeedsQuorum lockedReportWithinSafeBound \
  --max-steps 40 --max-samples 5000
# WALL 3.86 s, [ok] No violation found, exit 0

npx --no-install quint run specs/quint/instances.qnt --main fixed \
  --invariants atMostOneValidHolder acquireSuccessNeedsQuorumAndValidity \
  tokensAreFresh noTwoTokenMajorities validHolderHasQuorum \
  extendSuccessNeedsQuorumAndValidity failedExtendCompensated lateExtendCompensated \
  extensionLimit releaseSuccessNeedsQuorum lockedReportWithinSafeBound \
  --max-steps 40 --max-samples 5000
# WALL 4.52 s, [ok] No violation found, exit 0

npx --no-install quint run specs/quint/instances.qnt --main as_is_even \
  --invariants atMostOneValidHolder acquireSuccessNeedsQuorumAndValidity \
  tokensAreFresh noTwoTokenMajorities validHolderHasQuorum extensionLimit \
  releaseSuccessNeedsQuorum lockedReportWithinSafeBound \
  --max-steps 40 --max-samples 2000
# WALL 2.66 s, [ok] No violation found, exit 0

npx --no-install quint run specs/quint/instances.qnt --main as_is_slow \
  --invariants atMostOneValidHolder acquireSuccessNeedsQuorumAndValidity \
  tokensAreFresh noTwoTokenMajorities validHolderHasQuorum extensionLimit \
  releaseSuccessNeedsQuorum lockedReportWithinSafeBound \
  --max-steps 40 --max-samples 2000
# WALL 2.70 s, [ok] No violation found, exit 0

npx --no-install quint run specs/quint/instances.qnt --main boundary_tiny \
  --invariants atMostOneValidHolder acquireSuccessNeedsQuorumAndValidity \
  tokensAreFresh noTwoTokenMajorities validHolderHasQuorum \
  extendSuccessNeedsQuorumAndValidity failedExtendCompensated lateExtendCompensated \
  extensionLimit releaseSuccessNeedsQuorum lockedReportWithinSafeBound \
  --max-steps 20 --max-samples 500
# WALL 1.97 s, [ok] No violation found, exit 0
```

### 5.4 `quint run`：反例（產生 ITF trace）

```bash
npx --no-install quint run specs/quint/instances.qnt --main as_is \
  --invariant extendSuccessNeedsQuorumAndValidity \
  --max-steps 30 --max-samples 200 --seed 0x673a6573714b6fb2 \
  --out-itf specs/quint/traces/as_is_extend_success_without_validity.itf.json
# WALL 1.92 s, [violation], exit 1

npx --no-install quint run specs/quint/instances.qnt --main as_is \
  --invariant lateExtendCompensated \
  --max-steps 30 --max-samples 2000 --seed 0xcd7dd9223e2d6dac \
  --out-itf specs/quint/traces/as_is_late_extend_no_compensation.itf.json
# WALL 1.91 s, [violation], exit 1

npx --no-install quint run specs/quint/instances.qnt --main as_is_even \
  --invariant extendSuccessNeedsQuorumAndValidity \
  --max-steps 40 --max-samples 2000 --seed 0xb52954dda743c365 \
  --out-itf specs/quint/traces/as_is_even_extend_success_without_validity.itf.json
# WALL 1.89 s, [violation], exit 1

npx --no-install quint run specs/quint/instances.qnt --main as_is_slow \
  --invariant extendSuccessNeedsQuorumAndValidity \
  --max-steps 40 --max-samples 2000 --seed 0x7cefa39fde3e0737 \
  --out-itf specs/quint/traces/as_is_slow_extend_success_without_validity.itf.json
# WALL 1.92 s, [violation], exit 1
```

## 6. 反例清單（全部標為**候選發現**，不是已確認缺陷）

> 這些是模型抽樣找到的執行；分類（缺陷／設計取捨／資安）由 G2 依 `RULES.md` 與 `specs/quint/TRIAGE.md` 判定。本階段不修改 `src/**`，也不修改模型讓反例消失。

### 6.1 CF-1：as-is `extend` 在完成時超出租期仍回報成功（INV-6 第一句）

- trace：`traces/as_is_extend_success_without_validity.itf.json`（`as_is`，14 states、最後 index 13）。
- 關鍵狀態：`ART=200`、`DRIFT=4`、quorum=3；client 1 的 `lastExtendStart=1133`、`lastExtendEnd=1338`、`lastExtendOk=true`、`lastExtendRenewals=3`、`extensions=2`；A1(b) 的 `beliefEnd=1133+200-4=1329`，完成時間 1338 已超過 1329。
- 規則依據：INV-6 要求「完成時 `ART - drift - 自 extend 開始的 elapsed > 0`」；as-is 只看 quorum（`pottery/redlock.py:526-546`），所以回報成功。
- 同一根因的尺度／偶數變體：
  - `traces/as_is_even_extend_success_without_validity.itf.json`（`n=4`、quorum=3）：`lastExtendStart=900`、`lastExtendEnd=1100`、`beliefEnd=1096`、`lastExtendOk=true`。
  - `traces/as_is_slow_extend_success_without_validity.itf.json`（`ART=1000`、`DRIFT=12`）：`lastExtendStart=5698`、`lastExtendEnd=6692`、`beliefEnd=6686`、`lastExtendOk=true`、`lastExtendRenewals=5`。
- 分類提示：這是 as-is 與已確認 INV-6 的偏差；是否為缺陷、以及是否要在 library 端修復，交 G2。

### 6.2 CF-2：晚完成的 as-is `extend` 沒有補償釋放（INV-6 補償句）

- trace：`traces/as_is_late_extend_no_compensation.itf.json`（`as_is`，5 states、最後 index 4）。
- 關鍵狀態：client 0 的 `lastExtendStart=267`、`lastExtendEnd=465`、`lastExtendOk=true`、`lastExtendRenewals=3`、`beliefEnd=267+200-4=463`；master 0/1/2 仍為此 token、`expiry=467`，`now=465`（3 個 key 仍活著）。
- 規則依據：INV-6 要求在完成時超出有效期時，對所有仍持有本 token 的節點補償 release；as-is 沒有補償（`pottery/redlock.py:548-553`）。
- 同一 trace 也同時違反 CF-1；`as_is_slow` 的 trace（`expiry=6698`、`now=6692`）也留下 5 個仍活著的 key，可作為第二個補償缺口觀察。
- 分類提示：這會留下 stale key，影響後續 acquirer 的可用性；是否列為缺陷或設計取捨，交 G2。

### 6.3 規則層觀察（非狀態機反例）：INV-10 as-is 例外優先序

- `inv10ExitPriorityTest` 檢查 `contractExit(true,false) == BodyException`、`contractExit(false,false) == ReleaseException`，以及 `asIsExit(true,false) == ReleaseException`。
- 這表示 as-is 的 `__exit__`／`__aexit__` 在「body 已拋例外、release 失敗」時會用 release 例外覆蓋 body 例外，與 A2 的「body 例外優先」相反（`pottery/redlock.py:673`、`pottery/aioredlock.py:560`）。
- 這是控制流／例外優先序，不是可達的鎖狀態，因此沒有 ITF trace；是否要另開工作項修復，交 G2／人類。

### 6.4 沒有反例的項目

- INV-1：as-is 與 fixed 在 5000 samples 下都沒有反例。
- INV-2、INV-3、INV-4、INV-5、INV-7、INV-8、INV-9：as-is／fixed 抽樣均無反例（見 §5.3）。
- `boundary_tiny`：全部不變量在 500 samples 下無反例；acquire 在 1 ms 租期下必失敗，符合 `.001 s` 的既有測試預期。

## 7. 與 INV-1（互斥）的關係

在 A1(b) 的區間語意下，`extend` 成功的區間是 `[完成時刻, extend 開始 + ART - DRIFT)`。CF-1 的完成時刻已超過右端點，所以該區間是空的；模型因此**沒有**把 CF-1 直接算成 INV-1 的雙持有者反例。as-is 的 INV-1 在抽樣中沒有反例，理由與 `RULES.md` INV-4 的多數交集論證一致：key 的到期時間不早於操作開始 + ART，而有效期截止是操作開始 + ART - DRIFT，兩者之間有 DRIFT 的安全邊界。

真正的雙持有者風險需要下列之一，兩者都超出本模型已確認的 INV-1 語意：

1. 呼叫端把 `extend()` 的成功視為一個全新的完整租期（而不是 A1(b) 的錨定截止時間），於是過了 `start + ART - DRIFT` 仍繼續臨界區；此時 library 沒有通知、也沒有 fencing（OUT-2／OUT-4）。
2. 節點在租期內遺失 key（`OUT-1`／A5），使另一個客戶端在舊持有者的有效期內取得多數。

這兩點是 G2 判定「缺陷／設計取捨／資安」的關鍵輸入；本模型不把它們當成已確認的 INV-1 反例。

## 8. 未決事項（open questions）

1. **per-master 時序**：本模型把所有 master 效果放在操作開始、用單一 `delay` 表示完成時間；沒有建模個別 master 的 SET/PEXPIRE 完成時間差。因此「少數 PEXPIRE 成功、多數失敗」的補償路徑不可達。若 G2 要驗證該路徑，需加入 per-master skew 或明確的 fault injection；這會擴大狀態空間。
2. **RedisError／`raise_on_redis_errors`**：模型以「該 master 未生效」抽象失敗（ENV-10），沒有顯式 `RedisError` 事件，也沒有檢查 `QuorumIsImpossible` 分支（ENV-4）。是否需要建模，請 G2 決定。
3. **`locked()` 的 min/median 差異**：模型取所有持有者的最小 TTL，比同步程式「第一個 quorum 的最小值」更保守；這使 INV-9 的某些「回報過大」方向不可能被找到。是否要精確建模同步 quorum 的收集順序，待確認。
4. **`ART < 100 ms` 的 drift 精度**：模型用 `ceil(ART/100)+2` 毫秒；對 1 ms 邊界是 3 ms（真值 2.01 ms）。是否需要分數毫秒或微秒時間單位，待確認。
5. **呼叫端信念語意**：INV-1 只採用 A1(b)；「把 extend 成功當成新租期」或「使用過期 `locked()` 值」的呼叫端行為不在模型內。是否要把這類 caller model 納入下一輪，交 G2。
6. **INV-10 的建模層級**：目前是純函式（例外優先序），不是狀態機，因此沒有 ITF trace；若要求所有規則都有可回放的狀態 trace，需要把 context manager 的例外狀態納入模型。
7. **`NUM_EXTENSIONS` 負值**：程式沒有驗證；模型只涵蓋 0（下界）與 3（預設）。負值會讓所有 extend 立即 `TooManyExtensions`，是否需要另立實例，待確認。
8. **ACT-5／ACT-14 非同步語義**：重試、timeout、backoff 與 async 等待全部 master 的行為未建模（OUT-6／A6）；本輪只驗證同步安全語意。

## 9. 重現方式

```bash
cd specs/quint
npx --no-install quint typecheck model.qnt
npx --no-install quint typecheck instances.qnt
npx --no-install quint typecheck test.qnt
npx --no-install quint test test.qnt --main asIsTest --match '.*Test' --max-samples 10
npx --no-install quint test test.qnt --main fixedTest --match '.*Test' --max-samples 10
npx --no-install quint test test.qnt --main boundaryTest --match '.*Test' --max-samples 10
# 反例（會回傳 1，並寫出 traces/*.itf.json）
npx --no-install quint run instances.qnt --main as_is \
  --invariant extendSuccessNeedsQuorumAndValidity \
  --max-steps 30 --max-samples 200 --seed 0x673a6573714b6fb2 \
  --out-itf traces/as_is_extend_success_without_validity.itf.json
npx --no-install quint run instances.qnt --main as_is \
  --invariant lateExtendCompensated \
  --max-steps 30 --max-samples 2000 --seed 0xcd7dd9223e2d6dac \
  --out-itf traces/as_is_late_extend_no_compensation.itf.json
# 修正版（應 exit 0）
npx --no-install quint run instances.qnt --main fixed \
  --invariants atMostOneValidHolder acquireSuccessNeedsQuorumAndValidity \
  tokensAreFresh noTwoTokenMajorities validHolderHasQuorum \
  extendSuccessNeedsQuorumAndValidity failedExtendCompensated lateExtendCompensated \
  extensionLimit releaseSuccessNeedsQuorum lockedReportWithinSafeBound \
  --max-steps 40 --max-samples 5000
```
