/-
Non-vacuity witnesses.  `Examples.lean` is not the claim; the headline
theorems are in `Specs/Proofs.lean`.
-/

import Specs.Proofs

namespace Redlock

/-- INV-1 is non-vacuous: after the successful acquire in trace 2 exactly
one client is inside its validity interval. -/
example : validHolderCount w2s3 = 1 := by
  decide

/-- CF-2's "still holds a quorum" conjunct is non-vacuous. -/
example : (holders w2s4 0).length = 3 := by
  decide

/-- The contract model is non-vacuous: extending before the deadline
succeeds. -/
example : ((applyExtend true w2s3 0 0).clients 0).lastExtendOk = true := by
  decide

/-- The contract compensation is non-vacuous: a late contract extend
leaves no live key with this client's token. -/
example : (holders (applyExtend true w2s3 0 198) 0).length = 0 := by
  decide

end Redlock
