# pottery 納管提案（Issue #31 · agent-onboard · variant b）

> 給審核者的一頁說明。本目錄是**提案**，不是任何機制的讀取路徑：合併後仍需
> 人類親手搬檔（見 §5）才生效（docs/27 §2、§7.3）。本 run 是唯讀分析——
> 除 `proposals/onboarding/` 的三個提案檔外，沒有改動任何既有檔案。
>
> 掃描基準：`software-factory` @ `748bc61`（目標 repo
> `agent-playground/pottery`），日期 2026-11-01。

## 1. 掃描摘要

| 面向 | 實際發現 |
|---|---|
| 是什麼 | **Pottery — Redis for Humans**：Pythonic Redis 存取函式庫（README.md:1-8）。核心是 Redis 支撐的容器（`RedisDict`／`RedisSet`／`RedisList`／`RedisCounter`／`RedisDeque`／`BloomFilter`／`HyperLogLog`／`CachedOrderedDict`）與分散式協調 primitive（`Redlock`／`AIORedlock`／`NextID`／`AIONextID`／`synchronize`）。本 repo 是上游 `brainix/pottery` 的 playground fork（setup.py:33-36，`__version__='3.0.1'`、`__url__='https://github.com/brainix/pottery'`）。 |
| 語言／建置 | Python。無 `pyproject.toml`／poetry／uv；打包用 setuptools `setup.py`，依賴用 pip：`requirements.txt`（全鎖定）＋ `requirements-to-freeze.txt`（直接依賴源頭）。`python_requires='>=3.10, <4'`（setup.py:71）。 |
| 目錄結構 | 扁平：`pottery/`（19 個 `.py` + `py.typed`，4,790 行）、`tests/`（19 個 `test_*.py` + `conftest.py` + `__init__.py`，4,489 行）、`docs/`（architecture、business-rules、research）。**無** `src/`、`migrations/`、`auth/`、`payment/`、`api/`、`openapi*`、`*.proto`、`*.sql`、`schema*`、Dockerfile／k8s（find 全數零命中）。 |
| 測試 | **pytest**（`pytest.ini:20-21`，`asyncio_mode = auto` 即 pytest-asyncio）。fixture 連 `redis://localhost:6379/<隨機 db>`（tests/conftest.py:44-52）。README 也是可執行契約：tests/test_doctests.py:61-68 對 `README.md` 跑 doctest。靜態檢查：mypy（mypy.ini、py.typed）、flake8、isort、bandit（`.bandit.yaml`）。 |
| CI | `.github/workflows/python-package.yml`：Python 3.11–3.15 共 5 版 × redis service container，依序跑 pytest+cov → mypy → flake8/isort → bandit。⚠️ **觸發分支只有 `master`**（該檔 :6-10）——對 `software-factory` 的 PR 不會跑這支 workflow。 |
| 高風險面 | **無**認證授權／金流／PII／加密程式路徑。有的是**併發正確性**：Redis Lua 鎖腳本（redlock.py:113-148）、多 master quorum（redlock.py:318-350、:474-495；aioredlock.py:213、:262、:422-423、:540）、Lua 條件式單調 ID（nextid.py:88-99、:220；aionextid.py:76）、quorum 提前返回的 `BailOutExecutor`（executor.py:26）、全域 `json.dumps` monkey patch（monkey.py:33-55）。 |
| 服務／協調 | 單一 artefact（一個 PyPI 套件），`entry_points={}`（setup.py:77），沒有常駐服務或 CLI。多 Redis master 的 quorum 是**套件內**對多條連線的協調，不是跨 repo／跨服務的部署拓撲。 |

## 2. 三軸建議（值由人類裁定；提案檔內一律 `TODO`）

| 軸 | 建議值 | 為什麼不是更高 | 為什麼不是更低 |
|---|---|---|---|
| `factory.io/business-criticality` | **tactical (0)** | 不是 operational：repo 內沒有任何內部消費者設定或部署事實；README 的「battle tested in production」是上游自稱。若人類知道本 fork 的鎖／ID 已被生產服務使用，請升 operational。不是 strategic：無金流、無對外服務、無 PII。 | 已是合法值的最低級（0）。 |
| `factory.io/risk-profile` | **medium (1)** | 不是 high：H1（認證授權）、H2（金流）、H3（敏感資料）掃描零命中；無加密 import、無憑證檔、無 schema 遷移。 | 不是 low：鎖與單調 ID 是「錯了不會拋錯」的併發原語；bug 的後果是兩個行程同時持鎖或 ID 重複，靜默擴散給所有用客。 |
| `factory.io/complexity` | **medium (1)** | 不是 high：單一 artefact、扁平兩層、無跨服務拓撲、無 API／schema 定義面。 | 不是 low：sync／async 成對雙實作（redlock↔aioredlock、nextid↔aionextid）、`base.py` 被 11 個模組 import、CI 跑 5 個 Python 版本且需 Redis 服務。 |

