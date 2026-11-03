/-
Concrete reachable states transcribed from the two ITF traces that G2
(`specs/quint/TRIAGE.md`) marked `toLean = yes`.

Trace 1: `specs/quint/traces/as_is_extend_success_without_validity.itf.json`
Trace 2: `specs/quint/traces/as_is_late_extend_no_compensation.itf.json`

The states are built by applying the model transitions with the same
durations and master subsets as the Quint trace.  The locked() step in
trace 1 is omitted: it only updates `lastLock*` fields, which no headline
statement reads, and omitting it keeps the witness minimal.
-/

import Specs.Model

namespace Redlock

/-! ## Trace 1: late as-is extend still reports success -/

def w1s0 : State := initState

def w1s1 : State :=
  applyExtend false w1s0 1 47

def w1s2 : State :=
  applyExtend false w1s1 0 52

def w1s3 : State :=
  applyExtend false w1s2 0 123

def w1s4 : State :=
  applyAcquire w1s3 1 169 [1, 2, 3]

def w1s5 : State :=
  applyAdvance w1s4 106

def w1s6 : State :=
  applyAdvance w1s5 114

def w1s7 : State :=
  applyAcquire w1s6 0 58 [0, 2]

def w1s8 : State :=
  applyAdvance w1s7 97

/-- The Quint trace's `locked()` step at 766 -> 794 changes only
`lastLock*`, which no headline statement reads; it is kept as a pure
28 ms clock advance so the later timestamps match the trace. -/
def w1s9 : State :=
  applyAdvance w1s8 28

def w1s10 : State :=
  applyExtend false w1s9 0 146

def w1s11 : State :=
  applyAcquire w1s10 1 187 [0, 1, 2]

def w1s12 : State :=
  applyExtend false w1s11 1 6

def w1s13 : State :=
  applyExtend false w1s12 1 205

/-! ## Trace 2: late as-is extend leaves a quorum of keys behind -/

def w2s0 : State := initState

def w2s1 : State :=
  applyAdvance w2s0 98

def w2s2 : State :=
  applyAdvance w2s1 141

def w2s3 : State :=
  applyAcquire w2s2 0 28 [0, 1, 2]

def w2s4 : State :=
  applyExtend false w2s3 0 198

/-! ## Reachability

These are the statements that make the witnesses non-vacuous.  Each step
is a concrete `StepAsIs` instance; proving them here is the non-vacuity
check, not a proof of the headline theorems.
-/

private theorem step_w1_01 : StepAsIs w1s0 w1s1 := by
  unfold StepAsIs
  exact Or.inr (Or.inl ⟨1, 47, by decide, by decide, rfl⟩)

private theorem step_w1_12 : StepAsIs w1s1 w1s2 := by
  unfold StepAsIs
  exact Or.inr (Or.inl ⟨0, 52, by decide, by decide, rfl⟩)

private theorem step_w1_23 : StepAsIs w1s2 w1s3 := by
  unfold StepAsIs
  exact Or.inr (Or.inl ⟨0, 123, by decide, by decide, rfl⟩)

private theorem step_w1_34 : StepAsIs w1s3 w1s4 := by
  unfold StepAsIs
  exact Or.inl ⟨1, 169, [1, 2, 3], by decide, by decide, by decide, rfl⟩

private theorem step_w1_45 : StepAsIs w1s4 w1s5 := by
  unfold StepAsIs
  exact Or.inr (Or.inr (Or.inr ⟨106, by decide, by decide, rfl⟩))

private theorem step_w1_56 : StepAsIs w1s5 w1s6 := by
  unfold StepAsIs
  exact Or.inr (Or.inr (Or.inr ⟨114, by decide, by decide, rfl⟩))

private theorem step_w1_67 : StepAsIs w1s6 w1s7 := by
  unfold StepAsIs
  exact Or.inl ⟨0, 58, [0, 2], by decide, by decide, by decide, rfl⟩

private theorem step_w1_78 : StepAsIs w1s7 w1s8 := by
  unfold StepAsIs
  exact Or.inr (Or.inr (Or.inr ⟨97, by decide, by decide, rfl⟩))

private theorem step_w1_89 : StepAsIs w1s8 w1s9 := by
  unfold StepAsIs
  exact Or.inr (Or.inr (Or.inr ⟨28, by decide, by decide, rfl⟩))

private theorem step_w1_9_10 : StepAsIs w1s9 w1s10 := by
  unfold StepAsIs
  exact Or.inr (Or.inl ⟨0, 146, by decide, by decide, rfl⟩)

private theorem step_w1_10_11 : StepAsIs w1s10 w1s11 := by
  unfold StepAsIs
  exact Or.inl ⟨1, 187, [0, 1, 2], by decide, by decide, by decide, rfl⟩

private theorem step_w1_11_12 : StepAsIs w1s11 w1s12 := by
  unfold StepAsIs
  exact Or.inr (Or.inl ⟨1, 6, by decide, by decide, rfl⟩)

private theorem step_w1_12_13 : StepAsIs w1s12 w1s13 := by
  unfold StepAsIs
  exact Or.inr (Or.inl ⟨1, 205, by decide, by decide, rfl⟩)

theorem reachable_w1s13 : ReachableAsIs w1s13 := by
  have h1 : ReachableAsIs w1s1 := .step .init step_w1_01
  have h2 : ReachableAsIs w1s2 := .step h1 step_w1_12
  have h3 : ReachableAsIs w1s3 := .step h2 step_w1_23
  have h4 : ReachableAsIs w1s4 := .step h3 step_w1_34
  have h5 : ReachableAsIs w1s5 := .step h4 step_w1_45
  have h6 : ReachableAsIs w1s6 := .step h5 step_w1_56
  have h7 : ReachableAsIs w1s7 := .step h6 step_w1_67
  have h8 : ReachableAsIs w1s8 := .step h7 step_w1_78
  have h9 : ReachableAsIs w1s9 := .step h8 step_w1_89
  have h10 : ReachableAsIs w1s10 := .step h9 step_w1_9_10
  have h11 : ReachableAsIs w1s11 := .step h10 step_w1_10_11
  have h12 : ReachableAsIs w1s12 := .step h11 step_w1_11_12
  exact .step h12 step_w1_12_13

private theorem step_w2_01 : StepAsIs w2s0 w2s1 := by
  unfold StepAsIs
  exact Or.inr (Or.inr (Or.inr ⟨98, by decide, by decide, rfl⟩))

private theorem step_w2_12 : StepAsIs w2s1 w2s2 := by
  unfold StepAsIs
  exact Or.inr (Or.inr (Or.inr ⟨141, by decide, by decide, rfl⟩))

private theorem step_w2_23 : StepAsIs w2s2 w2s3 := by
  unfold StepAsIs
  exact Or.inl ⟨0, 28, [0, 1, 2], by decide, by decide, by decide, rfl⟩

private theorem step_w2_34 : StepAsIs w2s3 w2s4 := by
  unfold StepAsIs
  exact Or.inr (Or.inl ⟨0, 198, by decide, by decide, rfl⟩)

theorem reachable_w2s3 : ReachableAsIs w2s3 := by
  have h1 : ReachableAsIs w2s1 := .step .init step_w2_01
  have h2 : ReachableAsIs w2s2 := .step h1 step_w2_12
  exact .step h2 step_w2_23

theorem reachable_w2s4 : ReachableAsIs w2s4 := by
  exact .step reachable_w2s3 step_w2_34

end Redlock
