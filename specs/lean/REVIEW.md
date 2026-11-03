Verdict: PASS-WITH-NITS

# Lean 獨立對抗式審查報告（Issue #47，pottery Redlock）

> 審查者為另一個 session，沒有參與撰寫證明。目標是推翻 `specs/lean/` 的結論，不是背書。
> 輸出語言依 `specs/quint/.user-content/CONTEXT.md` 的 `## Output language (MANDATORY)`：繁體中文。
> 本次只寫入本檔；未改動其他檔案。`lake build` 只在 `specs/lean` 與 `/tmp` 的複本內執行。

## 一句話結論

5 條 headline 在 Lean 內成立，沒有後門，axiom 全在允許清單內，A-1 時序抽象也如實標成 assumption。但有三個 **major** 的範圍／誠實性缺口：(1) 模型把不同客戶端的操作視為原子、不交錯，這點沒寫進抽象帳本；(2) 「修正版」只有單步的區域引理，從未證明修正後的轉移系統保有 INV-1；(3) 定理 `as_is_late_extend_no_compensation` 名實不符。我沒找到會讓證明或模型失效的 blocker，所以判定 `PASS-WITH-NITS`，不判 `PASS`。

## 1. 建置與後門（逐項）

| 檢查 | 結果 | 證據 |
|---|---|---|
| `lake build`（既有 `.lake`） | 通過，`Build completed successfully (8 jobs)`，只有 unused variable／deprecated 警告 | `specs/lean`，我自己執行 |
| 乾淨複本重建 | 通過。複製到 `/tmp/lcopy`、刪掉 `.lake` 後 `lake build` 完成 8 個 job | 我自己執行 |
| `lake env lean Audit.lean` | 4 條依賴 `[propext, Classical.choice, Quot.sound]`；`contract_extend_success_implies_validity` 只依賴 `[propext, Quot.sound]`。全在允許清單內 | `Audit.lean:9-13` |
| `headline-theorems.txt` 與 `Audit.lean` 一致 | 5 條與 5 行 `#print axioms` 一一對應，沒有漏 | `headline-theorems.txt:1-5` |
| 掃描 `sorry`／`admit`／`axiom`／`opaque`／`native_decide`／`unsafe`／`extern`／`implemented_by`／`set_option` | 前七項 **0 命中**。`set_option` 只有 `set_option linter.unusedSimpArgs false`，只關 linter，不影響可靠性 | `Specs/Invariants.lean:3` |

結論：無後門。唯一的 `set_option` 是 linter 開關，嚴重度 **minor**。後面的 `PASS-WITH-NITS` 不是因為它。

## 2. Statement fidelity

**2.1 `at_most_one_valid_holder`**（`Specs/Proofs.lean:27-30`）：忠實對應 RULES R1／INV-1。
- 它對 `ReachableAsIs` 的所有可達狀態成立，用的是歸納不變量 `Inv`（`Specs/Invariants.lean:19-26`），不是同義反覆。
- 證明依賴「兩個有效持有者各需 ≥3 個 live key」加上「token 不同 ⇒ 持有集合不相交 ⇒ 3+3>5」。這是 Redlock 的多數交集論證本身。
- `Valid` 以 `now < beliefEnd` 定義（`Invariants.lean:7`）。這對應 G1 A1(b)，但有 F-2.3 的限制。

**2.2 `as_is_late_extend_reports_success`**（`Proofs.lean:30-46`）：與 R2 的反例對應。
- 它斷言 `lastExtendOk=true`、`lastExtendEnd ≥ lastExtendStart + 196`，並明確綁定 `ReachableAsIs w1s13`。
- 非同義反覆。

**2.3 `as_is_late_extend_no_compensation`（major，statement fidelity／命名）**（`Proofs.lean:48-62`）
- RULES R3 的敘述是「extend **未達 quorum 或完成時已超出有效期**，要補償所有仍持有 token 的節點」。as-is 違反的是兩條路徑：晚完成，以及未達 quorum 時已 PEXPIRE 的節點不被釋放（`pottery/redlock.py:548-553`，ACT-10）。
- 這條定理只證明「extend **成功**、晚完成、且 3 個節點仍持有 token」。成功的 extend 本來就應該留著 token，所以 `holders=3` 本身不是「缺少補償」的證據。
- 它與 CF-1 的差別只是多了 `holders=3`。「as-is 沒補償、契約有補償」只能靠對照 `Specs/Examples.lean:631-642`（同一 `w2s3`、同一 `delay=198`）才看得出來。這不是同一個定理內的比較。
- as-is 的「quorum 失敗後留下已續約節點」這條路徑**沒有任何定理或 witness**。
- 嚴重度：major（statement 比 R3 窄、名稱超過內容）。它不是弱化，因為這份敘述已在 G3 簽核。但「已證 R3 的 as-is 違反」這個說法在 REPORT／MODEL-MAP 中沒有被限縮。

