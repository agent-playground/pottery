# pottery 納管提案（Issue #4 · agent-onboard · 變體 a）

> 給審核者的一頁說明。本目錄是**提案**，不是任何機制的讀取路徑：合併後需
> 人類親手搬檔（見下方「搬檔指令」）才生效（docs/27 §2、§7.3）。本 run 為
> 唯讀分析，未改動 repo 任何既有檔案。

## 1. 掃描摘要（2026-11-01，分支 software-factory @ 2d7c70a）

| 面向 | 實際發現 |
|---|---|
| 是什麼 | **Pottery — Redis for Humans**：Pythonic Redis 存取函式庫（README.md:1-8），核心賣點為分布式鎖 Redlock（README 目錄「Redlock 🔒」）、單調 ID `NextID`，以及 Redis 支撐的 `RedisDict/Set/List/Counter/Deque/BloomFilter/HyperLogLog/CachedOrderedDict`。本 repo 為上游 brainix/pottery 的 playground fork（setup.py:34-36 `version='3.0.1'`、`url=https://github.com/brainix/pottery`）。 |
| 語言／建置 | Python（無 pyproject.toml／poetry／uv）。打包 = setuptools `setup.py`；依賴 = pip：`requirements.txt`（全鎖定矩陣）、`requirements-to-freeze.txt`（直接依賴清單：redis、hiredis、mmh3、pytest 系、uvloop、mypy 等）。 |
| 測試 | **pytest**（`pytest.ini`: `asyncio_mode = auto`）；`tests/` 18 檔，session fixture 連 `redis://localhost:6379`（tests/conftest.py:45-52）；**README.md 也是可執行契約**（tests/test_doctests.py:63-67 對 README 跑 doctest）。靜態檢查：mypy（`mypy.ini`、py.typed）、flake8、isort、**bandit**（`.bandit.yaml`）。 |
| CI | `.github/workflows/python-package.yml`：Python 3.11–3.15 × 5、**redis service container**、pytest+cov → mypy → flake8/isort → bandit。⚠️ 觸發分支僅 `master`（該檔 6-10 行）——對 `software-factory` 的 PR 不會跑它，工廠側以 rescore/crosscheck 把關。 |
| 目錄結構 | 扁平兩層：`pottery/`（20 模組）+ `tests/`（18 檔），合計 ~8.7k 行。**無** `src/`、`migrations/`、`docs/`、`api/`、openapi/proto、Dockerfile、k8s（find/ls 零命中）。 |
| 高風險面 | **無**認證授權／金流／PII／加密程式路徑：`pottery/` grep `password|secret|token|credential|auth` 零命中；`pottery/`+`tests/` 無 `cryptography|hashlib` import（requirements.txt 的 `cryptography==50.0.2` 僅為鎖定傳遞依賴；bloom.py 用的 `mmh3` 是非密碼學雜湊）。有的是**併發正確性原語**：Redis Lua 鎖腳本（redlock.py:77-102）、多 master quorum 表決（redlock.py:480-495、aioredlock.py:407-424、540）、Lua CAS 單調 ID（nextid.py:77-88）、quorum 提前返回的 BailOutExecutor（executor.py:31）、全域 json.dumps monkey patch（monkey.py:33-58）。 |
| 服務／協調 | 單一 artefact（一個 PyPI 套件）。多 Redis master quorum 屬**套件內**協調，無跨服務拓撲。 |

## 2. 三軸建議（值由人類裁定；提案中註解值一律 `TODO`）

| 軸 | 建議值 | 一句話理由（完整證據見 catalog-info.yaml 逐軸註解） |
|---|---|---|
| `factory.io/business-criticality` | **tactical** | 開發者面向開源函式庫，掃描無本組織生產依賴證據；若人類知有依賴此 fork 鎖/ID 的生產服務 → 升 operational。 |
| `factory.io/risk-profile` | **medium** | 不低：鎖/單調 ID 是靜默失敗型併發原語，bug 的後果是兩進程同持鎖/ID 重複，無聲擴散給所有用客；不高：H1–H3 四類路徑全無，且有 doctest/bandit/mypy 防護網。與 factory-scoreboard 同級（docs/16 §5.1）。 |
| `factory.io/complexity` | **medium** | 不低：sync/async 雙實作（redlock↔aioredlock、nextid↔aionextid）、3.11–3.15 五版本矩阵、base.py 被 11 模組依賴；不高：單 artefact、無跨服務拓撲、無 schema/API 定義面。 |

