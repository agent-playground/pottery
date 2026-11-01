# pottery 納管提案 — Issue #31（agent-onboard · 變體 a · 單層 PR）

> 給審核者的一頁說明。`proposals/onboarding/` 是**提案**，不是任何機制的讀取
> 路徑：合併後需人類親手搬檔（見 §4）才生效（docs/27 §2、§7.3）。本 run 為
> 唯讀分析：除本目錄三份提案檔外，未改動 repo 任何既有檔案。
> 掃描基準：`software-factory` @ `748bc61`（2026-11-01）。

## 1. 掃描摘要（全部為本 run 實跑命令所得，非臆測）

| 面向 | 實際發現 |
|---|---|
| 是什麼 | **Pottery — Redis for Humans**：Pythonic Redis 存取函式庫（README.md:1-8）。核心：Redis 後端容器（`RedisDict/Set/List/Counter/Deque`）、機率結構（`BloomFilter/HyperLogLog`）、快取（`redis_cache/CachedOrderedDict`）、**分布式協調原語**（`Redlock/AIORedlock`、`NextID/AIONextID`、`synchronize`）。上游為 brainix/pottery，本 repo 是 playground fork（setup.py:33-35：`version='3.0.1'`、`url=…brainix/pottery`）。 |
| 語言／建置 | Python，無 pyproject/poetry/uv：打包 = setuptools `setup.py`（python_requires `>=3.10, <4`，:71）；依賴 = pip（`requirements.txt` 全鎖定矩陣 + `requirements-to-freeze.txt` 源頭）；`Makefile` 為個人工作站流程（brew/pyenv；`release` target 人工 `twine upload`）。 |
| 測試 | **pytest**（`pytest.ini: asyncio_mode=auto`；pytest-asyncio）。`tests/` 19 個 `test_*.py` + conftest；session fixture 連 `redis://localhost:6379/{db}`（tests/conftest.py:44-47）；README.md 亦為可執行契約（tests/test_doctests.py:63-66 跑 doctest）。靜態檢查：mypy（py.typed）、flake8、isort、**bandit**（`.bandit.yaml`）。 |
| CI | `.github/workflows/python-package.yml`：矩陣 Python 3.11–3.15 ×5（:17）+ **redis service container**；pytest+cov → mypy → flake8/isort → bandit。⚠️ 僅觸發於 `master`（:7-10）——對工廠 trunk `software-factory` 的 PR 不會跑它，工廠側由 crosscheck/rescore 把關（人類如欲讓原生 CI 覆蓋工廠 PR，屬 repo 設定變更，另議——本提案不碰 `.github/`）。 |
| 目錄結構 | 扁平：**無** `src/`、`migrations/`、`api/`、auth/、payment/、openapi/proto、schema 檔、Dockerfile、k8s（find -iname 全數零命中）。源碼僅 `pottery/`（19 .py + py.typed，4790 行）與 `tests/`（21 檔）。 |
| 高風險面 | **無認證授權／金流／PII／加密路徑**：`password|credential|oauth|jwt|token|auth`、`payment|billing|invoice` 對 pottery/、tests/ 零命中；`pottery/`+`tests/` 無 cryptography/hashlib import（requirements 中的 `cryptography`、`pyjwt` 僅為鎖版傳遞依賴；`bloom.py:33` 的 `mmh3` 為非密碼學雜湊）。真正的風險面是**靜默失敗型併發原語**：Lua 鎖腳本（redlock.py:107-142）、跨 master quorum 表決（redlock.py:343/494/544/591、aioredlock.py:262/422/468）、Lua CAS 單調 ID（nextid.py:82-88）、全域 `json.dumps` monkey patch（monkey.py:33-55）、BailOutExecutor（executor.py:26）。 |
| 服務數量／協調 | 單一 artefact（一個 PyPI 套件）；多 Redis master quorum 屬**套件內**協調，無跨服務拓撲。 |

## 2. 三軸建議（提案值一律 `TODO`——裁定權在人類，docs/27 §7.1②）

| 軸 | 建議值 | 一句話理由（逐軸完整證據見 catalog-info.yaml 註解） |
|---|---|---|
| `factory.io/business-criticality` | **tactical** | 開發者面向開源函式庫；無組織內生產依賴證據（workflows 無 publish/deploy job，PyPI 發布為人工 Makefile 路徑）。人類若知悉有生產服務用此 fork 的鎖/ID → 升 operational。 |
| `factory.io/risk-profile` | **medium** | 不 low：鎖/單調 ID 是靜默失敗型併發原語，bug 後果是兩進程同持鎖/ID 重複，無聲擴散給所有用客；不 high：H1–H3 四類路徑零命中，且 19 測試檔 + README doctest + bandit/mypy 防護網完整。對照：factory-scoreboard 同級（docs/16 §5.1）。 |
| `factory.io/complexity` | **medium** | 不 low：sync/async 雙實作（redlock↔aioredlock、nextid↔aionextid，同語意寫兩遍）、3.11–3.15 五版本矩陣、base.py 被 10 模組直接 import、需外部 Redis 才能驗證語意；不 high：單 artefact、扁平兩層 ~4.8k 行、無跨服務拓撲/無 schema/API 定義面。 |

建議值全數採納之基準分：0+1+1 = **2 → review**（score.ts `tierForTotal` ≤1 on-loop）；
`agent-automerge` 依新納管硬規則一律先 `"false"`。