**預期基準分**：0 + 1 + 1 = **2 → `review`**（src/scoring/score.ts:95-98：total ≤1 → on-loop、≤4 → review）。若人類把 complexity 判為 low，基準分 2→1 會落到 on-loop；若 risk 判 high，則 0+2+1=3 → review。`agent-automerge` 依新納管預設填 `"false"`，且本 repo 的 CI 目前不會在 `software-factory` 上跑，更不宜先開放。

> 注意：`risk-profile` 的 medium 是**基準值**。H4 的 7 條共享模組路徑是
> **變更層級**的升級規則——只有實際改動 `base.py`／`redlock.py` 等檔案時，
> 該次變更才被強制 risk=2；一般容器、測試、文件變更仍走基準分。若把整個
> repo 的基準設為 high，所有變更都會需要最高監督，反而稀釋真正高風險改動
> 的警訊（與 docs/16 §5.3 同一原則）。

> ⚠️ 搬檔前把三個 `TODO` 換成合法值（`tactical|operational|strategic` / `low|medium|high`）。
> **值缺席或非法一律 fail-safe 計 2、無任何錯誤訊息**（docs/27 §7.2；幽靈值
> `supporting` 實案：預期 total 1，實測 total 3）。合法值以機制 repo 的
> `src/scoring/types.ts` 為準。

## 3. 審核時請特別看的四件事

1. **本 repo 其實已經納管。** 根目錄已有 `catalog-info.yaml`（2026-11-01 人類裁定
   tactical / medium / medium）與 `.github/factory/risk-paths.yml`。本提案是獨立
   重掃的建議草稿，**不是**要覆蓋既有裁定；若無意重新納管，請以 diff 比對即可，
   不要直接搬檔（見 §5 的注意事項）。
2. **CI 觸發分支與工廠 trunk 不一致。** `.github/workflows/python-package.yml:6-10`
   只監聽 `master`，但工廠 PR 的 base 是 `software-factory`。因此**工廠 PR 不會
   自動跑 pytest/mypy/bandit**；本 repo 的測試防護網在工廠流程中實際上是空的。
   這必須**由人類**修正 `on:` 的 `branches`：`.github/**` 屬 H5 護欄，bot 沒有
   `workflows` 權限，派工只會停手（docs/27 §14；docs/05 §1.1）。
3. **版本宣告與測試矩陣有落差。** `setup.py:71` 宣告支援 Python 3.10，但 CI
   矩陣只測 3.11–3.15（python-package.yml:17）；3.10 使用者沒有測試覆蓋。
4. **Issue #31 的 PRD 寫「斷線演練：納管提案（不需交付，用於驗證排程補漏）」。**
   本 PR 是派工指示要求的提案草稿，供人類比對與驗證排程；在人類裁定前不建議
   搬檔，也不影響既有的納管設定。

## 4. risk-paths.yml 重點（全部 glob 已對 `git ls-files` 實跑）

- **H1／H2／H3／H6：留空＋「掃描未發現，待人類確認」註解。** 證據逐條寫在檔內：
  authn/authz、金流、加密／PII、migrations／schema 皆零命中；`requirements.txt`
  的 `cryptography`／`PyJWT` 是傳遞依賴，`mmh3` 是非密碼學雜湊。
- **H4：精確列名 7 個核心檔**（base、monkey、executor、redlock、aioredlock、
  nextid、aionextid）。刻意**不**用 `pottery/**`（每個實質 PR 都命中，等於常態
  審查），也不用 `**/*lock*`（會連測試檔一起命中）。實測恰好命中這 7 檔。
- **H5：無條件四條**（`.github/**`、`CODEOWNERS`、`catalog-info.yaml`、
  `.dsh/skills/**`）。實測命中既有 5 個 `.github/` 檔＋根目錄 `catalog-info.yaml`。
