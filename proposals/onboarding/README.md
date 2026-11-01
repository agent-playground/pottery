# Pottery 納管提案（Issue #4 / S2 agent-onboard）

> 本 PR 只新增 `proposals/onboarding/` 下的三個檔案。**沒有**建立或修改正位的
> `catalog-info.yaml` 與 `.github/factory/risk-paths.yml`：這兩者是 guardrail
> 本身，必須由人類審核後親手搬檔（docs/05 §1.1、docs/27 §2、§7）。
>
> 三軸值一律 `TODO`。下面的「建議值」只是提案，**裁定權在人類**；在搬檔前
> 請把 `TODO` 換成合法值。值缺席或非法會 fail-safe 計為 2（最高風險，
> 且沒有錯誤訊息），合法值見 `src/scoring/types.ts` 與 docs/27 §7.2。

- 目標 repo：`agent-playground/pottery`
- 工廠 trunk：`software-factory`（HEAD `2d7c70a`）
- 掃描方式：唯讀；`git ls-files`、`wc -l`、grep、檔案閱讀。未修改任何既有檔案。

---

## 1. 掃描摘要

| 項目 | 實際結果 |
| --- | --- |
| 語言 | Python（`setup.py` 宣告 `python_requires='>=3.10, <4'`；CI matrix 3.11–3.15） |
| 建置工具 | setuptools（`setup.py`；無 `pyproject.toml`、無 tox）；`Makefile` 以 venv + pip 操作 |
| 測試框架 | pytest + pytest-asyncio + pytest-cov（`pytest.ini`：`asyncio_mode = auto`） |
| 套件結構 | 單一 Python 套件 `pottery/`：19 個 `.py`（18 個實作模組 + `__init__.py`），4,790 行 |
| 測試 | `tests/`：17 個 `test_*.py`、72 個 test method；`pytest --collect-only` 共 323 項（含 doctest） |
| 執行期相依 | `redis>=4.2.0rc1`、`mmh3`、`typing_extensions`（`setup.py` 的 `install_requires`） |
| migrations / schema | **無**：`git ls-files` 沒有 `migrations/`、Flyway/Alembic、`schema.sql` |
| API 定義 | **無** OpenAPI/Swagger/`*.proto`；對外 API 是 `pottery/__init__.py` 的 `__all__`（28 個名稱） |
| 部署 / 服務 | **無** Dockerfile、docker-compose、K8s/Helm、deploy/；repo 本身不執行服務 |
| 外部服務 | 只有 Redis（測試與執行期 client 連線；測試預設 `localhost:6379`） |
| CI | `.github/workflows/python-package.yml` 跑 pytest、mypy、flake8/isort、bandit；**只在 push/PR 到 `master` 時觸發** |

### 關鍵發現（含風險掃描）

1. **沒有 H1/H2/H3 對應程式碼。** `grep -rniE 'auth|password|secret|credential|encrypt|decrypt|payment|billing|pii|jwt|oauth' pottery/` 只命中 19 個檔頭版權宣告的 `author`；沒有 authn/authz、金流、PII 或加解密實作。
2. **`requirements.txt` 的 `cryptography` / `PyJWT` 不是產品相依。** 它們是 dev/release 工具鏈（twine/keyring 等）的 transitive deps；`pottery/` 與 `tests/` 都沒有 import。
3. **Redlock 的「token」是鎖的隨機值，不是憑證。** 因此 risk-paths 刻意不寫 `**/*token*`——那會誤中鎖的實作（docs/16 §5.3 的 `tokens.css` 教訓）。
4. **同步／非同步雙實作是複雜度的主要來源。** `redlock.py`（773 行）＋ `aioredlock.py`（563 行）合計 1,336 行，約占 4,790 行的 28%，含 quorum、auto-release、extension 與 clock-drift 補償。
5. **共用抽象集中在 `pottery/base.py`（337 行）。** `_Common`、`_Encodable`、`_Pipelined`、`_Comparable`、`Container`、`Primitive`、`AIOPrimitive` 都在此；所有容器、Redlock、NextID 都繼承它。這是 H4 的主要理由。
6. **CI 分支觸發範圍與工廠 trunk 不一致。** workflow 只監聽 `master`，但工廠 PR 的 base 是 `software-factory`；這個 onboarding PR 不會自動跑 pytest。這是既有設定，agent 不得修改 `.github/**`，留待人類決定是否另開工單。
7. **輕微文件漂移（不阻塞）。** `.github/copilot-instructions.md` 提到 `pottery/queue.py` 與 `make test-readme`，但 `git ls-files pottery` 沒有 `queue.py`，`Makefile` 也沒有 `test-readme` target。