**2.4 契約定理（major，覆蓋範圍）**
- `contract_extend_success_implies_validity`（`Proofs.lean:64-83`）是 `ok = quorumOk && valid`（`Model.lean:205`）的直接展開，內容近乎定義性。它證明「模型實作了 RULES」，不證明任何系統性質。
- `contract_late_extend_compensates`（`Proofs.lean:85-130`）只涵蓋 `hlate`（晚完成）。「quorum 不足」的失敗路徑不在敘述內，但 RX 與 R3 兩者都要求。兩條定理的 `hdelay`、`hext` 完全沒用到（建置警告 `Proofs.lean:87-88` 已提示）。
- `ReachableContract`、`StepContract`、`ExtendSucceededWithinValidity` 定義了（`Model.lean:268-306`）卻**沒有任何定理使用**。我 grep 了 `Specs/**`，只有定義處命中。
- 後果：Issue 要求「驗證修正」，也就是修正後的 extend 仍保有互斥。目前沒有 `at_most_one_valid_holder` 對 `ReachableContract` 的版本。修正後的轉移系統保有 INV-1 **沒有被證明**。REPORT §7 已說這是模型層級契約，但沒有說清楚「修正保有 INV-1」不在已證範圍內。

**2.5 F-2.3：INV-1 對 F5 的意義（minor／info）**
- `at_most_one_valid_holder` 對 as-is 為真。原因是 as-is 晚完成 extend 後 `beliefEnd` 仍等於 `start+196`，客戶端的「有效區間」在回傳成功時已過期（`Model.lean:219-222`），所以不會與別人重疊。
- 這表示 F5（晚完成的 extend）在本模型中**不破壞 INV-1**。真實後果是呼叫者收到「成功」，卻已沒有 A1(b) 定義的有效期。
- 這與 G2 的 `security = no` 一致，但報告沒有明說「F5 不產生雙持有者」。建議補一句，避免讀者以為 F5 會破壞互斥。

## 3. Non-vacuity

- `ReachableAsIs` 非空且可走出具體狀態：`reachable_w1s13`、`reachable_w2s3`、`reachable_w2s4` 在 Lean 內證明（`Specs/Witnesses.lean:135-176`）。
- `Examples.lean:7-29`：`validHolderCount w2s3 = 1`、`holders w2s4 0 = 3`、`applyExtend true w2s3 0 0` 成功、`applyExtend true w2s3 0 198` 補償後 `holders=0`。四者皆由 `decide` 檢查。
- 契約兩條定理的假設可滿足（上列兩個 example 即是）。`hlate` 在 `delay=198` 成立。
- `at_most_one_valid_holder` 的 `Inv` 不是空洞：`validHolderCount w2s3 = 1` 證明「有效持有者」不是恆為 0。
- 邊界缺口：沒有 witness 是「兩個客戶端先後都曾有效且 `now` 重疊邊界」。例如 `now = beliefEnd` 恰好相等的狀態沒有被舉例。這是 minor，不影響結論。

## 4. Model fidelity

逐項檢查時序、延遲、排程、鍵、對齊、原子性。

| 面向 | 結果 | 證據 |
|---|---|---|
| quorum 為嚴格多數 3/5 | 忠實 | `Model.lean:36`；`pottery/redlock.py:343,544,591` |
| 單一 master 的 `SET NX PX`、token 比對的 extend／release | 忠實 | `Model.lean:110-141`；`pottery/redlock.py:113-148` |
| `extend` 無 timer、無完成檢查、失敗不補償 | 忠實 | `Model.lean:197-226`；`pottery/redlock.py:523-553`（我讀過程式，確認 `extend()` 沒有 `ContextTimer`） |
| extend 的 `delay` 沒有上界 | 與程式一致：程式沒有 deadline／timer；模型以 `MaxOpDelay=205` 取有限範圍 | `Model.lean:35` |
| 未 acquire 就 extend | 安全：程式初始化 `_uuid = ''`，Lua 比對不相等，續約 0 個 | `pottery/redlock.py:275,128-134` |
| 效果放在操作開始、完成在 `start+delay` | 保守：真實 PEXPIRE 於 `start` 之後才落地，key 到期時間 ≥ 模型值 | `Model.lean:136-141,164` |
| 反例 witness 的 `delay` 是否依賴程式走不到的行為 | **未發現**。用的只是「命令早執行、回應晚到」，真實網路可以做到，沒有 timer 提前之類的模型獨有行為 | 見 4.2 |