預期基準分：建議值全數採納 = 0+1+1 = **2 → review**（score.ts:95-98：≤1 on-loop、≤4 review）；若 complexity 判 low → 1 → on-loop。`agent-automerge` 依新納管硬規則先 `false`，於人類對其變更紀錄建立實績前不開放。

> ⚠️ 搬檔前把三個 `TODO` 換成合法值（tactical|operational|strategic / low|medium|high）。
> **值缺席或非法一律 fail-safe 計 2、無錯誤訊息**（docs/27 §7.2；幽靈值 `supporting`
> 實案：預期 total 1 實測 3）。合法值以 `src/scoring/types.ts` 為準。

## 3. risk-paths.yml 重點

- H1、H2、H3、H6：**留空 + 待人類確認註解**——掃描零命中對應結構（證據逐條寫在檔內註解），不複製範本湊數。
- H4：列名 7 個「失敗會靜默擴散」的核心檔（base/monkey/redlock/aioredlock/nextid/aionextid/executor）。刻意**不**用 `pottery/**`——全覆蓋等於每個實質 PR 都命中，硬規則退化為常態審查、訓練人略過警訊（docs/16 §5.3）。
- H5：無條件寫入四條自我保護路徑。
- H7：Python 函式庫的公開 API 面 = 匯出宣告檔 `pottery/__init__.py`（:22-55）；README（doctest 契約）暫不納入，取捨見檔內註解。
- 全部 glob 已用機制同款比對（`minimatch(p, glob, {dot:true})`，score.ts:85）對 `git ls-files` 實跑驗證：H4 恰命中 7 檔、H5 命中既有 4 個 `.github/` 檔、H7 僅命中 `pottery/__init__.py`、H1/H2/H3/H6 命中 0——**無誤報、無臆測路徑**。

## 4. 搬檔指令（人類審核後，在目標 repo 的 software-factory 分支執行）

```bash
git mv proposals/onboarding/catalog-info.yaml .
mkdir -p .github/factory
git mv proposals/onboarding/risk-paths.yml .github/factory/risk-paths.yml
git rm -r proposals/onboarding
```

搬檔前：① 把 catalog-info.yaml 三個 `TODO` 換成裁定值（見上 ⚠️）；② 若採納「知有生產依賴」之類的新事實，依 §2 調整軸值；③ 合併進 `software-factory`（不是 main）。

## 5. 合併後的驗證步驟（docs/16 §5.2／docs/27 §8 雙向探測——必做）

僅有設定檔不代表工廠讀得到。**兩個方向都要驗**——只驗一般檔案無法區分「硬規則正確」與「硬規則根本沒載入」。開一個 `factory/*` 前綴探測 PR，以機制 repo 的 `factory-rescore.yml` 對該 PR 重計分：

```bash
gh workflow run factory-rescore.yml --repo aswf-dev/software_factory \
  -f repo=agent-playground/pottery -f base_branch=software-factory -f pr_number=<PR>
```

本 repo 的兩條探測（本 repo H6 為空，命中方向改用 H4 路徑）：

| 探測內容 | 預期結果 |
|---|---|
| 探測 A：PR 只改一般檔案（如 `pottery/dict.py`——不在任何 glob 下） | `triggeredHardRules: []`、`escalated: false`、分數＝三軸基準分 |
| 探測 B：PR 觸碰 `pottery/redlock.py` | 分數上升、`triggeredHardRules` 含 `H4`、`escalated: true` |

兩個方向都如預期才算納管完成；之後把 pottery 補進機制 repo `docs/16` §5 已納管清單。

## 6. 誠實邊界

- 本 run 未執行 pytest：全套測試需外部 Redis 服務（conftest 連 localhost:6379），DoD 亦明文排除需外部服務之 E2E；本 PR 為純文件提案、零程式碼變更（crosscheck `--onboard-only` 範圍：僅 `proposals/onboarding/**`）。
- 三軸僅為建議與證據，裁定權在人類；`stack=python`、`test-framework=pytest` 為掃描事實非風險裁定。
