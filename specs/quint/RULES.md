# pottery 分散式鎖規則（G1 確認草稿）

> 本文件是 grill 階段的**候選規則**，供 G1 確認／微調，尚未定稿，也不是已驗證結論。
> 基準：`agent-playground/pottery`，base commit `2d7c70a`（master）。
> 已套用第一輪 G1 答案（`specs/quint/GRILL-ANSWERS.md:6-54`，A1–A6）。
> 狀態標記：`confirmed`＝程式碼／README／G1 答案有證據；`assumption`＝本輪暫定、不阻擋建模，G1 可推翻；`candidate`＝未確認且會阻擋建模（本版無）。
> 行號皆指上述 base commit。

## ENV 環境假設

- **ENV-1（confirmed）叢集與 quorum**：鎖部署在 n 個互相獨立的 Redis master 上；quorum 定義為嚴格多數 `floor(n/2)+1`，程式以 `> len(masters)//2` 判定。README 建議生產環境用 5 個 master、可容忍 2 個失效。證據：`pottery/redlock.py:343`、`pottery/redlock.py:494`、`pottery/redlock.py:544`、`pottery/redlock.py:591`、`pottery/aioredlock.py:262`、`pottery/aioredlock.py:422`、`pottery/aioredlock.py:468`、`pottery/aioredlock.py:508`、`README.md:331-335`。
- **ENV-2（confirmed）時間模型**：客戶端有效期以單調時鐘計算（`timeit.default_timer()`），不看牆鐘；漂移補償固定為 `auto_release_time * 0.01 + 0.002` 秒。伺服器時鐘跳躍不建模。證據：`pottery/timer.py:106`、`pottery/timer.py:123-127`、`pottery/redlock.py:230`、`pottery/redlock.py:315-316`、`pottery/aioredlock.py:239-240`。
- **ENV-3（confirmed）Redis 語義**：每個 master 對單一 key 的操作是線性一致的；`SET ... NX PX` 與三個 Lua 腳本（acquired / extend / release）各自原子執行，腳本內先比對 token 再操作。不建模 replication／failover。證據：`pottery/redlock.py:278-285`、`pottery/redlock.py:113-120`、`pottery/redlock.py:128-134`、`pottery/redlock.py:142-148`、`pottery/aioredlock.py:202-209`。
- **ENV-4（confirmed）Redis 錯誤**：個別 master 可拋 `RedisError`；該次操作視為該 master 失敗。預設 `raise_on_redis_errors=False`；若錯誤數超過半數且旗標為真，拋 `QuorumIsImpossible`，否則以 `False`／`ExtendUnlockedLock`／`ReleaseUnlockedLock` 呈現。證據：`pottery/redlock.py:238`、`pottery/redlock.py:332-341`、`pottery/base.py:320-331`、`pottery/exceptions.py:64-65`。
- **ENV-5（confirmed）租期到期**：master 在 PTTL 到期後刪除 key；客戶端只能由 master 回報的 TTL 減去漂移與已耗時間推算剩餘有效期。證據：`pottery/redlock.py:282`、`pottery/redlock.py:287-296`、`pottery/redlock.py:447-501`、`pottery/aioredlock.py:386-430`。
- **ENV-6（confirmed）續約次數**：每次成功 `acquire` 重置續約計數；預設最多續約 3 次，超過拋 `TooManyExtensions`。證據：`pottery/redlock.py:232`、`pottery/redlock.py:322-323`、`pottery/redlock.py:523-524`、`pottery/redlock.py:545`、`pottery/exceptions.py:55-56`。
- **ENV-7（confirmed）資料持久性與 fencing**：模型假設租期內 master 不重啟、不遺失 key；不建模 Byzantine master；沒有 fencing token。節點資料遺失下的嚴格互斥不在承諾內（A5）。證據：`pottery/redlock.py:128-148`（只靠 token 比對，無 fencing）、`specs/quint/GRILL-ANSWERS.md:44-46`。
- **ENV-8（confirmed）臨界區長度**：呼叫端負責在算出的有效期內結束臨界區；library 不會通知或中止超期的臨界區（A1）。證據：`README.md:369-375`、`specs/quint/GRILL-ANSWERS.md:10-14`。
- **ENV-9（assumption）叢集成員固定**：建模期間 master 集合不變；訊息延遲有限、公平排程下計時器終將觸發。理由：程式沒有成員變更路徑，模型需要固定 `n` 才能窮盡。預設採用 `n=5`，G1 可推翻。
- **ENV-10（assumption）Redis 錯誤不改變狀態**：模型把 `RedisError` 視為「該命令未生效」（對互斥安全最保守的解讀）。真實的「命令已生效但回應逾時」不建模；它只會留下本 token 的 key，屬 liveness/stale-key 問題。理由：程式無法區分兩者，且互斥安全不應依賴未確認的回應。預設採用，G1 可推翻。
- **ENV-11（assumption）提早返回後的 in-flight 操作**：同步路徑在達到 quorum 即返回，`BailOutExecutor.__exit__` 只 `shutdown(wait=False)`，因此可能有尚未完成的 SET/PEXPIRE 在背景執行。模型將這些操作視為只會作用在自己的 token 上，且不改變「是否持有」的判定。理由：它們不引入第二個 token；但補償 release 與 in-flight SET 的競態可能留下 stale key，屬 liveness。預設採用，G1 可推翻。證據：`pottery/executor.py:53-58`、`pottery/redlock.py:325`、`pottery/redlock.py:343-348`。