可重現的掃描指令：

```bash
git ls-files | wc -l
git ls-files pottery tests .github
wc -l pottery/*.py
grep -rniE 'auth|password|secret|credential|encrypt|decrypt|payment|billing|pii|jwt|oauth' pottery/
git ls-files | grep -iE 'migrat|schema|openapi|swagger|\.proto$|docker|k8s|helm|deploy'
```

---

## 2. 三軸建議（待人類裁定）

| 軸 | 建議值 | 分數 | 一句話理由 |
| --- | --- | --- | --- |
| `factory.io/business-criticality` | `tactical` | 0 | 通用 Redis 工具庫；沒有服務、客戶資料、營收或部署 |
| `factory.io/risk-profile` | `low` | 0 | 掃描無 auth／金流／PII／加密；核心共用檔另由 H4/H7 動態升級 |
| `factory.io/complexity` | `medium` | 1 | 單一套件但 18 個模組、4,790 行、同步/async 雙實作與 Redlock quorum |

以這組建議值計算，未觸發硬規則的基準分是 **1 → on-loop**。但
`factory.io/agent-automerge: "false"` 會無條件否決自動合併，所以實務上仍需
人類審查。

### 2.1 business-criticality：建議 `tactical` (0)

- **為什麼是 tactical**：這是可被 import 的通用工具庫，不是對外服務或內部業務系統。repo 內沒有服務進入點、部署設定、客戶資料或營運流程；故障不會直接影響外部使用者或營收。`setup.py` 只是 PyPI 打包 manifest（`__version__ = '3.0.1'`），`.github/workflows/python-package.yml` 只有測試／型別檢查／lint／bandit，沒有 deploy 或 publish job。
- **為什麼不是 operational (1)**：沒有「內部業務系統」在運作，也沒有同仁日常作業依賴這個 fork 的服務。
- **為什麼不是 strategic (2)**：沒有面向客戶的介面、沒有金流或營收掛鉤；以 Apache-2.0 開源釋出，不是專有核心智慧財產。
- **保留意見**：若此 fork 日後承接上游 PyPI 發佈，或成為下游生產服務的關鍵依賴，應上調為 operational 或 strategic。

### 2.2 risk-profile：建議 `low` (0)

- **為什麼是 low**：實際掃描未發現 H1（授權/認證）、H2（金流）、H3（PII/憑證/加密）、H6（schema 遷移）、H7（對外 API 定義）的對應程式碼。一般功能變更落在有 72 個 test method 覆蓋的 leaf module；核心共用檔的風險由 risk-paths 的 H4/H7 動態升級，不需要把整個 repo 的 baseline 拉高。
- **為什麼不是 medium (1)**：不像 factory-scoreboard 那樣持有 ingest 認證或 `SCOREBOARD_TOKEN`；這裡沒有需要人工守護的敏感邏輯。
- **為什麼不是 high (2)**：H1–H3、H6–H7 掃描皆無對應結構；H4 只在 `pottery/base.py` 等共用抽象被改動時觸發，屬於變更層級的升級，不是靜態 baseline。
- **保留意見**：`pottery/base.py` 會讀 `REDIS_URL`（可能含連線密碼）並傳給 redis-py，但未記錄或輸出。若人類認為這屬於 H3，可將 `base.py` 列入 H3；代價是與 H4 重疊並提高誤報率。

### 2.3 complexity：建議 `medium` (1)

