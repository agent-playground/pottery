# 納管提案：agent-playground/pottery

> **狀態：提案，尚未生效。** 本 PR 只新增 `proposals/onboarding/` 下的三個檔案；
> 沒有修改正位的 `catalog-info.yaml` 或 `.github/factory/risk-paths.yml`。
> 三軸在 YAML 中一律是 `TODO`，由人類審核後裁定並填入（docs/27 §7）。
>
> 掃描基準：`agent-playground/pottery` @ `1cf5eaa`（`software-factory`），
> 2026-11-07。以下每個結論都附實際檔案與行號；沒有量到的東西不寫成事實。

---

## 1. 掃描摘要

### 1.1 語言、建置、測試

| 項目 | 實際狀況 | 證據 |
| --- | --- | --- |
| 語言 | Python（`>=3.10, <4`；classifier 列 3.11–3.15） | `setup.py:61-71` |
| 建置 | setuptools `setup.py`；沒有 `pyproject.toml`／poetry／uv | `setup.py:48-74`；根目錄檔案清單 |
| 依賴 | pip；`requirements-to-freeze.txt` 為源頭、`requirements.txt` 為 freeze 結果 | `setup.py:72`、兩份 requirements 檔 |
| 測試 | pytest + pytest-asyncio + pytest-cov | `pytest.ini`（`asyncio_mode = auto`）、`requirements.txt` |
| 靜態檢查 | mypy、flake8、isort、bandit | `.github/workflows/python-package.yml:42-50`、`Makefile:73-85` |
| CI | 5 個 Python 版本矩陣（3.11–3.15）＋ Redis service（`localhost:6379`） | `python-package.yml:17-27`、`:41` |

### 1.2 目錄結構（只列實際存在的）

```
pottery/            19 個 .py + py.typed，4,790 行
  redlock.py        同步分散式鎖 + synchronize()（Lua 腳本 + 多 master quorum）
  aioredlock.py     非同步分散式鎖（另一份獨立實作）
  nextid.py         同步單調遞增 ID（Lua CAS）
  aionextid.py      非同步單調遞增 ID
  base.py           Container / Primitive / AIOPrimitive 共用基礎層
  monkey.py         PotteryEncoder，monkey patch json.dumps
  executor.py       BailOutExecutor（quorum 提前返回）
  dict.py / list.py / set.py / counter.py / deque.py / bloom.py / hyper.py
  cache.py / timer.py / exceptions.py / annotations.py / __init__.py
tests/              19 個 test_*.py + conftest.py + __init__.py，4,489 行
docs/               architecture/、research/、business-rules.md
.github/            workflows/python-package.yml、ISSUE_TEMPLATE/、
                    copilot-instructions.md、factory/risk-paths.yml
```

**不存在的東西（掃描零命中）**：`src/`、`auth/`、`payment/`、`migrations/`、
`alembic/`、`api/`、`*.proto`、`openapi*`、schema 檔、Dockerfile、服務行程。
本 repo 是**單一 Python 套件**，沒有跨服務部署拓撲。

### 1.3 關鍵發現

- **這是一個開發者面向的 PyPI 函式庫，不是第一方業務服務。** `setup.py:34`
  版本 3.0.1、`:36` 上游 URL 指向 `brainix/pottery`；CI 只有測試 job，沒有
  publish／deploy job（`python-package.yml:29-50`）。
- **核心風險是併發正確性，不是認證或金流。** `redlock.py:107-148` 用 Lua
  比對持有者 token 後才 PTTL/PEXPIRE/DEL；`redlock.py:318-353` 以
  `num_masters_acquired > len(self.masters) // 2` 判定 quorum，並以
  `auto_release_time - drift - elapsed` 檢查剩餘有效性；`redlock.py:480-498`
  的 `locked()` 以 `min(ttls)` 與多數決計算；`nextid.py:82-97` 以 Lua CAS
  保證 ID 不重複。`aioredlock.py`／`aionextid.py` 是獨立的 async 雙實作。
  這些 bug 不必然拋錯，後果可能是兩個 worker 同時持鎖或重複發號。
