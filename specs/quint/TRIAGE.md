# G2 反例分類（TRIAGE）

每一個反例的判定：真缺陷（real）／模型假象（artifact）／設計取捨（accepted），是否送 Lean，是否涉及資安。

- 判定者（actor）：philipz
- 時間（at）：2026-11-03T00:27:25.123Z

| id | verdict | toLean | security |
|---|---|---|---|
| as_is_even_extend_success_without_validity | real | no | no |
| as_is_extend_success_without_validity | real | yes | no |
| as_is_late_extend_no_compensation | real | yes | no |
| as_is_slow_extend_success_without_validity | real | no | no |
