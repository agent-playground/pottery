# Issue #26（S11）相依更新稽核：redis 與 setuptools

> 對應 Issue：agent-playground/pottery#26（`agent-update-deps`，流程步驟 S11）
> 稽核日期：2026-11-01
> 變體：`b`（本檔案為本變體自己的交付，不引用另一變體的內容）

## 0. 結論摘要

**本次沒有可升級的修補版本，因此沒有變更任何相依版本。**

| 套件 | `requirements.txt` 目前 pin | PyPI 最新版（2026-11-01） | 是否有更新的修補版 | 決策 |
| --- | --- | --- | --- | --- |
| `redis` | `8.1.0` | `8.1.0`（2026-07-30 發佈） | 否 | 維持 `8.1.0` |
| `setuptools` | `84.2.1` | `84.2.1`（2026-10-20 發佈） | 否 | 維持 `84.2.1` |

兩個套件的精確版本在 OSV 查詢都是 **0 筆已知弱點**；兩者的 `requires_python` 都是
`>=3.10`，與 `setup.py:71` 的 `python_requires='>=3.10, <4'` 相容。因為沒有較新的修補
版本可用，Issue 要求的「只做安全與相容性更新，不改 API」在此收斂為**不改動**：
`requirements.txt`、`requirements-to-freeze.txt`、`setup.py` 與 `pottery/` 全部未修改。

## 1. 範圍與方法

- 目標套件：Issue 指定的 `redis`、`setuptools`（只查這兩個，不擴大到其他套件）。
- 版本來源：PyPI JSON API 的 `info.version` 與 `requires_python`，另以
  `pip index versions` 交叉確認實際可安裝清單。
- 安全面：以 OSV `POST /v1/query`，指定 `PyPI` ecosystem 與**精確版本**查詢。
- 相容性面：比對最新版的 `requires_python` 與本 repo 的 `python_requires`／CI matrix。
- 驗證面：以 `requirements.txt` 建立 venv、啟動 Redis 7，跑完整 pytest 與既有靜態檢查。

## 2. 版本與安全查詢結果

### 2.1 redis

- `requirements.txt`：`redis==8.1.0`
- PyPI 最新版：`8.1.0`，`requires_python=>=3.10`，發佈日 `2026-07-30`
- `pip index versions redis` 的最高版本：`8.1.0`
- OSV（`redis` `8.1.0`）：`vulns: 0`

### 2.2 setuptools

- `requirements.txt`：`setuptools==84.2.1`
- PyPI 最新版：`84.2.1`，`requires_python=>=3.10`，發佈日 `2026-10-20`
- `pip index versions setuptools` 的最高版本：`84.2.1`
- OSV（`setuptools` `84.2.1`）：`vulns: 0`

> 註：`setuptools` 只出現在 freeze 產物 `requirements.txt`，不是
> `requirements-to-freeze.txt` 的直接依賴；CI 在安裝 freeze 前會先
> `pip install --upgrade pip setuptools wheel`，目前同樣落在 `84.2.1`。
> 這次不需要為它新增或修改任何 manifest。

## 3. 為什麼不改

1. **沒有目標版本可升**：Issue 要求的是「可升級的修補版本」；兩個套件的 pin 已經等於
   PyPI 最新版，沒有任何 `8.1.x` 或 `84.2.x` 的後續修補版存在。
2. **沒有已知 CVE 需要修**：精確版本的 OSV 查詢皆為 0 筆。沒有「安全性更新」的觸發點。
3. **沒有相容性更新可做**：兩者都支援 Python `>=3.10`，與本 repo 的下限一致；升級與否
   不會改變相容性結論。
4. **不改 API**：本次沒有改動 `setup.py` 的 `install_requires`、沒有改動
   `pottery/__init__.py` 的匯出面，也沒有新增任何套件（SR5）。

## 4. 驗證紀錄

環境：Python `3.14.4`、Redis `7-alpine`（`localhost:6379`）、依賴由
`requirements.txt` 安裝（`redis 8.1.0`、`setuptools 84.2.1`、`pytest 9.2.0`）。

```console
$ python -m pytest --verbose --cov-config=.coveragerc --cov=pottery --cov=tests
...
TOTAL                                  4443     22    458      1    99%
======================= 353 passed, 4 skipped in 27.49s ========================
```

4 個 skip 都是**既有**的紅燈保留，不是本次新增：

- `tests/test_nextid_business_rules.py` ×3：R7 缺陷（`NextID` 沒有
  `initial_value`／`chunk_size`），斷言保留給 `agent-fix-bug`，已在 Issue #18 回報。
- `tests/test_redlock.py` ×1：F1（偶數 master 的 `QuorumIsImpossible` 門檻），
  見 `docs/research/9-s5-a1-a4-inventory.md` §2.5.1，修復另開工作項。

靜態檢查（與 CI 相同指令）：

```console
$ mypy
Success: no issues found in 41 source files
$ flake8 setup.py pottery/*.py tests/*.py --count --max-complexity=10 --statistics
0
$ isort setup.py pottery/*.py tests/*.py --check-only --diff
（無輸出，exit 0）
$ bandit --recursive pottery
Total issues (by severity): ... High: 0 ... Medium: 0
```

## 5. 重現指令

```console
$ python -m pip index versions redis
redis (8.1.0)
$ python -m pip index versions setuptools
setuptools (84.2.1)

$ curl -s -X POST https://api.osv.dev/v1/query \
    -H 'Content-Type: application/json' \
    -d '{"package":{"name":"redis","ecosystem":"PyPI"},"version":"8.1.0"}'
{"vulns":[]}

$ curl -s -X POST https://api.osv.dev/v1/query \
    -H 'Content-Type: application/json' \
    -d '{"package":{"name":"setuptools","ecosystem":"PyPI"},"version":"84.2.1"}'
{"vulns":[]}
```

> OSV 與 PyPI 都是會變動的快照；2026-11-01 的查詢結果如上。下一次 S11 應重新查詢，
> 不能把本檔案當成永久保證。

## 6. 未納入本次的相依（明確排除）

`docs/research/9-s5-a1-a4-inventory.md` §2.3.2 另外列出 6 個落後套件
（`docutils`、`flake8`、`mypy`、`pyflakes`、`readme_renderer`、`stevedore`）。
它們**不在** Issue #26 指定的 `redis`／`setuptools` 範圍內，且其中 `flake8`、
`pyflakes`、`stevedore` 的升級與 Python 3.10 下限決策綁在一起（W1／W6）。本工作項
不擅自擴大範圍，留待人類先完成 Python 下限裁定後，另開 `agent-update-deps` 處理。

## 7. 限制

- 本次只在 Python 3.14.4 上跑完整測試；CI matrix 的 3.11–3.15 沒有逐一重跑。
- 目標 repo 的 GitHub Actions 目前只綁 `master`，`software-factory` 分支的 PR 不會
  觸發 `.github/workflows/python-package.yml`；本檔的測試證據是本地執行結果（既有
  H5 缺口，W7）。
- 本檔案只記錄稽核結果，沒有變更任何相依版本；若人類要求「即使已是最新也要調整
  manifest」，那屬於新範圍，應另開工作項。