- **沒有 high 級的四類路徑。** 對 `pottery/`、`tests/`、`setup.py` 搜尋
  `password|secret|credential|authenticat|authoriz|auth|api_key|private_key`
  零命中；沒有 payment/billing/invoice；沒有 cryptography/hashlib/hmac/ssl/
  jwt import。`requirements.txt` 的 `cryptography==50.0.2` 是 freeze 的傳遞
  依賴，不在 `requirements-to-freeze.txt`，程式碼也沒有 import 它。
- **有完整防護網。** 19 個 `test_*.py`、README doctest（`tests/test_doctests.py`）、
  CI 的 Redis service、mypy/flake8/isort/bandit。
- **⚠️ 本 repo 已經有正位 guardrail 檔案。** 根目錄 `catalog-info.yaml` 與
  `.github/factory/risk-paths.yml` 已存在（內容看起來是前次納管的提案被搬檔）。
  本 PR **不覆寫**它們；人類審核時請先 diff，決定是沿用、合併或取代，不要
  未經裁定直接覆蓋已生效的三軸。

---

## 2. 三軸建議（人類裁定）

> YAML 內三個值仍是 `TODO`。搬檔前必須換成合法值，否則 fail-safe 一律計為 2。
> 合法值：business-criticality = `tactical|operational|strategic`；
> risk-profile = `low|medium|high`；complexity = `low|medium|high`
> （單一真相來源：`src/scoring/types.ts`）。

| 軸 | 建議值 | 分數 | 一句話理由 |
| --- | --- | --- | --- |
| business-criticality | `tactical` | 0 | 開源開發者函式庫，沒有第一方生產服務依賴的證據 |
| risk-profile | `medium` | 1 | 併發正確性會靜默失敗，但無 authn/authz、金流、PII、加密 |
| complexity | `medium` | 1 | sync/async 雙實作＋5 版本矩陣＋真實 Redis 測試；但仍是單一套件 |

以建議值計，基準分 **0+1+1 = 2 → review**（docs/06 §3）。

### 2.1 business-criticality = tactical (0)

**為什麼不是 operational**：這是 PyPI 上的開發者函式庫，不是組織的第一方業務
系統。`setup.py:34` 是套件版本 3.0.1、`:36` 上游 URL 指向 `brainix/pottery`；
repo 內沒有發佈／部署步驟——唯一的 CI 工作 `python-package.yml` 只有一個
build job（測試、mypy、flake8/isort、bandit，`:29-50`），沒有 publish 或
deploy job，也沒有消費端設定。它的故障影響的是 `pip install pottery` 的用客，
而不是本組織直接的業務流程。`README.md:8` 的「battle tested in production at
scale」是上游 brainix/pottery 的自我宣稱，不是本 fork 的部署事實。

**為什麼不是 strategic**：沒有金流、計費、營收或客戶合約路徑（H2 零命中）。

**反轉條件**：若人類知道本 fork 已被組織內生產服務依賴（例如以 Redlock 做
跨服務協調、以 NextID 發號），就應升級為 `operational`——這個資訊不在 repo
內，屬人類判斷。

### 2.2 risk-profile = medium (1)

**為什麼不是 low**：核心是「靜默失敗」型的併發正確性程式碼。`redlock.py:107-148`
的 Lua 腳本在 token 比對後才 PTTL/PEXPIRE/DEL；`redlock.py:318-353` 以多數決
判定取得鎖並檢查剩餘有效性；`redlock.py:480-498` 的 `locked()` 以 `min(ttls)`
與多數決計算；`nextid.py:82-97` 以 Lua CAS 保證 ID 單調遞增。`aioredlock.py:242-272`、
`:490-516`、`:520-540` 與 `aionextid.py:75-81` 是 async 版的重複實作。這些
邏輯出錯不一定拋錯，後果是兩個進程同時持鎖或同一 key 發出重複 ID，直接破壞
下游用客的資料一致性。