## INV 不變量

- **INV-1（confirmed，主要不變量）同一時間最多一個有效持有者**：對任意客戶端 c，其「認為自己持有有效鎖」的區間是 `[成功完成 acquire/extend 的時刻, 該次操作開始時刻 + auto_release_time - drift)`；此區間之外（含 release 成功後、租期到期後）c 不得認為自己持有鎖。任一時刻，最多一個 c 的區間包含該時刻。（A1 選 (b)；A3 固定 extend 以 extend 開始計時。）證據：`pottery/redlock.py:343-348`、`pottery/redlock.py:315-316`、`specs/quint/GRILL-ANSWERS.md:10-14`、`specs/quint/GRILL-ANSWERS.md:26-30`。
- **INV-2（confirmed）acquire 成功需 quorum 且在有效期內**：只有嚴格多數 master 的 `SET NX` 成功，且完成時 `auto_release_time - drift - elapsed > 0`，才可回報成功。證據：`pottery/redlock.py:343-348`、`pottery/aioredlock.py:262-267`。
- **INV-3（confirmed）每次嘗試使用全新 token**：每次 `_acquire_masters` 都產生新的 UUID；成功持有的 token 不重複使用。證據：`pottery/redlock.py:322`、`pottery/aioredlock.py:246`。
- **INV-4（confirmed）兩個不同 token 不可能同時各自擁有多數**：`SET NX` 只在 key 不存在時成功；任兩個多數集合必有交集，交集節點不可能同時存放兩個 token。證據：`pottery/redlock.py:278-285`、`pottery/redlock.py:343`。
- **INV-5（confirmed）只有 token 持有者可 extend/release**：extend 與 release 的 Lua 腳本先 `GET` 比對 token，不符則回 0，不刪除、不續約。證據：`pottery/redlock.py:128-134`、`pottery/redlock.py:142-148`、`pottery/redlock.py:298-313`。
- **INV-6（confirmed，嚴格續約規則）extend 成功需 quorum 且完成時仍在有效期內**：必須嚴格多數 `PEXPIRE` 成功，**而且**完成時 `auto_release_time - drift - 自 extend 開始的 elapsed > 0`；否則對所有仍持有本 token 的節點補償 release（只刪 token 相符的 key），補償失敗只記錄，最後拋 `ExtendUnlockedLock`。（A3 確認。）**現況偏差（候選缺陷）**：`extend()` 只在 quorum 時遞增計數並返回，沒有計時、沒有完成檢查，失敗時也沒有補償 release；`pottery/redlock.py:526-546`、`pottery/redlock.py:548-553`、`pottery/aioredlock.py:456-470`、`pottery/aioredlock.py:472-477`。模型應保留 as-is 行為以產生反例，再以本不變量檢查修正版。
- **INV-7（confirmed）續約次數上限**：成功續約次數不得超過 `num_extensions`；達上限後再 extend 拋 `TooManyExtensions`。證據：`pottery/redlock.py:523-524`、`pottery/redlock.py:545`。
- **INV-8（confirmed）release 成功需 quorum**：只有嚴格多數 master 刪除了本 token 的 key，才可回報成功；否則在檢查錯誤後拋 `ReleaseUnlockedLock`。證據：`pottery/redlock.py:579-599`、`pottery/aioredlock.py:496-516`。
- **INV-9（confirmed）`locked()` 的回報不得超過安全上界**：只有嚴格多數 master 仍持有本 token 時才可回報正值；回報值不得超過「回報 quorum 的 TTL 最小值 − drift − 查詢已耗時間」，且不得超過真實安全剩餘時間。同步取 quorum 最小值、非同步取排序後的中位索引，只要求上界安全，不要求兩者數值相同（A6 ②）。證據：`pottery/redlock.py:492-498`、`pottery/aioredlock.py:422-427`、`specs/quint/GRILL-ANSWERS.md:50-54`。
- **INV-10（confirmed，例外優先序）body 例外優先**：若臨界區的 body 已拋例外，`__exit__`／`__aexit__` 的 release 失敗不得覆蓋它；release 失敗只記錄（可掛在 `__context__` 或抑制）。body 沒有例外時，release 失敗照常拋出。補償路徑（acquire/extend 失敗後的 release）一律吞掉 `ReleaseUnlockedLock` 並記錄，不改變原本的 `False`／`QuorumIsImpossible`／`ExtendUnlockedLock` 結果。（A2 確認。）**現況偏差（候選缺陷）**：`__exit__` 直接呼叫 `self.__release()`，release 例外會覆蓋 body 例外；`__aexit__` 同樣直接 `await self.__release()`。證據：`pottery/redlock.py:648-674`（特別是 `:673`）、`pottery/aioredlock.py:542-560`（特別是 `:560`）、`specs/quint/GRILL-ANSWERS.md:18-22`。