- **為什麼是 medium**：單一 Python 套件、沒有跨服務拓撲，但也不是單檔模組——18 個實作模組共用 `pottery/base.py` 的抽象，且同步／非同步雙實作讓核心邏輯有兩份。典型變更會同時觸及 `base.py`、目標模組與 `tests/`，符合 docs/06 §3.3「跨數個模組」的判準。
- **為什麼不是 low (0)**：不是單一檔案／單一模組；Redlock 的 quorum、auto-release、extension 與 clock-drift 補償不適合用「單檔小改」看待。
- **為什麼不是 high (2)**：沒有跨服務／跨系統協調、沒有新架構模式、沒有 migrations；外部依賴只有一個 Redis 端點，服務數量為 0。

---

## 3. risk-paths 設計（H1–H7）

完整內容見 `proposals/onboarding/risk-paths.yml`。摘要：

| 規則 | 是否寫入 glob | 實際命中／依據 |
| --- | --- | --- |
| H1 授權/認證 | 空陣列 | 掃描未發現；grep 只命中版權宣告的 `author` |
| H2 財務計算 | 空陣列 | 掃描未發現 payment/billing/ledger/invoice/tax |
| H3 敏感資料 | 空陣列 | 掃描未發現 PII/憑證/加密；`cryptography`/`PyJWT` 未被 import |
| H4 共用模組 | `pottery/base.py`、`pottery/monkey.py`、`pottery/annotations.py` | 全部容器與 primitive 共用的抽象／編碼器／型別 |
| H5 guardrail | `.github/**`、`CODEOWNERS`、`catalog-info.yaml`、`.dsh/skills/**` | 無條件寫入；`.github/**` 目前命中 workflow、issue templates、copilot-instructions |
| H6 schema 遷移 | 空陣列 | 無 migrations/、Flyway/Alembic、schema.sql；Redis 無宣告式 schema |
| H7 對外 API | `pottery/__init__.py`、`pottery/exceptions.py` | `__all__` 的 28 個公開名稱與公開例外階層 |

### 3.1 刻意的取捨（避免誤報）

- **不寫 `pottery/**`**：那會讓每一次功能變更都觸發 H4/H7，等於沒有硬規則。
- **不寫 `**/*token*`**：Redlock 的鎖 token 是隨機值，不是憑證；廣樣式會製造無關的升級。
- **H7 的 `pottery/__init__.py` 會連非破壞性的新增 export 一起命中**：這是保守取捨。此檔變更頻率低，誤報成本小於漏掉公開 API 破壞；若人類認為太嚴，可改用 CI 檢查 `__all__` 的差異。
- **H5 的四條 glob 無條件保留**：即使 `CODEOWNERS`、`catalog-info.yaml`、`.dsh/skills/` 目前不存在，搬檔後就會出現；先寫入才能保護未來的 guardrail。

---

## 4. 審核後搬檔（人類親手執行）

先把三個 `TODO` 換成人類裁定的合法值：

- `tactical` / `operational` / `strategic`
- `low` / `medium` / `high`
- `low` / `medium` / `high`

再執行：

```bash
git mv proposals/onboarding/catalog-info.yaml .
mkdir -p .github/factory
git mv proposals/onboarding/risk-paths.yml .github/factory/risk-paths.yml
git rm -r proposals/onboarding
```

搬檔後 `proposals/onboarding/README.md` 會被 `git rm -r` 一併移除；這是預期的。
`catalog-info.yaml` 與 `.github/factory/risk-paths.yml` 搬進正位後受 CODEOWNERS
與 H5 保護，日後只能由人類修改。

---

## 5. 合併後的雙向探測驗證（必做）

設定檔在 `proposals/` 時工廠讀不到它；「寫對了」與「工廠讀得到」在合併前無法
區分。依 docs/16 §5.2，**兩個方向都要驗**：只驗一般檔案無法區分「硬規則正確」
與「硬規則根本沒載入」。

以下 `total`／`tier` 以本提案的三軸建議值（tactical / low / medium）計算；
若人類改動裁定值，數字會變，但 `triggeredHardRules` 與 `escalated` 的方向不變。
`agent-automerge: "false"` 會讓 `automergeAllowed` 一律為 false，不影響
rescore 的升級判定。

### 5.1 方向一：只改一般檔案（預期不升級）

開一個 probe PR（base `software-factory`），只在 `tests/test_timer.py` 加一行
註解（或新增一個不在任何硬規則下的根目錄檔案），執行：