**為什麼不是 high**：沒有認證／授權、沒有金流計算、沒有 PII／憑證／加密金鑰
處理（H1–H3 掃描零命中，見 `risk-paths.yml`）；沒有 DB schema 遷移（H6 空）。
`pottery/monkey.py:33-55` 會 monkey patch `json.dumps`，是共用序列化層，但它
處理容器內容，不是憑證。H4／H5／H7 是**路徑級**的升級規則：一旦改到
`redlock.py`、`__init__.py` 等檔案，risk 會被強制為 2；這不需要把整個 repo
的基準 profile 預先評為 high。repo 也有 19 個測試檔、CI 的 Redis service 與
bandit 作為防護網。

**對照**：與 factory-scoreboard 同為 `medium`（docs/16 §5.1）——scoreboard 的
風險來自應用層認證，pottery 的風險來自併發正確性，皆非 high 級四類路徑。

### 2.3 complexity = medium (1)

**為什麼不是 low**：
- sync/async 成對雙實作（`redlock.py` ↔ `aioredlock.py`、`nextid.py` ↔
  `aionextid.py`），改一邊必須同步另一邊；
- `pottery/base.py:278-337` 是共用基礎層，10 個模組在模組層 `from .base import ...`
  （`aionextid`、`aioredlock`、`bloom`、`cache`、`dict`、`hyper`、`list`、
  `nextid`、`redlock`、`set`），另 `monkey.py:37` 在函式內 import；
- CI 跑 5 個 Python 版本矩陣（`python-package.yml:17`，3.11–3.15），且測試
  需要真實 Redis service（`:18-27`；`tests/conftest.py:47` 連
  `redis://localhost:6379`）；
- 併發與 Lua 腳本使閱讀與測試成本高於一般資料結構函式庫。

**為什麼不是 high**：單一 artefact（一個 PyPI 套件），目錄扁平（只有
`pottery/` 與 `tests/` 兩層；19 個模組、4,790 行＋4,489 行測試）；沒有跨服務
拓撲——多 master quorum 是函式庫內部的協調（`executor.py:26-51` 的
`BailOutExecutor`），不是分散在多個 repo／服務的運算排布；沒有 API 定義檔、
沒有 migrations、沒有 DB schema。

---

## 3. 硬規則草案（`risk-paths.yml`）

- **H1 / H2 / H3 / H6：空陣列。** 掃描未發現對應結構，待人類確認；註解已寫
  出證據與「未來若引入應如何補」的建議。
- **H4：列名 7 個實際存在的共用／核心檔案**（`base.py`、`monkey.py`、
  `redlock.py`、`aioredlock.py`、`nextid.py`、`aionextid.py`、`executor.py`）。
  沒有用 `pottery/**` 或 `**/*lock*`，避免每次改資料結構或測試都誤觸
  （docs/16 §5.3 的誤報教訓）。
- **H5：無條件寫入四條**（`.github/**`、`CODEOWNERS`、`catalog-info.yaml`、
  `.dsh/skills/**`）；`CODEOWNERS` 與 `.dsh/skills/` 目前不存在，註解已標明。
- **H6：空陣列。** 沒有 migrations／schema；雙向探測請改用 H4 的
  `pottery/redlock.py` 作為「命中硬規則」方向，不要虛構 migrations/。
- **H7：`pottery/__init__.py`。** 它是 `__all__` 的匯出宣告檔
  （`__init__.py:58-90`，28 個公開名稱）；不把 `README.md` 納入，避免錯字
  修正也觸發人類審查。

---

## 4. 審核後搬檔（人類執行）

**先做**：把 `proposals/onboarding/catalog-info.yaml` 的三個 `TODO` 換成人類
裁定的合法值。**不要**把 `TODO` 搬進正位——它會被 fail-safe 計為 2。