## ACT 行為規則

- **ACT-1（confirmed）acquire 開始**：每次嘗試先產生新 token、把續約計數歸零、啟動單調計時器。證據：`pottery/redlock.py:322-325`、`pottery/aioredlock.py:246-249`。
- **ACT-2（confirmed）逐 master 嘗試**：對每個 master 執行 `SET key token PX int(auto_release_time*1000) NX`；回傳真表示該 master 取得成功。證據：`pottery/redlock.py:278-285`、`pottery/aioredlock.py:202-209`。
- **ACT-3（confirmed）quorum 與完成檢查**：統計成功數；一旦嚴格多數成功，計算 `validity = auto_release_time - drift - elapsed/1000`；`validity > 0` 才成功。同步在達到 quorum 時可提早返回（`BailOutExecutor`，其餘 future 背景完成）；非同步等所有 master 回應後才判斷（A6 ①，模型以同步語義為契約）。證據：`pottery/redlock.py:325`、`pottery/redlock.py:332-348`、`pottery/executor.py:53-58`、`pottery/aioredlock.py:251-267`、`specs/quint/GRILL-ANSWERS.md:50-54`。
- **ACT-4（confirmed）acquire 失敗補償**：未達 quorum 或 validity ≤ 0 時，對所有 master 執行 token 比對的 release，抑制 `ReleaseUnlockedLock`；再依 `raise_on_redis_errors` 決定是否拋 `QuorumIsImpossible`，否則回 `False`。證據：`pottery/redlock.py:350-353`、`pottery/aioredlock.py:269-272`。
- **ACT-5（confirmed）阻塞重試**：`blocking=True` 且 `timeout=-1` 時無限重試；`timeout>=0` 時在時限內重試；每次失敗後隨機退避 `uniform(0, 0.2)` 秒；時限用盡回 `False`。`blocking=False` 只嘗試一次；`blocking=False` 且指定 timeout 直接拋 `ValueError`。證據：`pottery/redlock.py:414-432`、`pottery/aioredlock.py:353-371`、`pottery/redlock.py:231`。注意：程式對 `timeout=-1` 沒有重試次數上限（`README.md:403-405` 明言無限阻塞）；本輪把「重試上限」解讀為 timeout／單次嘗試（見 CODE-SUMMARY 的 assumption），不阻擋建模。
- **ACT-6（confirmed）`locked()`**：對所有 master 查詢本 token 的 PTTL；若嚴格多數回報非零，回報「quorum 統計值 − drift − 查詢已耗時間」，負值截為 0；否則回 0。同步取第一個 quorum 的最小 TTL，非同步取排序後的中位索引（A6 ②只要求安全上界）。證據：`pottery/redlock.py:447-501`、`pottery/aioredlock.py:386-430`。
- **ACT-7（confirmed）extend 前置檢查**：續約計數已達 `num_extensions` 時拋 `TooManyExtensions`，不送任何 Redis 命令。證據：`pottery/redlock.py:523-524`、`pottery/aioredlock.py:453-454`。
- **ACT-8（confirmed）逐 master 續約**：對每個 master 執行 token 比對的 `PEXPIRE key int(auto_release_time*1000)`；只有 key 仍存有本 token 才成功。不會對遺失 key 的少數節點重新 `SET`（A4：設計取捨）。證據：`pottery/redlock.py:128-134`、`pottery/redlock.py:298-305`、`pottery/aioredlock.py:222-229`、`specs/quint/GRILL-ANSWERS.md:36-38`。
- **ACT-9（confirmed，as-is）extend 成功條件**：嚴格多數 `PEXPIRE` 成功時，續約計數加一並立即返回；沒有計時器、沒有完成時有效期檢查、沒有補償。（此 as-is 行為與 INV-6 衝突，見 INV-6 的現況偏差。）證據：`pottery/redlock.py:526-546`、`pottery/aioredlock.py:456-470`。
- **ACT-10（confirmed，as-is）extend 失敗**：未達 quorum 時，先依 `raise_on_redis_errors` 檢查錯誤，再拋 `ExtendUnlockedLock`；不執行補償 release。證據：`pottery/redlock.py:548-553`、`pottery/aioredlock.py:472-477`。
- **ACT-11（confirmed）release**：對所有 master 執行 token 比對的 `DEL`；嚴格多數成功即返回；否則在檢查錯誤後拋 `ReleaseUnlockedLock`。證據：`pottery/redlock.py:573-599`、`pottery/aioredlock.py:496-516`。
- **ACT-12（confirmed，as-is）context manager**：`__enter__` 依 `context_manager_blocking`／`context_manager_timeout` 呼叫 acquire，失敗拋 `QuorumNotAchieved`；離開時必定執行一次 release。as-is 的 release 失敗會覆蓋 body 例外（與 INV-10 衝突）。證據：`pottery/redlock.py:603-630`、`pottery/redlock.py:648-674`、`pottery/aioredlock.py:520-560`。
- **ACT-13（confirmed）到期與崩潰**：master 在租期到期後自動刪除 key；客戶端崩潰時不需主動 release，其他客戶端在租期到期後可取得。證據：`pottery/redlock.py:282`、`tests/test_redlock.py:55-61`、`tests/test_aioredlock.py:91-97`。
- **ACT-14（confirmed）同步／非同步差異**：①同步達到 quorum 即返回，非同步等所有 master；③acquire 失敗補償時，同步轉發 `raise_on_redis_errors`，非同步沒有轉發。兩者依 A6 視為漂移，模型以同步語義為契約、非同步應對齊；②`locked()` 的 min/median 實作差異只要求安全上界。證據：`pottery/redlock.py:325-351`、`pottery/aioredlock.py:249-270`、`pottery/redlock.py:492-498`、`pottery/aioredlock.py:422-427`、`specs/quint/GRILL-ANSWERS.md:50-54`。
- **ACT-15（confirmed）不可重入**：同一個 Redlock 實例再次 `acquire` 會產生新 token，舊 key 仍以舊 token 存在，因此會阻塞到舊租期到期後才成功；不是可重入鎖。證據：`pottery/redlock.py:322`、`tests/test_redlock.py:64-74`。