> ⚠️ **搬檔前必須把三個 `TODO` 換成合法值**（`tactical|operational|strategic` /
> `low|medium|high` / `low|medium|high`，以 `src/scoring/types.ts:12-21` 為準）。
> **值缺席或非法一律 fail-safe 計 2、無任何錯誤訊息**（docs/27 §7.2，幽靈值
> `supporting` 實案：預期 total 1 實測 3）。拼錯一個字元 = 靜默升監督等級。

## 3. risk-paths 重點（依實際結構撰寫，絕不複製範本——docs/16 §5.3）

- **H1、H2、H3、H6：留空 `[]` + 「掃描未發現，待人類確認」註解**——對應結構
  全部零命中（逐條證據寫在檔內註解）。硬規則不湊數：`**/*token*` 型泛樣式在
  本 repo 會重演 scoreboard 誤報教訓（`git ls-files '**/*token*'` 實跑零命中）。
- **H4：列名 7 檔**（base/monkey/redlock/aioredlock/nextid/aionextid/executor），
  每條 `git ls-files` 恰命中 1 個實際檔案並附行號證據。刻意不用 `pottery/**`
  （實跑命中全部 19 檔 → 每個實質 PR 都觸發，警訊淹沒）與 `**/*lock*`
  （實跑連帶命中 2 個測試檔）。代價＝模組更名需同步更新本檔，由 H5 保護。
- **H5：無條件四條自我保護路徑**（`.github/**`、`CODEOWNERS`、
  `catalog-info.yaml`、`.dsh/skills/**`）——前兩條目前命中 5 檔／0 檔（後者
  為建立即生效的前瞻保護），後兩條為搬檔後目標與未來涵蓋。
- **H7：`pottery/__init__.py`**（:21-55 匯出面 + :58 `__all__`＝Python 函式庫
  的公開 API 代理）；README doctest 契約不入 H7（取捨見檔內註解）。

## 4. 搬檔指令（人類審核後執行）

```bash
git mv proposals/onboarding/catalog-info.yaml .
mkdir -p .github/factory
git mv proposals/onboarding/risk-paths.yml .github/factory/risk-paths.yml
git rm -r proposals/onboarding
```

> ⚠️ **撞檔警告（本 run 實際掃描發現，請先決定再執行）**：repo 根目錄
> **已存在** `catalog-info.yaml`、`.github/factory/risk-paths.yml` 與
> `proposals/onboarding/`（皆由 PR #27 自 Issue #26 流程併入；根目錄
> catalog-info 檔頭還註記了 2026-11-01 的人類裁定
> `tactical/medium/medium`）。上述 `git mv` 對既有目標檔會直接失敗。
> 審核後請擇一：
> ① **若採納本提案為新版本**：`git mv -f` 覆寫（或先 `git diff` 比對新舊
>   risk-paths 差異再覆寫），再 `git rm -r proposals/onboarding`；
> ② **若既有生效檔已足夠**：僅 `git rm -r proposals/onboarding` 清掉提案目錄
>   （本 PR 的價值只剩文件化理由，供複核）。
> 搬檔前先依 §2 把三個 `TODO` 換成裁定值——`TODO` 計 2。

## 5. 合併後的驗證步驟（docs/16 §5.2 雙向探測——兩個方向都要驗）

僅有設定檔不代表工廠讀得到。先對**本 PR** 跑 rescore 取得基準，再補一個
探測 PR 驗證「命中硬規則」方向——只驗一般檔案無法區分「硬規則正確」與
「硬規則根本沒載入」：

```bash
# 方向一：對一般檔案的 PR（如只改 docs/）——
#   預期：triggeredHardRules: []、escalated: false、分數 = 三軸基準分
#   （搬檔並裁定後；未裁定前 TODO 一律計 2，分數偏高屬預期）
gh workflow run factory-rescore.yml --repo aswf-dev/software_factory \
  -f repo=agent-playground/pottery -f base_branch=software-factory -f pr_number=<PR>

# 方向二：對硬規則路徑的探測 PR——本 repo H6 為空，請以 H4 列名檔
#   （如 touch pottery/redlock.py 的 no-op 空白變更）為探測目標——
#   預期：分數上升、triggeredHardRules 含 [H4]、escalated: true
gh workflow run factory-rescore.yml --repo aswf-dev/software_factory \
  -f repo=agent-playground/pottery -f base_branch=software-factory -f pr_number=<探測PR>
```

## 6. 與 Issue #31 驗收條件（DoD）的對應

| DoD | 狀態 | 說明 |
|---|---|---|
| 有可驗證的測試/驗證方式 | ✅ | §5 的 `factory-rescore` 雙向探測即明確驗證命令（含預期輸出）。 |
| 不觸碰高風險路徑（H1–H3 等硬規則） | ✅ | diff 僅含 `proposals/onboarding/` 三檔；未碰 `catalog-info.yaml`、`.github/**`、`pottery/**`（guardrail 本體由人類搬檔才生效）。 |
| 跑測試確認綠燈（不跑需外部服務的 E2E） | ➖ 未執行 | 本 PR 零程式碼變更，既有測試不受影響；且 pottery 全量 pytest 需 Redis 服務（conftest.py:44-47），超出「不跑需外部服務」範圍，老實標 skipped 而非綠燈。工廠原生 CI 亦只觸發 `master`（見 §1），實際綠燈由工廠 crosscheck 保證。 |