**4.1（major）不同客戶端的操作在模型裡不交錯。**
- `StepAsIs` 每次只執行一個客戶端的完整操作，且 `now := finish`（`Model.lean:156-189,197-226,252-266`）。客戶端 A 的操作視窗 `(start, finish)` 內，客戶端 B 不能行動。
- 真實程式是多執行緒、多 master 並行；A 的 SET 落在各 master 的時間不同，B 可以在中間插入。
- 我自行推演：因為真實 key 到期時間 ≥ `start+200 > beliefEnd`，INV-1 在真實交錯下應該仍成立，所以我**不認為這使證明失效**。但這是我的論證，Lean 沒有證明。
- `MODEL-MAP.md` 的抽象帳本與「Explicitly not covered」都**沒有列出這個簡化**。A-1 只講單一操作的 `delay`，沒有講跨客戶端原子性。
- 嚴重度：major（未揭露的抽象，影響 `at_most_one_valid_holder` 的適用範圍），不是 blocker。

**4.2 反例 witness 逐 conjunct 檢查。**
- CF-1（`w1s13`，`Witnesses.lean:61-62`）：`applyExtend false w1s12 1 205`。`start=1133`、`finish=1338`、`renewals=3`，且模型把 key 到期時間設在 `1333`，**早於** `finish=1338`。
  - 也就是 extend 回傳成功時，3 個被續約的 key 在伺服器端已到期。`delay=205 > ART=200` 要求某個回應被延遲超過整個租期。
  - 這在真實網路是可能的（TCP 重傳、GC、排程飢餓），不是「走不到」，但很極端。報告用「晚完成」描述，沒有點出這一點。
  - CF-1 的 `w1s1`～`w1s3`（`Witnesses.lean:` `applyExtend false w1s0 1 47` 起）是客戶端 1 在 acquire 前呼叫 extend。我確認程式在此時不會出錯（見上表），所以不是不可達，只是 trace 裡的雜訊，不影響結論。
- CF-2（`w2s4`，`Witnesses.lean:77`）：`delay=198`，只比窗口多 2 ms，比 CF-1 更貼近現實。
- 兩條定理陳述中的欄位都是真實可觀測量（時間、`lastExtendOk`、`renewals`、`holders`），沒有混入 `nextToken` 之類模型自加欄位。MODEL-MAP 這個說法我核對屬實。
- `lastExtendRenewals`：模型記錄的是 extend 開始時 **所有** 持有者數（`Model.lean:201`）；程式的 `num_masters_extended` 在 quorum 當下回傳，成功時恰為 3。witness 的 `=3` 對兩邊都成立，但一般狀態下兩者語意不同。minor。

**4.3 同步 quorum 提早返回後的 in-flight 操作（A-7）。** 模型沒有建模。我的推演是：in-flight SET 只會落下本 token 的 key，到期時間 ≥ `start+200`，不會產生第二個 token，所以對 INV-1 安全。此推演合理，但仍是論證，不是 Lean 證明；文件已標成 assumption。

## 5. 反例的意義

- CF-1、CF-2 是**模型層級**的反例。`RULES.md` 的 A-1、`REPORT.md` §4.2、`MODEL-MAP.md` 的 Claim boundary 都明寫「程式可達性依賴 A-1，Lean 沒有證明」。這點誠實，且對照我讀的 `extend()` 程式碼，A-1 描述的交錯在真實系統可達，只是需要大延遲。
- 兩者依賴的假設都已標成 assumption：A-1（時序）、A-2（固定 n=5、ART=200）、A-4（Redis 錯誤＝命令未生效）。
- 沒有看到「模型較寬，所以真實也會壞」的推論。
- G2 的 `real`／`security = no` 來自 `TRIAGE.md`，Lean 報告沒有改寫，這也正確。

## 6. 報告誠實性

| 項目 | 結果 |
|---|---|
| G3 簽核證據與 `G3-SIGNOFF.md` 一致 | 一致：`philipz`、`2026-11-03T02:22:53.189Z`、`approved`（`G3-SIGNOFF.md:6-8`；`MODEL-MAP.md:9`、`REPORT.md` 開頭與 §12） |
| 模型層級 vs 程式層級 | 文件全程使用「模型層級」，且 §9 列出不能推出的結論。誠實 |
| 「本輪未改 statement」 | 我核對 `MODEL-MAP.md` 的 5 條 snapshot 與 `Proofs.lean` 現文逐字相符。但 snapshot 與證明在同一個目錄、同一輪，且 `specs/` 沒有 git 歷史可比（`git status` 顯示整個 `specs/` 為未追蹤），所以「phase 2 後未變更」我無法獨立驗證 |
| `MODEL-MAP.md` 審查 checkbox | 「獨立對抗式審查」標為「尚未完成」，沒有偽造完成。審查日誌第一列仍是「待執行」，需要在本審查後更新（由人或下一輪更新，我不改） |
| 「Witness 的每個 conjunct 都對應真實程式欄位」 | 對兩條反例定理屬實；但見 4.2 的 `renewals` 語意差 |
| 抽象帳本完整性 | 缺「跨客戶端操作原子性」（見 4.1），以及「CF-1 的 key 在回傳時已到期」這一事實 |