## OUT 明確不驗證

- **OUT-1（confirmed）無 fencing 的嚴格互斥**：節點崩潰／重啟遺失 key、或需要 fencing token 才能排除的雙持有者情境，不在承諾內；模型不加入 `MasterRestart`／資料遺失事件（A5）。證據：`specs/quint/GRILL-ANSWERS.md:42-46`、`pottery/redlock.py:128-148`。
- **OUT-2（confirmed）臨界區超期**：library 不通知、不中止超過租期的臨界區；「臨界區在有效期內結束」是 ENV，不是可驗證的 library 保證（A1）。證據：`README.md:369-375`、`specs/quint/GRILL-ANSWERS.md:10-14`。
- **OUT-3（confirmed）extend 修復少數節點**：extend 不會對遺失 key 的少數節點重新 `SET`，也不保證續約後仍保有全部節點；這是設計取捨（A4）。證據：`pottery/redlock.py:128-134`、`pottery/redlock.py:526-547`、`specs/quint/GRILL-ANSWERS.md:34-38`。
- **OUT-4（confirmed）跨叢集公平性、代管 Redis 認證設定、Redis 伺服器內部實作、Byzantine master、replication/failover、伺服器時鐘跳躍、持久化設定**：皆不在本次模型範圍。證據：`README.md:311-314`（只承諾分散式互斥，未承諾上述項目）、`specs/quint/GRILL-ANSWERS.md:42-46`。
- **OUT-5（confirmed）同步／非同步 `locked()` 的數值相等**：只驗證兩者都不超過安全上界，不驗證 min 與 median 得到相同數字（A6 ②）。證據：`specs/quint/GRILL-ANSWERS.md:50-54`。
- **OUT-6（confirmed）liveness／吞吐量**：不驗證任意分割下的最終取得、公平性、等待時間上界或 5 個 master 中容錯 2 個的可用性；本次只驗證安全不變量。
- **OUT-7（confirmed）例外訊息與 `redis_errors` 內容**：只驗證例外型別與優先序（INV-10），不驗證訊息文字、欄位順序或底層 Redis 錯誤字串。證據：`pottery/exceptions.py:44-65`。