```bash
git mv proposals/onboarding/catalog-info.yaml .
mkdir -p .github/factory
git mv proposals/onboarding/risk-paths.yml .github/factory/risk-paths.yml
git rm -r proposals/onboarding
```

> **⚠️ 本 repo 的正位檔案已存在**（`catalog-info.yaml` 與
> `.github/factory/risk-paths.yml`，見 §1.3）。上面的 `git mv` 在目標已存在時
> 會拒絕覆寫。請先比對，再決定：
>
> ```bash
> git diff --no-index catalog-info.yaml proposals/onboarding/catalog-info.yaml || true
> git diff --no-index .github/factory/risk-paths.yml proposals/onboarding/risk-paths.yml || true
> ```
>
> 若確認要以本提案取代，才用 `git mv -f`；若要保留既有內容，請手動合併三軸
> 與規則，**不要**未經裁定直接覆蓋已生效的 guardrail。

合併進 `software-factory`（不是 `main`）。

---

## 5. 合併後驗證（docs/16 §5.2 雙向探測）

設定檔在 `proposals/` 時工廠讀不到它，所以「寫對了」與「讀得到」在合併前
無法區分。開一個 `factory/*` 探測 PR，**兩個方向都要驗**：

```bash
gh workflow run factory-rescore.yml --repo aswf-dev/software_factory \
  -f repo=agent-playground/pottery -f base_branch=software-factory -f pr_number=<PR>
```

| 方向 | 探測 PR 改什麼 | 預期（以建議值 tactical/medium/medium 為例） |
| --- | --- | --- |
| 對照組（一般檔案） | `docs/architecture/overview.md` 之類的非硬規則檔 | `total: 2`、`triggeredHardRules: []`、`escalated: false`、tier `review` |
| 實驗組（命中硬規則） | `pottery/redlock.py`（H4） | `total: 3`、`triggeredHardRules: ["H4"]`、tier `review` |

**判讀重點**：
- 對照組證明三軸有被讀到（total 2，不是 fail-safe 的 6）。
- 實驗組證明 `risk-paths.yml` **真的被載入**：`triggeredHardRules` 必須出現
  `H4`，total 必須由 2 上升到 3。
- `escalated` 的語意是「監督層級是否上升」（`src/cli/factory-rescore.ts:79-84`），
  不是「分數是否上升」。以建議值計，基準已是 `review`，H4 讓 total 從 2 到 3
  但 tier 仍是 `review`，所以 `escalated` 可能是 `false`——這不代表硬規則沒
  載入；**`triggeredHardRules` 與 total 才是判準**。若人類把基準三軸判成
  on-loop（total ≤1），同一個 H4 探測就會同時得到 `escalated: true`。
- 若對照組的 total 是 6（三個軸都 fail-safe 2），代表 annotation 值不合法或
  搬檔沒成功；若實驗組沒有 `H4`，代表 `risk-paths.yml` 沒被載入或 glob 寫錯。

---

## 6. 審核清單

- [ ] 三個 `TODO` 已換成合法值（`tactical|operational|strategic`、
      `low|medium|high`、`low|medium|high`），沒有幽靈值。
- [ ] `risk-paths.yml` 的 H5 四條完整；H1–H4、H6–H7 的空陣列都有「掃描未發現，
      待人類確認」的註解。
- [ ] H4 的每一條 glob 都對應實際存在的檔案；沒有 `pottery/**` 這種會淹沒
      警訊的寬樣式。
- [ ] `catalog-info.yaml` 的 `spec.type` 是 `library`（不是範本的 `service`），
      `owner` 符合組織歸屬。
- [ ] 搬檔後跑過 §5 的雙向探測，並把 `triggeredHardRules` 的實際輸出貼回 Issue。
- [ ] 沒有把任何憑證、token、連線字串寫進提案或 PR 描述。