## 7. 發現總表

| # | 嚴重度 | 內容 | 證據 |
|---|---|---|---|
| F1 | major | 跨客戶端操作不交錯，未列入抽象帳本與 not-covered | `Model.lean:252-266`；`MODEL-MAP.md` 抽象帳本 |
| F2 | major | 修正版轉移系統是否保有 INV-1 沒有被證明；`ReachableContract`／`StepContract` 未被任何定理使用 | `Model.lean:268-306`；`Proofs.lean` 全檔 |
| F3 | major | `as_is_late_extend_no_compensation` 名稱超過內容，未涵蓋 R3 的 quorum 失敗路徑 | `Proofs.lean:48-62`；`RULES.md` R3 |
| F4 | minor | 兩條契約定理近乎定義展開；補償定理只涵蓋晚完成，`hdelay`／`hext` 未使用 | `Proofs.lean:64-130` |
| F5 | minor | CF-1 witness 的 `delay=205 > ART`，回傳時 key 已到期；報告沒說明 | `Witnesses.lean:61-62`；ITF 終態 `masters.expiry=1333` |
| F6 | minor | `lastExtendRenewals` 的語意在一般狀態下與程式的 `num_masters_extended` 不同 | `Model.lean:201` |
| F7 | minor | `set_option linter.unusedSimpArgs false` | `Invariants.lean:3` |
| F8 | info | INV-1 對 as-is 為真，意味 F5 不破壞互斥；報告可明說 | `Model.lean:219-222` |
| F9 | info | statement「未變更」無法由 git 歷史獨立驗證 | `git status` |

沒有 blocker：建置、axiom、後門、statement 弱化、模型忠實度的硬規則都未被違反。

## 必須修（下一輪）

1. 在 `MODEL-MAP.md` 的抽象帳本與「Explicitly not covered」補上：跨客戶端操作視為原子、不交錯，並說明為什麼不影響 INV-1（key 到期時間 ≥ `start+200`），或明講這是未證明的論證。（F1）
2. 在 `REPORT.md` §7 與 `MODEL-MAP.md` 明說：修正版保有 INV-1 **尚未證明**。若要落到「驗證修正」，補 `at_most_one_valid_holder` 的 `ReachableContract` 版本（`Inv` 的證明幾乎可重用）。（F2）
3. 更名或補強 `as_is_late_extend_no_compensation`：在文件裡說明它只涵蓋「晚完成且成功」；as-is 的「quorum 失敗後不補償」另補 witness 或定理，並補契約的 quorum 失敗補償定理。（F3、F4）

## 可以不修

- 拿掉未用到的 `hdelay`／`hext` 或加底線（F4）。
- 說明 CF-1 的 `delay=205 > ART` 是極端案例，並考慮把 CF-2（`delay=198`）當主要 witness（F5）。
- 對齊或註明 `lastExtendRenewals` 的語意（F6）。
- 移除或註解 `set_option linter.unusedSimpArgs false`（F7）。
- 在 REPORT 補一句「F5 不產生雙持有者」（F8）。

## 未驗證

- 真實 Python 執行緒／網路排程是否會走到 CF-1／CF-2：Lean 與本審查都未驗證，我只從程式碼確認它沒有被程式排除。
- 跨客戶端交錯下 INV-1 是否仍成立：只有我的論證，沒有形式化。
- 「statement 自 phase 2 以來未變更」：沒有 git 歷史可比，只能核對 snapshot 與現文一致。
- ITF trace 與 Lean witness 逐步一致性：我只核對了兩條 trace 的終態欄位（`now`、`lastExtend*`、`beliefEnd`、`expiry`）與 Lean 一致，沒有逐步比對 17 個轉移。
- 任意 `n`、任意 `ART` 的推廣：固定實例 A-2，未檢查。
- 非同步 `AIORedlock`、`locked()`、`__exit__` 例外優先序：不在 Lean 範圍，未檢查。
- `verify-lean.sh` 與 dashboard delta：未重跑（我只手動執行 build、audit、掃描），`metrics-baseline.txt` 的數字未獨立重算。