```bash
gh workflow run factory-rescore.yml --repo aswf-dev/software_factory \
  -f repo=agent-playground/pottery -f base_branch=software-factory -f pr_number=<PROBE_PR>
```

預期：

| 欄位 | 預期值 |
| --- | --- |
| `total` | 1（0 + 0 + 1） |
| `tier` | `on-loop` |
| `triggeredHardRules` | `[]` |
| `escalated` | `false` |
| `automergeAllowed` | `false`（owner veto） |

### 5.2 方向二：改一個硬規則路徑（預期升級）

另開一個 probe PR，只在 `pottery/base.py` 加一行註解（不改行為），執行同一條
rescore 指令，`pr_number` 換成該 probe PR：

```bash
gh workflow run factory-rescore.yml --repo aswf-dev/software_factory \
  -f repo=agent-playground/pottery -f base_branch=software-factory -f pr_number=<PROBE_PR_H4>
```

預期：

| 欄位 | 預期值 |
| --- | --- |
| `total` | 3（0 + 2 + 1） |
| `tier` | `review` |
| `triggeredHardRules` | `["H4"]` |
| `escalated` | `true` |
| `automergeAllowed` | `false`（硬規則＋owner veto） |

> 若方向一與方向二的結果不符合上表，先確認 probe PR 的 diff 是否真的只含
> 預期路徑，再檢查 risk-paths 是否已搬到 `.github/factory/`。兩個方向都通過，
> 才把這個 repo 補進 docs/16 §5 的已納管清單。

### 5.3 重要提醒

- 本 repo 的 `python-package.yml` 只監聽 `master`；probe PR 與這個 onboarding
  PR 的 base 是 `software-factory`，**不會自動跑 pytest**。需要時請以
  `pytest --verbose` 手動執行（測試需要 `localhost:6379` 的 Redis）。
- 上述 rescore 指令的機制 repo 是 `aswf-dev/software_factory`；請確認執行者
  對該 repo 有 Actions 權限。

---

## 6. 本次驗證紀錄

在沙箱內實際執行：

| 驗證 | 結果 |
| --- | --- |
| `python3` + PyYAML 6.0.3 解析兩個 YAML | 通過；`hard_rules` 為 H1–H7 的 map，三軸值為字串 `TODO` |
| 三軸值合法性檢查 | 三軸都是 `TODO`（刻意留待裁定）；合法值集合與 `src/scoring/types.ts` 一致 |
| H5 完整性 | 四條 glob 都在（`.github/**`、`CODEOWNERS`、`catalog-info.yaml`、`.dsh/skills/**`） |
| 變更範圍 | `git diff --name-only software-factory...HEAD` 只有 `proposals/onboarding/` 下的三個檔案 |
| 計分模擬（`src/scoring/score.ts`＋本提案 risk-paths） | 一般檔 `tests/test_timer.py` → total 1、on-loop、`[]`；`pottery/base.py` → total 3、review、`["H4"]`；`pottery/__init__.py` → `["H7"]`；`.github/**` → `["H5"]`。`automergeAllowed` 皆為 false |
| 目標 repo 測試 collection | `pytest --collect-only`：323 tests collected |
| 非外部服務測試子集 | `pytest tests/test_timer.py tests/test_executor.py`：4 passed |
| 完整測試套件 | **未執行**：`tests/conftest.py` 需要 `localhost:6379` 的 Redis，沙箱沒有 `redis-server`；依 Issue 的「不跑需外部服務的 E2E」排除 |

---

## 7. 待人類確認

1. `spec.owner` 目前暫填 `group:default/factory-team`，請改成 pottery 的實際 owner group。
2. business-criticality 的 fork／上游發佈定位：若這個 repo 會代表上游發佈，criticality 可能不是 tactical。
3. `pottery/base.py` 的 `REDIS_URL` 是否算 H3 敏感資料處理（目前只列 H4）。
4. H6 是否要保護 Redis key 的隱含編碼格式；目前因為沒有 migrations/schema 而留空。
5. 本 repo 沒有 `CODEOWNERS`；搬檔後誰來守護 `catalog-info.yaml` 與 risk-paths？
6. `python-package.yml` 只觸發 `master`；是否要另開工單讓 `software-factory` 也跑 CI（agent 不得改 `.github/**`）。
