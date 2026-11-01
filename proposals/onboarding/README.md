# pottery 納管提案（Issue #34 · agent-onboard · 變體 a）

> 給審核者的一頁說明。本目錄是**提案**、不是任何機制的讀取路徑：合併後需
> 人類親手搬檔（§4）才生效（docs/27 §2、§7.3）。本 run 為唯讀分析，
> 僅改動 `proposals/onboarding/` 下三檔，未觸碰 repo 任何既有檔案
> （根目錄既有的 `catalog-info.yaml` 與 `.github/factory/risk-paths.yml`
> **保持原樣**——它们是前次 S2 的生效件，agent 依 docs/05 §1.1 不得寫入）。
> 掃描基準：2026-11-01，software-factory 分支 HEAD 748bc61。

## 1. 掃描摘要（全部為實測輸出，非臆測）

| 面向 | 實際發現 |
|---|---|
| 是什麼 | **Pottery — Redis for Humans**：Pythonic Redis 存取函式庫（README.md:1-4），核心為分布式鎖 Redlock、單調 ID NextID，與 Redis 支撐的 dict/list/set/counter/deque/bloom/hyper/cache 集合。上游 brainix/pottery 之 playground fork：setup.py:34 `version='3.0.1'`、:36 `url=brainix/pottery`。 |
| 語言／建置 | Python（`python_requires '>=3.10, <4'`，setup.py:71）。無 pyproject/poetry/uv：setuptools `setup.py` + pip。依賴源頭 `requirements-to-freeze.txt`（redis、hiredis、mmh3、uvloop、twine…）→ `requirements.txt` 為 freeze 全鎖定矩陣（Makefile:71 實證生成關係）。 |
| 測試 | **pytest**（pytest.ini:21 `asyncio_mode = auto`）；tests/ **21 檔**（19 個 `test_*.py`、301 個 test 函式、4,489 行）；README.md 是可執行契約（tests/test_doctests.py:63-66 跑 doctest）；需外部 Redis（conftest.py:47 `redis://localhost:6379`）。靜態面：mypy（py.typed）、flake8、isort、bandit（Makefile test target）。 |
| CI | 僅 `.github/workflows/python-package.yml`：Python 3.11–3.15 × ubuntu + redis service container、pytest→mypy→flake8/isort→bandit；**無 publish/deploy job**。⚠️ 該 workflow 只在 `master` 觸發（:6-9）——`software-factory` 的 PR 不跑它，工廠側以 rescore/crosscheck 把關。 |
| 目錄結構 | 扁平兩層：`pottery/` 19 個 .py 模組 + py.typed（4,790 行，redlock.py 773 行、aioredlock.py 563 行為最大檔）+ `tests/`；另有 docs/（architecture、research、business-rules.md——前次 S 流程產物）。**無** src/、migrations/、schema、openapi/proto、api/、auth/、payment/（find/grep 零命中）。 |
| 關鍵發現 | 無認證／金流／PII／加密路徑（宽鬆 'tls' 命中皆 `ttls`＝TTL 集合變數假陽性，已在 risk-paths.yml 記錄防誤判）。真正的風險面是**靜默失敗型併發原語**：三支 Redis Lua 鎖腳本（redlock.py:113/:128/:142）、多 master quorum 表決（redlock.py:480-495；aioredlock.py:407-424/:540）、Lua CAS 單調 ID（nextid.py:82-88；aionextid.py:76）、全域 `json.dumps` monkey patch（monkey.py:55）、BailOutExecutor 提前返回計時（executor.py:26）、base.py 被 10 模組直接匯入。sync/async 雙實作成對存在，易漂移。 |
| 服務／協調 | 單一 artefact（一個 PyPI 套件）；多 master quorum 是**套件內**對外部 Redis 叢集的協調，無跨服務拓撲。 |

## 2. 三軸建議（提案檔內值一律 `TODO`；裁定權在人類）

| 軸 | 建議值 | 一句話理由（完整證據+邊界論證見 catalog-info.yaml 逐軸註解，docs/16 §5.1 格式） |
|---|---|---|
| `factory.io/business-criticality` | **tactical (0)** | 開發者面向開源庫，無本組織生產依賴證據（無 publish/deploy job、無消費端設定）；「production at scale」是上游宣稱。人類如知本 fork 有內部生產依賴 → 升 operational。 |
| `factory.io/risk-profile` | **medium (1)** | 不低：鎖/單調 ID/quorum 表決屬靜默失敗型併發正確性，bug 後果是互斥失效或 ID 重複、無聲擴散所有用客；不高：H1–H3 四類路徑全數零命中，且有 301 test 函式 + doctest + bandit + H4 列名強制人審。 |
| `factory.io/complexity` | **medium (1)** | 不低：sync/async 雙實作 ×2 對、嵌入 Lua 腳本、quorum/BailOut 計時語意、base 扇出 10 模組、5 Python 版本矩阵、~9.3k 行（對照 docs/16 §5.1 low 基準：15 檔/單表/無協調）；不高：單 artefact、扁平兩層、無 API/schema/跨服務面。 |

