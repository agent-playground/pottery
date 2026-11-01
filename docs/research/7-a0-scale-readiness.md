# Issue #7 S4／A0：pottery 規模與就緒度量測

| 項目 | 內容 |
| --- | --- |
| 工作項 | [agent-playground/pottery#7](https://github.com/agent-playground/pottery/issues/7) |
| 任務類型 | `agent-analyze`（分析型，不產生程式碼變更） |
| 流程步驟 | S4（P1）＝ **A0 規模與就緒度量測** |
| 目標 repo | `agent-playground/pottery` |
| 基準分支 | `software-factory` |
| 變體 | b |
| 量測日期 | 2026-11-01 |
| 本次變更 | 只新增本報告 `docs/research/7-a0-scale-readiness.md` |
| 狀態 | 分析完成；規模與 R 等級**僅為建議**，待 HG2 人類裁定 |

---

## 0. 範圍與依據

Issue #7 的「需求描述（PRD）」只有一句「S 流程的 S4 步驟」，三條 DoD 是表單固定文字。為避免猜測，本報告先以工廠流程定義還原 S4 的可驗收內容：

- `templates/factory/S.yaml:35-41`：`S4` → `規模與就緒度量測（A0）`、`task_type: agent-analyze`、`per: system`、`gates: [HG2]`。
- 機制 repo `docs/29-brownfield-adoption-playbook.md` §9.1（S4 列）：產出物是「報告 PR 合併」，題目是 A0。
- 同文件 §7.1「A0 — 規模與就緒度量測」：報告須含六維度數值與量測方法、依 §4.2「至少 2 個維度」規則的建議等級、模組清單（建置可重現性／CI 狀態／行覆蓋率／建議 R 等級），量不到者須寫「量不到＋原因」。

因此本報告以 **docs/29 §7.1 的 A0 檢核項**作為分析內容的驗收基準，並在 §6 逐條對照 Issue #7 的三條 DoD。這是引用流程規格，不是自行擴大範圍；A0 的數值與建議不具放行效力，規模等級與 R 等級由 HG2 人類簽核（docs/29 §4.2 第 3 點、§5）。

**範圍限制**：只讀取與量測，不修改 `src/`、測試、設定、CI 或依賴；本次 diff 只有本報告。

---

## 1. 結論摘要

1. **規模建議：小型（small）。** 六個維度全部落在「小型」：正式程式碼 **2.80 KLOC**、可部署單元 **1**、外部整合 **1**（Redis）、負責團隊 **1（推定）**、**1 repo／5 個 bounded context**、關聯式 DB 資料表 **0**。依 docs/29 §4.2「至少 2 個維度達標」規則，六個維度皆達小型，建議小型。
2. **就緒度建議：R2（條件式）。** 建置可重現、測試與覆蓋率證據充分：以 pinned 依賴在 Python 3.14.4＋Redis 7 重跑，**323 passed、行與分支覆蓋率 100%**（19 個 `pottery/*.py` 全部 100%）。唯一未達標的是「CI 綠燈」：repo 的 GitHub Actions workflow 只綁 `master`，`software-factory` 上從未觸發，API 回報的 workflow run 總數為 **0**。
3. **因此的管制建議**：HG2 若接受「以本地重跑 CI 指令綠燈」作為替代證據，可判 **R2**；若堅持機械判準「CI 綠燈」，則在 CI 接上 `software-factory` 前，`fix-bug`／`update-deps` 應以 **R0** 管制。`analyze`、`write-docs`、`add-tests` 不受此限制（R0 已允許）。
4. **下一個閘門與工作項**：HG2 裁定規模／R 等級／核心模組後，依 S5 開 A1（架構）、A2（測試）、A3（相依）、A4（風險）各一張 `agent-analyze`。另有一張**人類**工作項：把 CI trigger 擴及 `software-factory`（`.github/**` 是 H5 guardrail，agent 不得修改）。
5. **Issue #7 DoD**：REQ-1／REQ-2／REQ-3 三條皆已涵蓋（§6）。本報告不具放行效力，仍需人類審查。

### 決策卡

| 決策 | 建議值 | 主要證據 |
| --- | --- | --- |
| 規模等級 | **小型** | 6/6 維度皆小型；2.80 KLOC、1 部署單元、1 外部整合、1 repo／5 contexts |
| 就緒度 | **R2（條件式）** | 323 passed、100% coverage、建置可重現；CI 未在 `software-factory` 觸發 |
| 核心模組初判 | `distributed-lock`、`id-generation`（其餘為 containers／core plumbing） | 靜默失敗型併發正確性；見 §3 |
| 下一個閘門 | **HG2** | docs/29 §5：R 等級由人類依 A0／A2 證據簽核 |
| 下一個工作項 | S5 A1–A4 各 1 張 | docs/29 §7.2：小型專案 A1–A4 各 1 |

---

## 2. 證據與量測方法

### 2.1 可重現的量測步驟

量測環境：Python **3.14.4**、Redis **7-alpine**（本機 Docker，`localhost:6379`）、依賴版本取自 `requirements.txt`（全部 pinned）。測試套件不是 E2E；它與 CI 一樣只依賴一個 Redis 服務（`.github/workflows/python-package.yml:18-29`）。

```bash
# 1) 打包與語法（不需外部服務）
python3 setup.py --version          # → 3.0.1
python3 -m compileall -q pottery    # → exit 0

# 2) 以 pinned 依賴建立隔離環境
python3 -m venv /tmp/pv
/tmp/pv/bin/pip install pytest==9.2.0 pytest-asyncio==1.4.1 pytest-cov==7.1.0 \
  coverage==7.17.0 redis==8.1.0 mmh3==5.3.1 typing_extensions==4.16.0 uvloop==0.23.0

# 3) 啟動 CI 同款 Redis 服務
docker run -d --rm -p 6379:6379 --name pottery-redis redis:7-alpine

# 4) 跑 CI 的測試指令（只把 --cov=tests 換成逐檔覆蓋率報告）
/tmp/pv/bin/python -m pytest --cov-config=.coveragerc --cov=pottery \
  --cov-report=term-missing --cov-report=json:/tmp/coverage.json -q
# → 323 passed in 25.35s
# → TOTAL 100%（1854 statements、380 branches、0 missing）
```

**解讀**：`323 passed` 與 CI 的 pytest 指令一致（`.github/workflows/python-package.yml:40-41`）；CI 另外還會跑 mypy（:42）、flake8／isort（:44-47）、bandit（:48-50），本次 A0 只量測測試與覆蓋率，未重跑那三個工具。覆蓋率 100% 只表示每一行／分支都被執行過，**不表示測試語意充分**（docs/29 §5 的同一提醒）；語意缺口留給 A2。

### 2.2 六個維度

| 維度 | 量測值 | 級別 | 量測方法與證據 |
| --- | --- | --- | --- |
| 正式程式碼 KLOC | **2.80 KLOC**（2,798 SLOC） | 小型（< 50） | 以 Python `tokenize` 計 `pottery/*.py` 的非空行、非註解行；排除 `tests/`、`setup.py`、設定與文件。原始非測試行數為 4,868（含註解／空行），全 repo Python 行數 8,775（含測試 3,907）。 |
| 可部署單元數 | **1** | 小型（1–3） | 只有一個 PyPI library artifact（`setup.py:48-72`），沒有服務、批次、前端或 daemon；`entry_points={}`（`setup.py:77`）。 |
| 外部整合數 | **1** | 小型（0–3） | 唯一外部系統是 Redis：預設 `redis://localhost:6379/0`（`pottery/base.py:52-53`）、`install_requires` 的 `redis`（`setup.py:72`）、CI 的 Redis service（`.github/workflows/python-package.yml:18-29`）。Redlock 可傳多個 Redis master，但仍是同一種 Redis 協定，不另計外部系統。 |
| 負責團隊數 | **1（推定）** | 小型（1） | repo 內沒有 `CODEOWNERS`、team manifest 或 ownership 檔；`setup.py:37-38` 的 author／email 指向單一上游作者。**量不到組織實際負責團隊**，以可觀察證據推定 1；若實際 ≥4 才可能影響等級，但依 2 維度規則仍需另一維度同時達標。 |
| repo 數／模組數 | **1 repo／5 個 bounded context** | 小型（1 repo、≤ 5） | repo 內只有 `pottery/` 一個套件；以職責與相依方向切成 5 個 context（§2.3）。不以 19 個 `.py` 檔當模組數，因為檔案是實作單位，不是 bounded context。 |
| DB 資料表數 | **0** | 小型（< 50） | 沒有關聯式資料庫、migration 或 schema 檔；狀態全在 Redis keyspace。這是「不適用＋原因」，不是估算。 |

**2 維度規則（docs/29 §4.2）**：六個維度全部達到「小型」，遠超過「至少 2 個維度達標」的門檻，因此建議 **小型**。沒有任何維度達到中型或大型；即使把 19 個檔案誤當模組數（單一維度衝到大型），其餘五個維度仍全為小型，依規則也不能定為大型或中型。

### 2.3 模組清單與就緒度

邊界判斷依據：以「共用基礎 → 領域能力 → 對外契約」的相依方向切分，並用 `pottery/*.py` 的 `ImportFrom` 圖驗證（19 個檔案、無循環依賴）。同一 context 內的檔案彼此高度耦合，跨 context 只經由 `base.py`、`annotations.py`、`exceptions.py` 等共用層。

| Context | 檔案（SLOC） | 職責 | 測試檔 | 建置可重現 | CI 狀態 | 行覆蓋率 | 建議 R |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `core-plumbing` | `base.py`(255)、`monkey.py`(33)、`annotations.py`(9)、`exceptions.py`(36)、`executor.py`(13)、`timer.py`(60) | Redis 連線／key mixin、JSON monkey patch、型別、例外、提早結束的 executor、計時器 | `test_base.py`、`test_monkey.py`、`test_executor.py`、`test_timer.py`、`test_doctests.py` | 可重現（共用套件；`setup.py --version`＝3.0.1） | workflow 存在，但 `software-factory` 未觸發 | **100%** | **R2\*** |
| `data-structures` | `dict.py`(120)、`list.py`(283)、`set.py`(218)、`deque.py`(132)、`counter.py`(193)、`bloom.py`(143)、`hyper.py`(94)、`cache.py`(211) | Redis-backed 容器、Bloom filter、HyperLogLog、cache decorator | `test_dict.py`、`test_list.py`、`test_set.py`、`test_deque.py`、`test_counter.py`、`test_bloom.py`、`test_hyper.py`、`test_cache.py` | 可重現（同上） | 同上 | **100%** | **R2\*** |
| `distributed-lock` | `redlock.py`(394)、`aioredlock.py`(267) | Redlock quorum、Lua acquire／extend／release、sync／async 雙實作 | `test_redlock.py`、`test_aioredlock.py` | 可重現（同上） | 同上 | **100%** | **R2\*** |
| `id-generation` | `nextid.py`(163)、`aionextid.py`(114) | 單調遞增 ID、Lua CAS、quorum、sync／async 雙實作 | `test_nextid.py`、`test_aionextid.py` | 可重現（同上） | 同上 | **100%** | **R2\*** |
| `public-api` | `__init__.py`(60) | 28 個公開匯出（`pottery/__init__.py:58-90`）與套件契約 | `test_doctests.py`（19 個模組 doctest＋README doctest） | 可重現（同上） | 同上 | **100%** | **R2\*** |

\* **R2 的條件**：三個判準中的「建置可重現」與「行覆蓋率 ≥ 60%」已由本次量測滿足；「CI 綠燈」在 `software-factory` 上不成立。若 HG2 嚴格要求 CI 綠燈，這五個 context 都應暫判 **R0**，直到 CI 接上工廠 trunk；R0 仍允許 analyze／write-docs／add-tests，因此 P1–P3 的分析與補測試不受阻。

**測試規模**：17 個 `test_*.py`（另有 `conftest.py`、`__init__.py`，共 19 個測試目錄下的 `.py`）、273 個 `test_*` 函式／方法，pytest 實際收集 **323 個 case**（含 parametrize 與 doctest 展開）。`pytest` 的 323 passed 是在 Python 3.14.4 上跑的；CI 矩陣另外承諾 3.11–3.15（`.github/workflows/python-package.yml:17`），本次未逐一跑五個版本。

### 2.4 根因與結構觀察

**為什麼是小型**：這是一個單一 PyPI library，不是服務拓撲。它只有一個 artifact、一個外部系統（Redis）、一個負責團隊（推定）、五個 bounded context，且沒有關聯式資料庫。2.80 KLOC 也遠低於 50 KLOC 的小型上限。程式碼品質與規模是兩件事：專案有 323 個綠燈測試與 100% 覆蓋率，但這不會把它變成中型或大型。

**為什麼 R2 只能條件式**：程式碼與測試面沒有觀察到就緒度缺口，缺口在**自動化管線的觸發範圍**。

- `.github/workflows/python-package.yml:6-10` 的 `on.push`／`on.pull_request` 都只列 `master`；工廠 trunk 是 `software-factory`。
- GitHub API `repos/agent-playground/pottery/actions/runs` 回報 `total_count = 0`；repo 的 default branch 是 `master`。
- 因此：對 `software-factory` 開的 PR 不會跑 repo 的 pytest／mypy／flake8／bandit，`gh run list` 也沒有任何 run 可以證明「CI 綠燈」。本次以**完全相同的 pytest 指令**在本機重跑得到 323 passed，證明測試本身是綠的；但這是本地證據，不是 CI 證據。
- `.github/**` 是 H5 guardrail，agent 不得修改（factory-stop-rules SR3）；把 trigger 擴及 `software-factory` 必須由人類開 PR 處理。

**次要觀察（不影響本次等級，留給 S5）**：

1. `setup.py:71` 宣告 `python_requires='>=3.10, <4'`，但 classifiers 與 CI 矩陣從 3.11 起（`setup.py:55-69`、`.github/workflows/python-package.yml:17`）。3.10 是否真的支援，repo 內沒有可驗證證據；建議 A3／人類裁決要嘛測 3.10，要嘛把下限改成 3.11。
2. `Makefile:26-55` 的 `make install` 依賴 macOS Homebrew 與 pyenv，Linux 開發者只能照 CI 的 `pip install -r requirements.txt`；建置可重現性目前主要由 `requirements.txt`（全 pinned）與 CI workflow 承擔，文件沒有把 Linux 路徑寫清楚（S6 可補）。
3. repo 沒有 `CODEOWNERS`／team manifest，團隊數只能推定；若組織要把 ownership 機械化，這是 HG1／S6 的前置資料。

### 2.5 量不到與限制

| 項目 | 狀態 | 原因與影響 |
| --- | --- | --- |
| 組織實際負責團隊數 | **量不到（推定 1）** | repo 無 `CODEOWNERS`／team manifest；只能由 `setup.py` 的單一作者推定。若實際 ≥4，需人類在 HG2 調整；但依 2 維度規則仍不足以單獨升級。 |
| `software-factory` 上的 CI 綠燈 | **量不到（確認未觸發）** | workflow 只綁 `master`，Actions run 總數 0。這是 R2 的唯一條件缺口。 |
| 關聯式 DB 資料表數 | **不適用（0）** | 沒有 SQL DB／migration；Redis keyspace 不是資料表。 |
| 上游生產依賴情形 | **量不到（不在 repo）** | README 的「battle tested in production at scale」是上游 `brainix/pottery` 的宣稱；本 fork 是否被組織生產服務使用，不在 repo 內。onboarding 已由人類裁定 `business-criticality=tactical`（`catalog-info.yaml` 的 2026-11-01 裁定註解）。 |
| 測試語意品質 | **未量測（不在 A0）** | 100% 行／分支覆蓋率只證明「執行過」，不證明斷言有效；留給 A2 與之後的驗證閘門（docs/29 §10）。 |
| 五個 Python 版本的 CI 矩陣 | **未逐一重跑** | 本次只在 Python 3.14.4 重跑；CI 承諾 3.11–3.15，尚未有 run 可證明。 |
| E2E／外部服務整合測試 | **未跑（DoD 排除）** | Issue DoD 明文排除需外部服務的 E2E；本次跑的 323 個是單元／doctest，只用一個本機 Redis。 |

---

## 3. 影響範圍

### 3.1 受影響模組

- **全部 19 個 `pottery/*.py`、5 個 context** 都受本次量測結論影響，因為規模與 R 等級是系統級／模組級的流程參數。
- **最高風險的兩個 context**：
  - `distributed-lock`：`redlock.py:107-113` 註冊 Lua acquire 腳本、`redlock.py:357` 的 `acquire()`、`redlock.py:494-495` 以 `len(ttls) > len(masters)//2` 與 `min(ttls)` 做 quorum 判定；`aioredlock.py:422` 是 async 版 quorum。這些邏輯失敗時不一定拋錯，而是**兩個進程同時持鎖**。
  - `id-generation`：`nextid.py:82-88` 註冊 Lua CAS 腳本、`nextid.py:220` 呼叫；失敗模式是 **ID 重複或非單調**，直接破壞下游資料一致性。
  - 這兩者也是 onboarding 把 `risk-profile` 定為 `medium` 的理由（`catalog-info.yaml` 的風險註解），與規模無關。
- **`core-plumbing` 的 `monkey.py:45-59`** 會 monkey patch `json.dumps`，是每個容器讀寫路徑上的序列化層；它的影響面廣，但本次測試全綠，沒有觀察到缺陷。

### 3.2 受影響使用者與下游

- **PyPI 消費者**：任何 `pip install pottery` 的 Python 服務；`install_requires` 是 `redis`、`mmh3`、`typing_extensions`（`setup.py:72`）。
- **使用 Redlock／NextID 的下游服務**：受影響的是併發正確性與 ID 唯一性，屬於資料一致性風險，不是可用性風險。
- **工廠流程**：S5 的 A1–A4 範圍由本報告的 5 個 context 決定；S6 的文件集、S8 的 add-tests 清單也會沿用。若 HG2 把規模判成中型，A2–A4 會從「各 1 張」膨脹成「每模組各 1 張」，審查成本會增加，但本次六維度不支持中型。
- **CI 缺口是全域性的**：只要 trigger 不改，所有對 `software-factory` 的 PR 都得不到 repo 的測試／lint／security 訊號，這是五個 context 共同的流程風險。

### 3.3 本次變更的影響

本次只新增一份 `docs/research/` 報告，不動 `src/`、`tests/`、`.github/`、`catalog-info.yaml` 或依賴。依 factory-crosscheck 的 analyze 模式，變更應只落在 `docs/`；沒有 H1–H3（授權／金流／敏感資料）路徑。

---

## 4. 方案比較

| 方案 | 內容 | 優點 | 為何採用／拒絕 |
| --- | --- | --- | --- |
| **A（建議）** | 規模判**小型**；就緒度建議 **R2（條件式）**；照小型流程開 S5 A1–A4 各 1 張 | 與六維度證據一致；不膨脹審查成本；A1–A4 仍能覆蓋 lock／ID 風險 | **採用**。條件是 HG2 接受本地重跑 CI 指令作為 CI 綠燈的替代證據；否則以 R0 過渡。 |
| **B（拒絕）** | 因為 19 個 `.py`、sync／async 雙實作、Redlock quorum，把規模判**中型** | 對複雜度較保守；A2–A4 會按模組細分 | **拒絕**。違反 docs/29 §4.2 的 2 維度規則：只有「檔案數」這一個非正式維度可能衝高，KLOC／部署單元／外部整合／團隊／repo-context／DB 五個維度都是小型。`complexity=medium` 是變更風險軸，不是規模軸；把它當規模會多開 3 倍以上的分析單。 |
| **C（拒絕，但部分借用）** | 在 CI 接上 `software-factory` 前，一律判 **R0** | 對「CI 綠燈」判準最保守；不會在沒有自動化訊號時開 fix-bug／update-deps | **不採為預設**：建置可重現、323 passed、100% 覆蓋率是強證據，全面 R0 會不必要地阻擋修 bug 與 CVE 更新。**借用其精神**：在 CI 接上前，fix-bug／update-deps 以 R0 管制；analyze／write-docs／add-tests 照常。 |
| **D（拒絕）** | 用原始行數 8,775 或 4,868 判 KLOC | 數字較大、看起來較保守 | **拒絕**。A0 明文要求 KLOC 排除測試、產生碼、設定與文件；8,775 含 3,907 行測試，4,868 含註解與空行。正式 SLOC 是 2,798，兩者相差 1.7–3.1 倍，用原始行數會把小型誤判成中型。 |

**決策理由**：A0 的目的是給 HG2 一個可比較的量測基準，不是把專案「講得越複雜越安全」。六維度與覆蓋率都指向小型＋高測試覆蓋；唯一真正的缺口是 CI 觸發範圍，應以一個獨立的人類工作項修掉，而不是用規模或 R 等級去掩蓋。

---

## 5. 建議下一步

以下工作項都可以直接開成 Issue；「驗收條件草案」是可觀察的結果，不是「更好／完善」這種空泛詞。

### 5.1 HG2（人類閘門，不開工單）

- **做什麼**：依本報告裁定規模＝小型、五個 context 的 R 等級（R2 條件式或 R0 過渡）、核心模組清單（初判 `distributed-lock`、`id-generation`）。
- **驗收條件草案**：導入追蹤 Issue 出現 HG2 簽核留言（簽核人、日期、採用的規模／R 等級／核心模組、對 CI 缺口的處置），並把結果寫進 P1 變數。

### 5.2 H-CI（人類，guardrail 變更）

- **做什麼**：把 `.github/workflows/python-package.yml` 的 `on.push`／`on.pull_request` 分支從只有 `master` 擴及 `software-factory`（或建立等效的 required check），讓工廠 PR 得到 pytest／mypy／flake8／bandit 訊號。
- **為什麼是人類**：`.github/**` 是 H5 guardrail，agent 不得修改（factory-stop-rules SR3）。
- **驗收條件草案**：
  1. 對 `software-factory` 開的 PR 會觸發 `Python package` workflow；
  2. 五個 Python 版本（3.11–3.15）皆 `success`；
  3. `gh api repos/agent-playground/pottery/actions/runs` 的 `total_count > 0`，且最近一筆 `head_branch=software-factory`、`conclusion=success`；
  4. branch protection 或 ruleset 把該 check 設為 required。

### 5.3 S5-A1（`agent-analyze`，架構與模組盤點）

- **做什麼**：盤點 5 個 context 的容器／模組圖、職責、模組間呼叫與共用資料、候選接縫（seam）、推斷的設計決策。
- **範圍**：只讀 `pottery/`、`tests/`、`README.md`；不改程式碼。
- **驗收條件草案**：報告含 (a) 文字或 Mermaid 模組圖、(b) 每個 context 的職責與對外介面、(c) `base.py`／`monkey.py` 等共用層的耦合點、(d) 至少 2 個候選接縫與風險、(e) 推斷的設計決策逐條標「推斷，待人類確認」。

### 5.4 S5-A2（`agent-analyze`，測試現況與缺口）

- **做什麼**：盤點測試框架、執行方式、各 context 覆蓋率、未覆蓋的關鍵路徑，排出 add-tests 優先序。
- **已知起點**：本次量到 323 passed、19 檔 100% 行／分支覆蓋率；A2 應改問「哪些**語意**沒被斷言」，而不是重複量行覆蓋率。
- **驗收條件草案**：報告含 (a) 測試框架與指令、(b) 五個 context 的覆蓋率表（引用本次或重跑）、(c) 至少 5 條未覆蓋／弱斷言的關鍵路徑（含 `redlock.py` quorum、`nextid.py` CAS 的失敗注入）、(d) 建議的 add-tests 工作項清單，每項一個模組或檔案，附驗收條件草案。

### 5.5 S5-A3（`agent-analyze`，相依健康度）

- **做什麼**：盤點 `requirements.txt`／`setup.py` 的第三方相依：過時版本、已知 CVE、停止維護者；另檢查 `python_requires` 與 CI 矩陣的不一致。
- **驗收條件草案**：報告含 (a) 相依清單與落後版本數、(b) CVE 編號與嚴重度（用 `pip-audit` 或等效工具）、(c) 建議的 update-deps 工作項（CVE 類標優先）、(d) 對 `python_requires>=3.10` 與 classifiers 3.11–3.15 不一致的裁決建議。

### 5.6 S5-A4（`agent-analyze`，風險熱點）

- **做什麼**：找風險熱點，作為核心模組認定與 P3 排序依據。
- **驗收條件草案**：報告含 (a) 命中 `risk-paths.yml` H1–H7 的路徑、(b) 近一年 `git log` 變動頻率最高的檔案、(c) 兩者交集、(d) 建議核心模組清單（僅建議，HG2 認定）、(e) 每個核心模組適用 Quint 或 Hegel 的初判（docs/29 §10）。

### 5.7 選配：W-PYVER（人類或 `agent-fix-bug`）

- **做什麼**：讓 `python_requires`、classifiers、CI 矩陣三者一致（目前 3.10 vs 3.11–3.15）。
- **驗收條件草案**：三處宣告同一組下限與上限；若保留 3.10，CI 矩陣新增 3.10 且綠燈；若不保留，`python_requires` 改為 `>=3.11` 並在 CHANGELOG／README 說明。

### 5.8 選配：W-OWNERS（人類）

- **做什麼**：新增 `CODEOWNERS` 或 team manifest，讓「負責團隊數」可機械量測，並支撐 HG1／S6 的 ownership。
- **驗收條件草案**：repo 根目錄有 `CODEOWNERS`（或等效），涵蓋 `pottery/`、`tests/`、`.github/`；下一位 agent 的 A0 能直接量到團隊數而不是推定。

---

## 6. Issue #7 驗收條件對照

| ID | Issue DoD 原文 | 狀態 | 本報告的涵蓋方式 |
| --- | --- | --- | --- |
| REQ-1 | 有可驗證的測試/驗證方式（測試紅→綠或明確驗證命令） | **passed** | §2.1 列出可重現指令：`setup.py --version`、`compileall`、pinned venv、Redis container、`pytest --cov`；結果 323 passed／100%。§2.3 另列出每個 context 的覆蓋率。 |
| REQ-2 | 不觸碰高風險路徑（H1–H3 等硬規則，見 risk-paths.yml） | **passed** | 本次 diff 只有 `docs/research/7-a0-scale-readiness.md`；沒有 `src/`、`tests/`、`.github/`、`catalog-info.yaml`、依賴或 H1–H3 路徑。§3.3 明列。 |
| REQ-3 | 跑測試確認綠燈（不跑需外部服務的 E2E） | **passed** | §2.1：以 CI 同款 pytest 指令在本機 Redis 7 上跑 323 passed、25.35s、100% 覆蓋率；沒有跑 E2E。CI 本身的綠燈另見 §2.4 的 trigger 缺口（不影響本條的本地驗證）。 |

**A0 檢核項對照**（docs/29 §7.1，非 Issue DoD，供 HG2 審查）：

| A0 要求 | 涵蓋位置 | 狀態 |
| --- | --- | --- |
| 六維度數值與量測方法 | §2.2（含 KLOC 排除規則、工具與指令） | 已涵蓋 |
| 依 2 維度規則的建議等級 | §2.2、§1 | 已涵蓋（小型） |
| 模組清單＋建置可重現／CI／覆蓋率／R 等級 | §2.3 | 已涵蓋（5 contexts、R2 條件式） |
| 量不到須寫「量不到＋原因」 | §2.5 | 已涵蓋（團隊數、CI 綠燈、DB、上游依賴、語意品質） |

---

## 7. 給人類審查者的三句話

1. **規模沒有懸念**：2.80 KLOC、1 個 library、1 個 Redis 整合、1 repo／5 contexts，六維度全小型。
2. **測試比預期好**：323 passed、19 檔 100% 行／分支覆蓋率；但這是執行覆蓋，不是語意保證，A2 仍值得開。
3. **唯一要你動手的是 CI**：workflow 只綁 `master`，`software-factory` 從未跑過；在它接上之前，R2 只能是條件式，fix-bug／update-deps 建議以 R0 管制。