- **H7：兩個公開 API 代理**——`pottery/__init__.py`（`__all__` 28 個名稱，
  :58-90）與 `pottery/exceptions.py`（例外階層，經 :61-72 匯出、被下游 catch）。
  實測各命中 1 檔。README（doctest 契約）刻意不納入，取捨寫在檔內。
- 驗證方式：以機制同款 `minimatch(path, glob, {dot:true})`（src/scoring/score.ts:85）
  對 `git ls-files` 實跑——H4 恰 7 檔、H5 恰 6 檔、H7 恰 2 檔、H1/H2/H3/H6 皆 0，
  **無誤報、無臆測路徑**。

## 5. 搬檔指令（人類審核後，在目標 repo 的 `software-factory` 分支執行）

```bash
git mv proposals/onboarding/catalog-info.yaml .
mkdir -p .github/factory
git mv proposals/onboarding/risk-paths.yml .github/factory/risk-paths.yml
git rm -r proposals/onboarding
```

搬檔前：① 把 `catalog-info.yaml` 的三個 `TODO` 換成裁定值（見 §2 ⚠️）；
② 若採納「已知有生產依賴」之類的新事實，依 §2 調整軸值；③ 合併進
`software-factory`（不是 main）。

> **注意（本 repo 特有）：** 根目錄的 `catalog-info.yaml` 與
> `.github/factory/risk-paths.yml` 已經存在（2026-11-01 納管）。上面的 `git mv`
> 會因目的地存在而失敗。若人類決定用本提案**取代**既有設定，請先 `git diff`
> 確認差異，再改用 `git mv -f ...`；若只是**比對**，不要搬檔，直接關閉本 PR。

## 6. 合併後的驗證步驟（docs/16 §5.2／docs/27 §8 雙向探測——必做）

設定檔在 `proposals/` 時工廠讀不到它，所以「設定寫對了」與「工廠讀得到」在
合併前無法區分。**兩個方向都要驗**——只驗一般檔案無法區分「硬規則正確」與
「硬規則根本沒載入」。開一個 `factory/*` 前綴的探測 PR，用機制 repo 的
`factory-rescore.yml` 對它重計分：

```bash
gh workflow run factory-rescore.yml --repo aswf-dev/software_factory \
  -f repo=agent-playground/pottery -f base_branch=software-factory -f pr_number=<PR>
```

| 探測 | PR 改動 | 預期結果 |
|---|---|---|
| A（一般檔案） | 例如 `pottery/dict.py`——不在任何 hard-rule glob 下 | `triggeredHardRules: []`、`escalated: false`、total＝三軸基準分 2 |
| B（硬規則） | 例如 `pottery/redlock.py`（H4）或 `pottery/exceptions.py`（H7） | `triggeredHardRules` 含 `H4`（或 `H7`）、`escalated: true`、risk 被強制為 2、total＝3 |

兩個方向都如預期才算納管完成；之後把 pottery 補進機制 repo `docs/16` §5 的
已納管清單。

## 7. 本 run 的驗證與誠實邊界

- **測試**：在本 sandbox（Python 3.14.4）以 `redis:7-alpine` 起本地 Redis，
  執行完整 `pytest -q` → **353 passed, 4 skipped**（23.61s）。這是完整單元／
  doctest 套件，不是只跑子集。4 個 skip **不是環境問題**，而是既有缺陷的
  保留斷言：`tests/test_nextid_business_rules.py:101,113,125`（NextID 未實作
  `initial_value`／`chunk_size`，R7，issue #18）與 `tests/test_redlock.py:359`
  （偶數 master 的 quorum 判定，F1，見 `docs/research/9-s5-a1-a4-inventory.md`
  §2.5.1）。它們不是本 PR 造成，但審核者應知道這個 repo 有 4 個已標記的
  已知缺陷。CI 矩陣的 3.11–3.15 未逐一重跑。
- **零程式碼變更**：本 PR 只動 `proposals/onboarding/` 三個檔案；crosscheck
  `--onboard-only` 的允許範圍正是 `proposals/onboarding/**` 與 `docs/**`。
- **沒有修改 guardrail**：根目錄 `catalog-info.yaml`、`.github/factory/risk-paths.yml`、
  `.github/**` 均未觸碰（docs/05 §1.1 核心不變量）。
- **三軸只是建議**：值一律 `TODO`，裁定權在人類；`stack=python`、
  `test-framework=pytest` 是掃描事實，不是風險裁定。