採納建議值 → 基準分 **0+1+1 = 2 → review**（score.ts:96-98：≤1 on-loop、≤4 review、≥5 in-loop）。命中 H4/H5/H7 任一 glob → risk=2 → 3 分，仍 review。

> ⚠️ 搬檔前把三個 `TODO` 逐一換成 `src/scoring/types.ts` 的合法值
> （tactical|operational|strategic / low|medium|high）。**值缺席或非法一律
> fail-safe 靜默計 2、無錯誤訊息**（docs/27 §7.2 幽靈值 `supporting` 實案）。
> `agent-automerge` 依新納管硬規則維持 `"false"`；`stack=python`、
> `test-framework=pytest` 為掃描事實（非風險裁定），可直接沿用。

## 3. 與現行生效件的關係（請審核者先讀）

根目錄 `catalog-info.yaml`（檔內註明「2026-11-01 人類裁定：tactical/medium/medium，V4 驗收」）與 `.github/factory/risk-paths.yml` **已存在**——本 repo 曾被 S2 納管生效。本提案是 Issue #34 要求的重新產出，三軸建議與前次裁定一致（tactical/medium/medium），risk-paths 亦同形制，但所有行級證據按**當前 trunk** 重新驗證並修正了舊稿的時效性誤差（例：tests/ 已由 18 檔成長為 21 檔——新增 business-rules 測試來自 S8 工作項；executor.py BailOutExecutor 實際在 :26 而非 :31）。Issue 文字中「20 個模組／18 個測試檔」與實測略有出入，以本掃描實測為準。人類可選擇：**沿用現行生效件**（關掉本 PR 或僅存檔），或 **diff 後以本稿覆寫**。

## 4. 搬檔指令（人類審核後，在目標 repo 的 software-factory 分支執行）

```bash
git mv proposals/onboarding/catalog-info.yaml .
mkdir -p .github/factory
git mv proposals/onboarding/risk-paths.yml .github/factory/risk-paths.yml
git rm -r proposals/onboarding
```

因目標檔已存在（§3），覆寫前先比對：
`git diff --no-index proposals/onboarding/catalog-info.yaml catalog-info.yaml`
與 `git diff --no-index proposals/onboarding/risk-paths.yml .github/factory/risk-paths.yml`；
決定覆寫後若 `git mv` 因目標存在而拒動，改用 `git mv -f`。搬檔前先把三個 `TODO` 換成裁定值（§2 ⚠️）。合併目標是 `software-factory`，絕不是 main/master。

## 5. 合併後的驗證步驟（docs/16 §5.2 雙向探測——兩個方向都要驗，必做）

僅有設定檔不代表工廠讀得到：只驗一般檔案**無法區分「硬規則正確」與「硬規則根本沒載入」**。開一個 `factory/*` 前綴探測 PR，對機制 repo 觸發 rescore：

```bash
gh workflow run factory-rescore.yml --repo aswf-dev/software_factory \
  -f repo=agent-playground/pottery -f base_branch=software-factory -f pr_number=<PR>
```

| 探測 | 改什麼 | 預期（採納建議三軸 0/1/1 時） |
|---|---|---|
| A：一般檔案 | 只動未被任何 glob 命中的檔案（如 `pottery/dict.py`） | `total 2`、`triggeredHardRules: []`、`escalated: false`、tier review（基準分） |
| B：硬規則檔案 | 觸碰 `pottery/redlock.py`（H4） | `risk=2 → total 3`、`triggeredHardRules: [H4]`、`escalated: true` |

本 repo H6 為空（無 migrations/），命中方向以 H4 路徑代替（risk-paths.yml 檔內亦已註明）。兩方向結果如預期才算納管驗證完成；隨後把 pottery 條目更新進機制 repo docs/16 §5 一覽表。

## 6. 誠實邊界

- 本 run 未執行 pytest：全套需外部 Redis 服務，且 DoD 明文「不跑需外部服務的 E2E」；本 PR 為純提案、零程式碼/測試變更（crosscheck `--onboard-only` 白名單路徑：僅 `proposals/onboarding/**`）。
- 每條 glob 已用機制同款比對器（minimatch `{dot:true}`）對 `git ls-files` 實跑：H4 恰命中 7 檔、H7 恰 1 檔、H5 命中既有 5+1 檔（含 .github/**）、H1/H2/H3/H6 空陣列零命中——無臆測路徑、無範本殘留。
- 三軸僅為建議+證據；風險裁定、搬檔與探測放行皆屬人類。
