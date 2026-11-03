/-
Headline theorem proofs (proofs phase, after G3 sign-off).

The statements are the snapshots signed off at G3 and recorded in
`specs/lean/MODEL-MAP.md`; they must not be weakened.

Rule IDs refer to `specs/lean/RULES.md`.
-/

import Specs.Witnesses
import Specs.Invariants

namespace Redlock

/-! ### INV-1: mutual exclusion of valid holders -/

/-- INV-1: in every state reachable under the as-is rules, at most one
client is inside its A1(b) validity interval. -/
theorem at_most_one_valid_holder
    (s : State) (h : ReachableAsIs s) :
    AtMostOneValidHolder s := by
  exact atMostOne_of_inv s (inv_reachable s h)

/-! ### INV-6 counterexample 1: success after the completion window -/

/-- CF-1 (G2 `toLean = yes`): trace 1 reaches a state where client 1's
as-is `extend` reports success although its completion time (1338 ms) is
at or past its A3 validity deadline (1133 + 196 = 1329 ms).  The state is
built from `as_is_extend_success_without_validity.itf.json`. -/
theorem as_is_late_extend_reports_success :
    ReachableAsIs w1s13 ∧
    w1s13.now = 1338 ∧
    ((w1s13.clients 1).lastExtendOk = true) ∧
    ((w1s13.clients 1).lastExtendStart = 1133) ∧
    ((w1s13.clients 1).lastExtendEnd = 1338) ∧
    ((w1s13.clients 1).lastExtendRenewals = 3) ∧
    ((w1s13.clients 1).lastExtendEnd ≥
      (w1s13.clients 1).lastExtendStart + ValidityWindow) := by
  refine ⟨reachable_w1s13, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-! ### INV-6 counterexample 2: late success without compensation -/

/-- CF-2 (G2 `toLean = yes`): trace 2 reaches a state where client 0's
as-is `extend` reports success at 465 ms (deadline 267 + 196 = 463 ms)
and still has a strict-majority of live keys (3 of 5) with its token;
the as-is failure/late path performs no compensation release.  The state
is built from `as_is_late_extend_no_compensation.itf.json`. -/
theorem as_is_late_extend_no_compensation :
    ReachableAsIs w2s4 ∧
    w2s4.now = 465 ∧
    ((w2s4.clients 0).lastExtendOk = true) ∧
    ((w2s4.clients 0).lastExtendStart = 267) ∧
    ((w2s4.clients 0).lastExtendEnd = 465) ∧
    ((holders w2s4 0).length = 3) ∧
    ((w2s4.clients 0).lastExtendEnd ≥
      (w2s4.clients 0).lastExtendStart + ValidityWindow) := by
  refine ⟨reachable_w2s4, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-! ### INV-6 contract (G1 A3): the corrected extend rule -/

/-- INV-6 first clause: in the contract model, a successful `extend`
(started while another extension is still allowed) always finishes
strictly before `start + AutoReleaseTime - Drift`. -/
theorem contract_extend_success_implies_validity
    (s : State) (c : ClientId) (delay : Nat)
    (hdelay : delay ≤ MaxOpDelay)
    (hext : (s.clients c).extensions < NumExtensions) :
    (((applyExtend true s c delay).clients c).lastExtendOk = true) →
    (((applyExtend true s c delay).clients c).lastExtendEnd <
      ((applyExtend true s c delay).clients c).lastExtendStart +
        ValidityWindow) := by
  intro hok
  have hok' : (decide (Quorum ≤ (holders s c).length) &&
      decide (s.now + delay < s.now + ValidityWindow)) = true := by
    simpa [applyExtend] using hok
  have hboth : decide (Quorum ≤ (holders s c).length) = true ∧
      decide (s.now + delay < s.now + ValidityWindow) = true := by
    simpa [Bool.and_eq_true] using hok'
  have hv : decide (s.now + delay < s.now + ValidityWindow) = true := hboth.2
  have hlt : s.now + delay < s.now + ValidityWindow := decide_eq_true_eq.mp hv
  simpa [applyExtend] using hlt

/-- INV-6 compensation clause: a contract `extend` that completes at or
past the A3 deadline leaves no live key holding this client's token. -/
theorem contract_late_extend_compensates
    (s : State) (c : ClientId) (delay : Nat)
    (hdelay : delay ≤ MaxOpDelay)
    (hext : (s.clients c).extensions < NumExtensions)
    (hlate : ¬ (s.now + delay < s.now + ValidityWindow)) :
    ((holders (applyExtend true s c delay) c).length = 0) := by
  unfold holders
  rw [List.length_eq_zero_iff, List.filter_eq_nil_iff]
  intro m _
  rw [Bool.not_eq_true]
  have hv : decide (s.now + delay < s.now + ValidityWindow) = false := by
    rw [decide_eq_false_iff_not]
    exact hlate
  cases ht : (s.clients c).token with
  | none =>
    have htoken : ((applyExtend true s c delay).clients c).token = none := by
      rw [extend_token_self true s c delay]
      exact ht
    exact holds_eq_false_of_token_none _ _ _ htoken
  | some t =>
    have hmaster0 : (applyExtend true s c delay).masters m =
        (releaseToken (renewHolders s c) (s.clients c).token).masters m := by
      unfold applyExtend
      dsimp only
      simp only [if_true]
      rw [hv]
      simp
    have hmaster : (applyExtend true s c delay).masters m =
        (releaseToken (renewHolders s c) (some t)).masters m := by
      rw [hmaster0, ht]
    have hne := releaseToken_owner_ne_self (renewHolders s c) t m
    have howner_ne : ((applyExtend true s c delay).masters m).owner ≠ some t := by
      rw [hmaster]
      exact hne
    cases ho : ((applyExtend true s c delay).masters m).owner with
    | none => exact holds_eq_false_of_owner_none _ _ _ ho
    | some o =>
      have hto : t ≠ o := by
        intro h
        exact howner_ne (by rw [ho, h])
      have htoken : ((applyExtend true s c delay).clients c).token = some t := by
        rw [extend_token_self true s c delay]
        exact ht
      exact holds_eq_false_of_ne _ _ _ _ _ htoken ho hto

end Redlock
