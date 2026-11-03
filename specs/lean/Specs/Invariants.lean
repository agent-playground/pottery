import Specs.Model
namespace Redlock
set_option linter.unusedSimpArgs false

/-! Helper definitions for the inductive invariant. -/

def Valid (s : State) (c : ClientId) : Prop := s.now < (s.clients c).beliefEnd

def BeliefLe (s : State) : Prop :=
  ∀ c, (s.clients c).beliefEnd ≤ s.now + ValidityWindow

def ClientsBelow (s : State) : Prop :=
  ∀ (c : ClientId) (t : Nat), (s.clients c).token = some t → t < s.nextToken

def OwnersBelow (s : State) : Prop :=
  ∀ (m : MasterId) (o : Nat), (s.masters m).owner = some o → o < s.nextToken

def TokensInjective (s : State) : Prop :=
  ∀ (c c' : ClientId) (t : Nat),
    (s.clients c).token = some t → (s.clients c').token = some t → c = c'

structure Inv (s : State) : Prop where
  quorum : ∀ c, Valid s c → Quorum ≤ (holders s c).length
  expiry : ∀ c m, Valid s c → holds s c m = true → (s.clients c).beliefEnd < (s.masters m).expiry
  clientsBelow : ClientsBelow s
  ownersBelow : OwnersBelow s
  injective : TokensInjective s
  beliefLe : BeliefLe s

/-! ## holds facts -/

theorem holds_eq_true_iff (s : State) (c : ClientId) (m : MasterId) :
    holds s c m = true ↔
      ∃ t, (s.clients c).token = some t ∧ (s.masters m).owner = some t ∧
        s.now < (s.masters m).expiry := by
  unfold holds
  cases hc : (s.clients c).token with
  | none => simp
  | some t =>
    cases hm : (s.masters m).owner with
    | none => simp
    | some o =>
      simp only [Option.some.injEq, Bool.and_eq_true, decide_eq_true_eq,
        exists_eq_left, true_and, beq_iff_eq]
      constructor
      · rintro ⟨h, hlt⟩
        exact ⟨t, rfl, h.symm, hlt⟩
      · rintro ⟨x, hx, hox, hlt⟩
        subst hx
        exact ⟨hox.symm, hlt⟩

theorem holds_eq_false_of_token_none (s : State) (c : ClientId) (m : MasterId)
    (h : (s.clients c).token = none) : holds s c m = false := by
  simp [holds, h]

theorem holds_eq_false_of_owner_none (s : State) (c : ClientId) (m : MasterId)
    (h : (s.masters m).owner = none) : holds s c m = false := by
  simp [holds, h]

theorem holds_eq_false_of_ne (s : State) (c : ClientId) (m : MasterId) (t o : Nat)
    (hc : (s.clients c).token = some t) (hm : (s.masters m).owner = some o) (h : t ≠ o) :
    holds s c m = false := by
  simp [holds, hc, hm, h]

theorem holds_eq_false_of_not_live {s : State} {c : ClientId} {m : MasterId}
    (h : live (s.masters m) s.now = false) : holds s c m = false := by
  unfold holds live at *
  cases hc : (s.clients c).token with
  | none => simp
  | some t =>
    cases hm : (s.masters m).owner with
    | none => simp
    | some o =>
      simp only [hm, Option.isSome_some, Bool.true_and] at h ⊢
      rw [h]
      simp

theorem mem_freeMasters {s : State} {m : MasterId} (h : m ∈ freeMasters s) :
    live (s.masters m) s.now = false := by
  unfold freeMasters at h
  rw [List.mem_filter] at h
  simpa using h.2

theorem mem_freeMasters_of_subset {s : State} {chosen : List MasterId}
    (hsub : listSubset chosen (freeMasters s) = true) {m : MasterId} (hm : m ∈ chosen) :
    m ∈ freeMasters s := by
  unfold listSubset at hsub
  exact List.contains_iff_mem.mp ((List.all_eq_true.mp hsub) m hm)

theorem holds_congr_holders {s s' : State} (h : ∀ c m, holds s c m = holds s' c m) (c : ClientId) :
    holders s c = holders s' c := by
  unfold holders
  exact List.filter_congr (fun m _ => h c m)

/-! ## Acquire field facts -/

abbrev AcquireOk (s : State) (delay : Nat) (chosen : List MasterId) : Bool :=
  decide (Quorum ≤ chosen.length ∧ s.now + delay < s.now + ValidityWindow)

theorem acquire_now (s : State) (c : ClientId) (delay : Nat) (chosen : List MasterId) :
    (applyAcquire s c delay chosen).now = s.now + delay := rfl

theorem acquire_nextToken (s : State) (c : ClientId) (delay : Nat) (chosen : List MasterId) :
    (applyAcquire s c delay chosen).nextToken = s.nextToken + 1 := rfl

theorem acquire_token_self (s : State) (c : ClientId) (delay : Nat) (chosen : List MasterId) :
    ((applyAcquire s c delay chosen).clients c).token = some s.nextToken := by
  unfold applyAcquire
  dsimp only
  rw [if_pos rfl]

theorem acquire_token_other (s : State) (c d : ClientId) (delay : Nat) (chosen : List MasterId)
    (h : d ≠ c) : ((applyAcquire s c delay chosen).clients d).token = (s.clients d).token := by
  unfold applyAcquire
  dsimp only
  rw [if_neg h]

theorem acquire_clients_other (s : State) (c d : ClientId) (delay : Nat) (chosen : List MasterId)
    (h : d ≠ c) : (applyAcquire s c delay chosen).clients d = s.clients d := by
  unfold applyAcquire
  dsimp only
  rw [if_neg h]

theorem acquire_beliefEnd_self (s : State) (c : ClientId) (delay : Nat) (chosen : List MasterId) :
    ((applyAcquire s c delay chosen).clients c).beliefEnd =
      if AcquireOk s delay chosen = true then s.now + ValidityWindow else 0 := by
  unfold applyAcquire
  dsimp only
  rw [if_pos rfl]

theorem acquire_masters_ok (s : State) (c : ClientId) (delay : Nat) (chosen : List MasterId)
    (hok : AcquireOk s delay chosen = true) (m : MasterId) :
    (applyAcquire s c delay chosen).masters m =
      if chosen.contains m then
        { owner := some s.nextToken, expiry := s.now + AutoReleaseTime }
      else s.masters m := by
  unfold applyAcquire
  dsimp only
  rw [if_pos hok]

theorem acquire_masters_not_ok (s : State) (c : ClientId) (delay : Nat) (chosen : List MasterId)
    (hok : AcquireOk s delay chosen = false) (hown : OwnersBelow s) (m : MasterId) :
    (applyAcquire s c delay chosen).masters m =
      if chosen.contains m then emptyMaster else s.masters m := by
  unfold applyAcquire
  dsimp only
  have hnot : ¬ (AcquireOk s delay chosen = true) := by rw [hok]; simp
  rw [if_neg hnot]
  unfold releaseToken
  dsimp only
  by_cases hc : chosen.contains m = true
  · simp only [hc, if_true]
  · simp only [hc, Bool.false_eq_true, if_false]
    cases ho : (s.masters m).owner with
    | none => simp [ho]
    | some o =>
      have hlt : o < s.nextToken := hown m o ho
      have hne : ¬ (s.nextToken = o) := by omega
      simp [ho, hne]

theorem acquire_masters_not_chosen (s : State) (c : ClientId) (delay : Nat)
    (chosen : List MasterId) (hown : OwnersBelow s) (m : MasterId)
    (hc : chosen.contains m = false) :
    (applyAcquire s c delay chosen).masters m = s.masters m := by
  by_cases hok : AcquireOk s delay chosen = true
  · rw [acquire_masters_ok s c delay chosen hok m]
    simp only [hc, Bool.false_eq_true, if_false]
  · have hokf : AcquireOk s delay chosen = false := by
      cases h : AcquireOk s delay chosen <;> simp_all
    rw [acquire_masters_not_ok s c delay chosen hokf hown m]
    simp only [hc, Bool.false_eq_true, if_false]

end Redlock

namespace Redlock

theorem holds_applyAcquire_self_of_ok (s : State) (c : ClientId) (delay : Nat)
    (chosen : List MasterId) (hok : AcquireOk s delay chosen = true) (hown : OwnersBelow s)
    (m : MasterId) :
    holds (applyAcquire s c delay chosen) c m = true ↔ chosen.contains m = true := by
  constructor
  · intro h
    rw [holds_eq_true_iff] at h
    rcases h with ⟨t, htok, howner, hlt⟩
    rw [acquire_token_self] at htok
    by_cases hc : chosen.contains m = true
    · exact hc
    · have hcf : chosen.contains m = false := by
        cases h : chosen.contains m <;> simp_all
      rw [acquire_masters_ok s c delay chosen hok m] at howner
      simp only [hcf, Bool.false_eq_true, if_false] at howner
      have hlt' : t < s.nextToken := hown m t howner
      have ht : s.nextToken = t := Option.some.inj htok
      omega
  · intro hc
    rw [holds_eq_true_iff]
    refine ⟨s.nextToken, acquire_token_self s c delay chosen, ?_, ?_⟩
    · rw [acquire_masters_ok s c delay chosen hok m]
      simp only [hc, if_true]
    · rw [acquire_now, acquire_masters_ok s c delay chosen hok m]
      simp only [hc, if_true]
      have hP : Quorum ≤ chosen.length ∧ s.now + delay < s.now + ValidityWindow :=
        decide_eq_true_eq.mp hok
      have hVA : ValidityWindow < AutoReleaseTime := by decide
      omega

theorem holds_applyAcquire_other_of_valid (s : State) (c d : ClientId) (delay : Nat)
    (chosen : List MasterId) (m : MasterId) (hne : d ≠ c) (hInv : Inv s)
    (hsub : listSubset chosen (freeMasters s) = true)
    (hvalid : s.now + delay < (s.clients d).beliefEnd) :
    holds (applyAcquire s c delay chosen) d m = holds s d m := by
  have hnow := acquire_now s c delay chosen
  have htok := acquire_token_other s c d delay chosen hne
  apply Bool.eq_iff_iff.mpr
  rw [holds_eq_true_iff, holds_eq_true_iff]
  constructor
  · rintro ⟨t, htok', howner', hlt'⟩
    rw [htok] at htok'
    by_cases hc : chosen.contains m = true
    · by_cases hok : AcquireOk s delay chosen = true
      · rw [acquire_masters_ok s c delay chosen hok m] at howner'
        simp only [hc, if_true] at howner'
        have ht : s.nextToken = t := Option.some.inj howner'
        have hlt'' : t < s.nextToken := hInv.clientsBelow d t htok'
        omega
      · have hokf : AcquireOk s delay chosen = false := by
          cases h : AcquireOk s delay chosen <;> simp_all
        rw [acquire_masters_not_ok s c delay chosen hokf hInv.ownersBelow m] at howner'
        simp only [hc, if_true] at howner'
        simp [emptyMaster] at howner'
    · have hcf : chosen.contains m = false := by
        cases h : chosen.contains m <;> simp_all
      rw [acquire_masters_not_chosen s c delay chosen hInv.ownersBelow m hcf] at howner'
      refine ⟨t, htok', howner', ?_⟩
      rw [hnow, acquire_masters_not_chosen s c delay chosen hInv.ownersBelow m hcf] at hlt'
      omega
  · rintro ⟨t, htok', howner', hlt'⟩
    by_cases hc : chosen.contains m = true
    · have hfree : m ∈ freeMasters s := mem_freeMasters_of_subset hsub (List.contains_iff_mem.mp hc)
      have hfalse : holds s d m = false := holds_eq_false_of_not_live (mem_freeMasters hfree)
      have holdtrue : holds s d m = true :=
        (holds_eq_true_iff s d m).mpr ⟨t, htok', howner', hlt'⟩
      rw [hfalse] at holdtrue
      simp at holdtrue
    · have hcf : chosen.contains m = false := by
        cases h : chosen.contains m <;> simp_all
      have hvald : Valid s d := by unfold Valid; omega
      have hexp := hInv.expiry d m hvald (by
        rw [holds_eq_true_iff]; exact ⟨t, htok', howner', hlt'⟩)
      refine ⟨t, ?_, ?_, ?_⟩
      · rw [htok]; exact htok'
      · rw [acquire_masters_not_chosen s c delay chosen hInv.ownersBelow m hcf]; exact howner'
      · rw [hnow, acquire_masters_not_chosen s c delay chosen hInv.ownersBelow m hcf]
        omega

end Redlock

namespace Redlock

/-! ## Extend field facts -/

abbrev ExtendOk (s : State) (c : ClientId) : Bool :=
  decide (Quorum ≤ (holders s c).length)

theorem extend_now (strict : Bool) (s : State) (c : ClientId) (delay : Nat) :
    (applyExtend strict s c delay).now = s.now + delay := rfl

theorem extend_token_self (strict : Bool) (s : State) (c : ClientId) (delay : Nat) :
    ((applyExtend strict s c delay).clients c).token = (s.clients c).token := by
  unfold applyExtend
  dsimp only
  rw [if_pos rfl]

theorem extend_clients_other (strict : Bool) (s : State) (c d : ClientId) (delay : Nat)
    (h : d ≠ c) : (applyExtend strict s c delay).clients d = s.clients d := by
  unfold applyExtend
  dsimp only
  rw [if_neg h]

theorem extend_beliefEnd_self_asis (s : State) (c : ClientId) (delay : Nat) :
    ((applyExtend false s c delay).clients c).beliefEnd =
      if ExtendOk s c = true then s.now + ValidityWindow else (s.clients c).beliefEnd := by
  unfold applyExtend
  dsimp only
  rw [if_pos rfl]
  simp [ExtendOk]

theorem extend_beliefEnd_other (strict : Bool) (s : State) (c d : ClientId) (delay : Nat)
    (h : d ≠ c) : ((applyExtend strict s c delay).clients d).beliefEnd =
      (s.clients d).beliefEnd := by
  rw [extend_clients_other strict s c d delay h]

theorem extend_masters_asis (s : State) (c : ClientId) (delay : Nat) :
    (applyExtend false s c delay).masters = (renewHolders s c).masters := by
  unfold applyExtend
  dsimp only
  simp

theorem renewHolders_at (s : State) (c : ClientId) (m : MasterId) :
    (renewHolders s c).masters m =
      if holds s c m then
        { owner := (s.clients c).token, expiry := s.now + AutoReleaseTime }
      else s.masters m := rfl

theorem renewHolders_at_of_holds (s : State) (c : ClientId) (m : MasterId)
    (h : holds s c m = true) :
    (renewHolders s c).masters m =
      { owner := (s.clients c).token, expiry := s.now + AutoReleaseTime } := by
  rw [renewHolders_at]
  simp [h]

theorem renewHolders_at_of_not_holds (s : State) (c : ClientId) (m : MasterId)
    (h : holds s c m = false) :
    (renewHolders s c).masters m = s.masters m := by
  rw [renewHolders_at]
  simp [h]

theorem holds_applyExtend_self_of_valid (s : State) (c : ClientId) (delay : Nat)
    (m : MasterId) (hfinish : s.now + delay < s.now + ValidityWindow) :
    holds (applyExtend false s c delay) c m = holds s c m := by
  have hnow := extend_now false s c delay
  have htok := extend_token_self false s c delay
  have hmas := extend_masters_asis s c delay
  apply Bool.eq_iff_iff.mpr
  rw [holds_eq_true_iff, holds_eq_true_iff]
  constructor
  · rintro ⟨t, htokN, hownerN, hltN⟩
    rw [htok] at htokN
    by_cases hold : holds s c m = true
    · rw [holds_eq_true_iff] at hold
      rcases hold with ⟨t', ht', ho', hltOld⟩
      rw [htokN] at ht'
      have htEq : t = t' := Option.some.inj ht'
      refine ⟨t, htokN, ?_, hltOld⟩
      simpa [htEq] using ho'
    · have holdf : holds s c m = false := by
        cases h : holds s c m <;> simp_all
      rw [hmas, renewHolders_at_of_not_holds s c m holdf] at hownerN
      rw [hmas, renewHolders_at_of_not_holds s c m holdf, hnow] at hltN
      exact absurd ((holds_eq_true_iff s c m).mpr ⟨t, htokN, hownerN, by omega⟩)
        (by simp [holdf])
  · rintro ⟨t, htokOld, hownerOld, hltOld⟩
    have hold : holds s c m = true :=
      (holds_eq_true_iff s c m).mpr ⟨t, htokOld, hownerOld, hltOld⟩
    refine ⟨t, ?_, ?_, ?_⟩
    · rw [htok]; exact htokOld
    · rw [hmas, renewHolders_at_of_holds s c m hold]; exact htokOld
    · have holdExp : ((applyExtend false s c delay).masters m).expiry =
          s.now + AutoReleaseTime := by
        rw [hmas, renewHolders_at_of_holds s c m hold]
      rw [extend_now, holdExp]
      have hVA : ValidityWindow < AutoReleaseTime := by decide
      omega

theorem holds_applyExtend_other_of_valid (s : State) (c d : ClientId) (delay : Nat)
    (m : MasterId) (hne : d ≠ c) (hinj : TokensInjective s)
    (hexp : ∀ m, holds s d m = true → (s.clients d).beliefEnd < (s.masters m).expiry)
    (hvalid : s.now + delay < (s.clients d).beliefEnd) :
    holds (applyExtend false s c delay) d m = holds s d m := by
  have hnow := extend_now false s c delay
  have htok : ((applyExtend false s c delay).clients d).token = (s.clients d).token := by
    rw [extend_clients_other false s c d delay hne]
  have hmas := extend_masters_asis s c delay
  apply Bool.eq_iff_iff.mpr
  rw [holds_eq_true_iff, holds_eq_true_iff]
  constructor
  · rintro ⟨t, htokN, hownerN, hltN⟩
    rw [htok] at htokN
    by_cases hc : holds s c m = true
    · rw [hmas, renewHolders_at_of_holds s c m hc] at hownerN
      exact absurd (hinj d c t htokN hownerN) hne
    · have hcf : holds s c m = false := by
        cases h : holds s c m <;> simp_all
      rw [hmas, renewHolders_at_of_not_holds s c m hcf] at hownerN
      rw [hmas, renewHolders_at_of_not_holds s c m hcf, hnow] at hltN
      refine ⟨t, htokN, hownerN, ?_⟩
      omega
  · rintro ⟨t, htokOld, hownerOld, hltOld⟩
    by_cases hc : holds s c m = true
    · rw [holds_eq_true_iff] at hc
      rcases hc with ⟨t', ht', ho', _⟩
      have hsome : some t' = some t := by rw [← ho', ← hownerOld]
      have htEq : t' = t := Option.some.inj hsome
      have hct : (s.clients c).token = some t := by simpa [htEq] using ht'
      exact absurd (hinj d c t htokOld hct) hne
    · have hcf : holds s c m = false := by
        cases h : holds s c m <;> simp_all
      have hexp' := hexp m ((holds_eq_true_iff s d m).mpr ⟨t, htokOld, hownerOld, hltOld⟩)
      refine ⟨t, ?_, ?_, ?_⟩
      · rw [htok]; exact htokOld
      · rw [hmas, renewHolders_at_of_not_holds s c m hcf]; exact hownerOld
      · rw [hnow, hmas, renewHolders_at_of_not_holds s c m hcf]
        omega

end Redlock

namespace Redlock

/-! ## Release field facts -/

abbrev ReleaseOk (s : State) (c : ClientId) : Bool :=
  decide (Quorum ≤ (holders s c).length)

theorem release_now (s : State) (c : ClientId) (delay : Nat) :
    (applyRelease s c delay).now = s.now + delay := rfl

theorem release_token_self (s : State) (c : ClientId) (delay : Nat) :
    ((applyRelease s c delay).clients c).token = (s.clients c).token := by
  unfold applyRelease
  dsimp only
  rw [if_pos rfl]

theorem release_clients_other (s : State) (c d : ClientId) (delay : Nat) (h : d ≠ c) :
    (applyRelease s c delay).clients d = s.clients d := by
  unfold applyRelease
  dsimp only
  rw [if_neg h]

theorem release_beliefEnd_self_asis (s : State) (c : ClientId) (delay : Nat) :
    ((applyRelease s c delay).clients c).beliefEnd =
      if ReleaseOk s c = true then 0 else (s.clients c).beliefEnd := by
  unfold applyRelease
  dsimp only
  simp [ReleaseOk]

theorem release_masters (s : State) (c : ClientId) (delay : Nat) :
    (applyRelease s c delay).masters = (releaseToken s (s.clients c).token).masters := rfl

theorem releaseToken_masters_of_ne (s : State) (token : Option Nat) (m : MasterId)
    (h : token ≠ (s.masters m).owner) :
    (releaseToken s token).masters m = s.masters m := by
  unfold releaseToken
  dsimp only
  split <;> simp_all

theorem releaseToken_owner_some (s : State) (token : Option Nat) (m : MasterId) (t : Nat)
    (h : ((releaseToken s token).masters m).owner = some t) :
    (s.masters m).owner = some t := by
  cases token with
  | none => simpa [releaseToken] using h
  | some ct =>
    cases ho : (s.masters m).owner with
    | none => simpa [releaseToken, ho] using h
    | some o =>
      by_cases hco : ct = o
      · simp [releaseToken, ho, hco, emptyMaster] at h
      · simpa [releaseToken, ho, hco] using h

theorem releaseToken_owner_ne_self (s : State) (t : Nat) (m : MasterId) :
    ((releaseToken s (some t)).masters m).owner ≠ some t := by
  unfold releaseToken
  dsimp only
  cases ho : (s.masters m).owner with
  | none => simp [ho]
  | some o =>
    by_cases h : t = o
    · simp [ho, h, emptyMaster]
    · have h' : o ≠ t := by omega
      simp [ho, h, h']

theorem holds_applyRelease_other_of_valid (s : State) (c d : ClientId) (delay : Nat)
    (m : MasterId) (hne : d ≠ c) (hinj : TokensInjective s)
    (hexp : ∀ m, holds s d m = true → (s.clients d).beliefEnd < (s.masters m).expiry)
    (hvalid : s.now + delay < (s.clients d).beliefEnd) :
    holds (applyRelease s c delay) d m = holds s d m := by
  have hnow := release_now s c delay
  have htok : ((applyRelease s c delay).clients d).token = (s.clients d).token := by
    rw [release_clients_other s c d delay hne]
  have hmas := release_masters s c delay
  apply Bool.eq_iff_iff.mpr
  rw [holds_eq_true_iff, holds_eq_true_iff]
  constructor
  · rintro ⟨t, htokN, hownerN, hltN⟩
    rw [htok] at htokN
    rw [hmas] at hownerN
    have hownerOld : (s.masters m).owner = some t :=
      releaseToken_owner_some s (s.clients c).token m t hownerN
    have hct : (s.clients c).token ≠ some t := by
      intro hc
      exact hne (hinj d c t htokN hc)
    have hneTok : (s.clients c).token ≠ (s.masters m).owner := by
      intro hc
      exact hct (by simpa [hownerOld] using hc)
    have hexpEq : ((applyRelease s c delay).masters m).expiry = (s.masters m).expiry := by
      rw [hmas, releaseToken_masters_of_ne s (s.clients c).token m hneTok]
    refine ⟨t, htokN, hownerOld, ?_⟩
    rw [hnow] at hltN
    rw [hexpEq] at hltN
    omega
  · rintro ⟨t, htokOld, hownerOld, hltOld⟩
    have hneTok : (s.clients c).token ≠ (s.masters m).owner := by
      intro hc
      apply hne
      rw [hownerOld] at hc
      exact hinj d c t htokOld hc
    have hexp' := hexp m ((holds_eq_true_iff s d m).mpr ⟨t, htokOld, hownerOld, hltOld⟩)
    refine ⟨t, ?_, ?_, ?_⟩
    · rw [htok]; exact htokOld
    · rw [hmas, releaseToken_masters_of_ne s (s.clients c).token m hneTok]
      exact hownerOld
    · rw [hnow, hmas, releaseToken_masters_of_ne s (s.clients c).token m hneTok]
      omega

theorem not_valid_applyRelease_self (s : State) (hInv : Inv s) (c : ClientId) (delay : Nat) :
    ¬ Valid (applyRelease s c delay) c := by
  intro hv
  rw [Valid] at hv
  have hnow := release_now s c delay
  have hbel := release_beliefEnd_self_asis s c delay
  by_cases hok : ReleaseOk s c = true
  · rw [hbel, hok] at hv
    simp at hv
  · have hokf : ReleaseOk s c = false := by
      cases h : ReleaseOk s c <;> simp_all
    rw [hbel, hokf] at hv
    simp at hv
    have hval : Valid s c := by unfold Valid; rw [hnow] at hv; omega
    have hq := hInv.quorum c hval
    unfold ReleaseOk at hokf
    rw [decide_eq_false_iff_not] at hokf
    exact hokf hq

/-! ## Advance -/

theorem advance_now (s : State) (delay : Nat) :
    (applyAdvance s delay).now = s.now + delay := rfl

theorem holds_applyAdvance_of_valid (s : State) (delay : Nat) (c : ClientId) (m : MasterId)
    (hvalid : s.now + delay < (s.clients c).beliefEnd)
    (hexp : ∀ m, holds s c m = true → (s.clients c).beliefEnd < (s.masters m).expiry) :
    holds (applyAdvance s delay) c m = holds s c m := by
  have hnow := advance_now s delay
  apply Bool.eq_iff_iff.mpr
  rw [holds_eq_true_iff, holds_eq_true_iff]
  constructor
  · rintro ⟨t, htok, howner, hlt⟩
    refine ⟨t, htok, howner, ?_⟩
    have hlt' : s.now + delay < (s.masters m).expiry := by
      simpa [applyAdvance, hnow] using hlt
    omega
  · rintro ⟨t, htok, howner, hlt⟩
    have hexp' := hexp m ((holds_eq_true_iff s c m).mpr ⟨t, htok, howner, hlt⟩)
    refine ⟨t, htok, howner, ?_⟩
    simp only [applyAdvance]
    omega

end Redlock

namespace Redlock

theorem acquire_not_chosen_of_holds_other (s : State) (c d : ClientId) (delay : Nat)
    (chosen : List MasterId) (m : MasterId) (hne : d ≠ c) (hInv : Inv s)
    (hhold : holds (applyAcquire s c delay chosen) d m = true) :
    chosen.contains m = false := by
  cases hc : chosen.contains m with
  | false => rfl
  | true =>
    rw [holds_eq_true_iff] at hhold
    rcases hhold with ⟨t, htok, howner, hlt⟩
    rw [acquire_token_other s c d delay chosen hne] at htok
    by_cases hok : AcquireOk s delay chosen = true
    · rw [acquire_masters_ok s c delay chosen hok m] at howner
      simp only [hc, if_true] at howner
      have ht : s.nextToken = t := Option.some.inj howner
      have hlt' := hInv.clientsBelow d t htok
      omega
    · have hokf : AcquireOk s delay chosen = false := by
        cases h : AcquireOk s delay chosen <;> simp_all
      rw [acquire_masters_not_ok s c delay chosen hokf hInv.ownersBelow m] at howner
      simp only [hc, if_true] at howner
      simp [emptyMaster] at howner

theorem inv_init : Inv initState := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro c hv
    unfold Valid at hv
    simp [initState, emptyClient] at hv
  · intro c m hv
    unfold Valid at hv
    simp [initState, emptyClient] at hv
  · intro c t h
    simp [initState, emptyClient] at h
  · intro m o h
    simp [initState, emptyMaster] at h
  · intro c c' t hc hc'
    simp [initState, emptyClient] at hc
  · intro c
    simp [initState, emptyClient]

theorem inv_step_acquire (s : State) (hInv : Inv s) (c : ClientId) (delay : Nat)
    (chosen : List MasterId) (hsub : listSubset chosen (freeMasters s) = true)
    (hnd : chosen.Nodup) : Inv (applyAcquire s c delay chosen) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · -- quorum
    intro d hvd
    by_cases hdc : d = c
    · subst d
      have hok : AcquireOk s delay chosen = true := by
        by_cases hok : AcquireOk s delay chosen = true
        · exact hok
        · have hokf : AcquireOk s delay chosen = false := by
            cases h : AcquireOk s delay chosen <;> simp_all
          unfold Valid at hvd
          rw [acquire_beliefEnd_self, hokf] at hvd
          simp at hvd
      have hP : Quorum ≤ chosen.length ∧ s.now + delay < s.now + ValidityWindow :=
        decide_eq_true_eq.mp hok
      have hsubHold : chosen ⊆ holders (applyAcquire s c delay chosen) c := by
        intro m hm
        unfold holders
        rw [List.mem_filter]
        refine ⟨List.mem_finRange m, ?_⟩
        rw [holds_applyAcquire_self_of_ok s c delay chosen hok hInv.ownersBelow m]
        exact List.contains_iff_mem.mpr hm
      exact Nat.le_trans hP.1 (List.Nodup.length_le_of_subset hnd hsubHold)
    · have hvd' : s.now + delay < (s.clients d).beliefEnd := by
        have hvd1 : (applyAcquire s c delay chosen).now <
            ((applyAcquire s c delay chosen).clients d).beliefEnd := hvd
        rw [acquire_now, acquire_clients_other s c d delay chosen hdc] at hvd1
        exact hvd1
      have hvalidOld : Valid s d := by unfold Valid; omega
      have hEq : holders (applyAcquire s c delay chosen) d = holders s d := by
        unfold holders
        exact List.filter_congr (fun m _ =>
          holds_applyAcquire_other_of_valid s c d delay chosen m hdc hInv hsub hvd')
      rw [hEq]
      exact hInv.quorum d hvalidOld
  · -- expiry
    intro d m hvd hhold
    by_cases hdc : d = c
    · subst d
      have hok : AcquireOk s delay chosen = true := by
        by_cases hok : AcquireOk s delay chosen = true
        · exact hok
        · have hokf : AcquireOk s delay chosen = false := by
            cases h : AcquireOk s delay chosen <;> simp_all
          unfold Valid at hvd
          rw [acquire_beliefEnd_self, hokf] at hvd
          simp at hvd
      have hmem : chosen.contains m = true :=
        (holds_applyAcquire_self_of_ok s c delay chosen hok hInv.ownersBelow m).mp hhold
      have hexp : ((applyAcquire s c delay chosen).masters m).expiry =
          s.now + AutoReleaseTime := by
        rw [acquire_masters_ok s c delay chosen hok m]
        simp only [hmem, if_true]
      have hbel : ((applyAcquire s c delay chosen).clients c).beliefEnd =
          s.now + ValidityWindow := by
        rw [acquire_beliefEnd_self, hok]
        simp
      rw [hbel, hexp]
      have hVA : ValidityWindow < AutoReleaseTime := by decide
      omega
    · have hvd' : s.now + delay < (s.clients d).beliefEnd := by
        have hvd1 : (applyAcquire s c delay chosen).now <
            ((applyAcquire s c delay chosen).clients d).beliefEnd := hvd
        rw [acquire_now, acquire_clients_other s c d delay chosen hdc] at hvd1
        exact hvd1
      have hvalidOld : Valid s d := by unfold Valid; omega
      have hEq : holds (applyAcquire s c delay chosen) d m = holds s d m :=
        holds_applyAcquire_other_of_valid s c d delay chosen m hdc hInv hsub hvd'
      have hholdOld : holds s d m = true := by rw [hEq] at hhold; exact hhold
      have hexpOld := hInv.expiry d m hvalidOld hholdOld
      have hnotChosen : chosen.contains m = false :=
        acquire_not_chosen_of_holds_other s c d delay chosen m hdc hInv hhold
      have hbel : ((applyAcquire s c delay chosen).clients d).beliefEnd =
          (s.clients d).beliefEnd := by
        rw [acquire_clients_other s c d delay chosen hdc]
      have hexp : ((applyAcquire s c delay chosen).masters m).expiry =
          (s.masters m).expiry := by
        rw [acquire_masters_not_chosen s c delay chosen hInv.ownersBelow m hnotChosen]
      rw [hbel, hexp]
      exact hexpOld
  · -- clientsBelow
    intro d t htok
    by_cases hdc : d = c
    · subst d
      rw [acquire_token_self] at htok
      have ht : s.nextToken = t := Option.some.inj htok
      rw [acquire_nextToken]
      omega
    · rw [acquire_token_other s c d delay chosen hdc] at htok
      have hlt := hInv.clientsBelow d t htok
      rw [acquire_nextToken]
      omega
  · -- ownersBelow
    intro m o ho
    by_cases hok : AcquireOk s delay chosen = true
    · rw [acquire_masters_ok s c delay chosen hok m] at ho
      by_cases hc : chosen.contains m = true
      · simp only [hc, if_true] at ho
        have ht : s.nextToken = o := Option.some.inj ho
        rw [acquire_nextToken]
        omega
      · simp only [hc, Bool.false_eq_true, if_false] at ho
        have hlt := hInv.ownersBelow m o ho
        rw [acquire_nextToken]
        omega
    · have hokf : AcquireOk s delay chosen = false := by
        cases h : AcquireOk s delay chosen <;> simp_all
      rw [acquire_masters_not_ok s c delay chosen hokf hInv.ownersBelow m] at ho
      by_cases hc : chosen.contains m = true
      · simp only [hc, if_true] at ho
        simp [emptyMaster] at ho
      · simp only [hc, Bool.false_eq_true, if_false] at ho
        have hlt := hInv.ownersBelow m o ho
        rw [acquire_nextToken]
        omega
  · -- injective
    intro d e t hd he
    by_cases hdc : d = c
    · subst d
      have hnew : s.nextToken = t := by
        rw [acquire_token_self] at hd
        exact Option.some.inj hd
      by_cases hec : e = c
      · subst e; rfl
      · rw [acquire_token_other s c e delay chosen hec] at he
        have hlt := hInv.clientsBelow e t he
        exfalso
        omega
    · rw [acquire_token_other s c d delay chosen hdc] at hd
      by_cases hec : e = c
      · subst e
        rw [acquire_token_self] at he
        have hnew : s.nextToken = t := Option.some.inj he
        have hlt := hInv.clientsBelow d t hd
        exfalso
        omega
      · rw [acquire_token_other s c e delay chosen hec] at he
        exact hInv.injective d e t hd he
  · -- beliefLe
    intro d
    by_cases hdc : d = c
    · subst d
      rw [acquire_beliefEnd_self]
      by_cases hok : AcquireOk s delay chosen = true
      · rw [if_pos hok]
        rw [acquire_now]
        omega
      · have hokf : AcquireOk s delay chosen = false := by
          cases h : AcquireOk s delay chosen <;> simp_all
        rw [if_neg (by simp [hokf])]
        omega
    · rw [acquire_clients_other s c d delay chosen hdc]
      have hbl := hInv.beliefLe d
      rw [acquire_now]
      omega

end Redlock

namespace Redlock

theorem inv_step_extend (s : State) (hInv : Inv s) (c : ClientId) (delay : Nat)
    (hext : (s.clients c).extensions < NumExtensions) :
    Inv (applyExtend false s c delay) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · -- quorum
    intro d hvd
    by_cases hdc : d = c
    · subst d
      unfold Valid at hvd
      rw [extend_beliefEnd_self_asis] at hvd
      by_cases hok : ExtendOk s c = true
      · have hfinish : s.now + delay < s.now + ValidityWindow := by
          rw [if_pos hok] at hvd
          exact hvd
        have hq : Quorum ≤ (holders s c).length := decide_eq_true_eq.mp hok
        have hEq : holders (applyExtend false s c delay) c = holders s c := by
          unfold holders
          exact List.filter_congr (fun m _ =>
            holds_applyExtend_self_of_valid s c delay m hfinish)
        rw [hEq]
        exact hq
      · have hokf : ExtendOk s c = false := by
          cases h : ExtendOk s c <;> simp_all
        rw [if_neg (by simp [hokf])] at hvd
        have hvalidOld : Valid s c := by unfold Valid; rw [extend_now] at hvd; omega
        have hq := hInv.quorum c hvalidOld
        unfold ExtendOk at hokf
        rw [decide_eq_false_iff_not] at hokf
        exact absurd hq hokf
    · have hvd' : s.now + delay < (s.clients d).beliefEnd := by
        unfold Valid at hvd
        rw [extend_now, extend_clients_other false s c d delay hdc] at hvd
        exact hvd
      have hvalidOld : Valid s d := by unfold Valid; omega
      have hEq : holders (applyExtend false s c delay) d = holders s d := by
        unfold holders
        exact List.filter_congr (fun m _ =>
          holds_applyExtend_other_of_valid s c d delay m hdc hInv.injective
            (fun m hh => hInv.expiry d m hvalidOld hh) hvd')
      rw [hEq]
      exact hInv.quorum d hvalidOld
  · -- expiry
    intro d m hvd hhold
    by_cases hdc : d = c
    · subst d
      unfold Valid at hvd
      rw [extend_beliefEnd_self_asis] at hvd
      by_cases hok : ExtendOk s c = true
      · have hfinish : s.now + delay < s.now + ValidityWindow := by
          rw [if_pos hok] at hvd
          exact hvd
        have hpoint : holds (applyExtend false s c delay) c m = holds s c m :=
          holds_applyExtend_self_of_valid s c delay m hfinish
        have holdOld : holds s c m = true := by rw [hpoint] at hhold; exact hhold
        have hexp : ((applyExtend false s c delay).masters m).expiry =
            s.now + AutoReleaseTime := by
          rw [extend_masters_asis, renewHolders_at_of_holds s c m holdOld]
        have hbel : ((applyExtend false s c delay).clients c).beliefEnd =
            s.now + ValidityWindow := by
          rw [extend_beliefEnd_self_asis, if_pos hok]
        rw [hbel, hexp]
        have hVA : ValidityWindow < AutoReleaseTime := by decide
        omega
      · have hokf : ExtendOk s c = false := by
          cases h : ExtendOk s c <;> simp_all
        rw [if_neg (by simp [hokf])] at hvd
        have hvalidOld : Valid s c := by unfold Valid; rw [extend_now] at hvd; omega
        have hq := hInv.quorum c hvalidOld
        unfold ExtendOk at hokf
        rw [decide_eq_false_iff_not] at hokf
        exact absurd hq hokf
    · have hvd' : s.now + delay < (s.clients d).beliefEnd := by
        unfold Valid at hvd
        rw [extend_now, extend_clients_other false s c d delay hdc] at hvd
        exact hvd
      have hvalidOld : Valid s d := by unfold Valid; omega
      have hcf : holds s c m = false := by
        by_cases hc : holds s c m = true
        · exfalso
          rw [holds_eq_true_iff] at hc hhold
          rcases hc with ⟨tc, htokc, hownc, _⟩
          rcases hhold with ⟨td, htokd, hownd, _⟩
          rw [extend_clients_other false s c d delay hdc] at htokd
          rw [extend_masters_asis, renewHolders_at_of_holds s c m (by
            rw [holds_eq_true_iff]; exact ⟨tc, htokc, hownc, by omega⟩)] at hownd
          exact hdc (hInv.injective d c td htokd hownd)
        · cases h : holds s c m <;> simp_all
      have hexp : ((applyExtend false s c delay).masters m).expiry =
          (s.masters m).expiry := by
        rw [extend_masters_asis, renewHolders_at_of_not_holds s c m hcf]
      have hbel : ((applyExtend false s c delay).clients d).beliefEnd =
          (s.clients d).beliefEnd := extend_beliefEnd_other false s c d delay hdc
      have hpoint : holds (applyExtend false s c delay) d m = holds s d m :=
        holds_applyExtend_other_of_valid s c d delay m hdc hInv.injective
          (fun m hh => hInv.expiry d m hvalidOld hh) hvd'
      have holdOld : holds s d m = true := by rw [hpoint] at hhold; exact hhold
      have hexpOld := hInv.expiry d m hvalidOld holdOld
      rw [hbel, hexp]
      exact hexpOld
  · -- clientsBelow
    intro d t htok
    by_cases hdc : d = c
    · subst d
      rw [extend_token_self] at htok
      exact hInv.clientsBelow c t htok
    · rw [extend_clients_other false s c d delay hdc] at htok
      exact hInv.clientsBelow d t htok
  · -- ownersBelow
    intro m o ho
    rw [extend_masters_asis, renewHolders_at] at ho
    by_cases hc : holds s c m = true
    · rw [if_pos hc] at ho
      rw [holds_eq_true_iff] at hc
      rcases hc with ⟨t, htok, howner, _⟩
      have hto : t = o := by rw [htok] at ho; exact Option.some.inj ho
      exact hInv.ownersBelow m o (by rw [howner, hto])
    · have hcf : holds s c m = false := by
        cases h : holds s c m <;> simp_all
      rw [if_neg (by simp [hcf])] at ho
      exact hInv.ownersBelow m o ho
  · -- injective
    intro d e t hd he
    by_cases hdc : d = c
    · subst d
      rw [extend_token_self] at hd
      by_cases hec : e = c
      · subst e; rfl
      · rw [extend_clients_other false s c e delay hec] at he
        exact hInv.injective c e t hd he
    · rw [extend_clients_other false s c d delay hdc] at hd
      by_cases hec : e = c
      · subst e
        rw [extend_token_self] at he
        exact hInv.injective d c t hd he
      · rw [extend_clients_other false s c e delay hec] at he
        exact hInv.injective d e t hd he
  · -- beliefLe
    intro d
    by_cases hdc : d = c
    · subst d
      rw [extend_beliefEnd_self_asis]
      by_cases hok : ExtendOk s c = true
      · rw [if_pos hok]
        rw [extend_now]
        omega
      · have hokf : ExtendOk s c = false := by
          cases h : ExtendOk s c <;> simp_all
        rw [if_neg (by simp [hokf])]
        have hbl := hInv.beliefLe c
        rw [extend_now]
        omega
    · rw [extend_beliefEnd_other false s c d delay hdc]
      have hbl := hInv.beliefLe d
      rw [extend_now]
      omega

end Redlock

namespace Redlock

theorem inv_step_release (s : State) (hInv : Inv s) (c : ClientId) (delay : Nat) :
    Inv (applyRelease s c delay) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · -- quorum
    intro d hvd
    by_cases hdc : d = c
    · subst d
      exact absurd hvd (not_valid_applyRelease_self s hInv c delay)
    · have hvd' : s.now + delay < (s.clients d).beliefEnd := by
        unfold Valid at hvd
        rw [release_now, release_clients_other s c d delay hdc] at hvd
        exact hvd
      have hvalidOld : Valid s d := by unfold Valid; omega
      have hEq : holders (applyRelease s c delay) d = holders s d := by
        unfold holders
        exact List.filter_congr (fun m _ =>
          holds_applyRelease_other_of_valid s c d delay m hdc hInv.injective
            (fun m hh => hInv.expiry d m hvalidOld hh) hvd')
      rw [hEq]
      exact hInv.quorum d hvalidOld
  · -- expiry
    intro d m hvd hhold
    by_cases hdc : d = c
    · subst d
      exact absurd hvd (not_valid_applyRelease_self s hInv c delay)
    · have hvd' : s.now + delay < (s.clients d).beliefEnd := by
        unfold Valid at hvd
        rw [release_now, release_clients_other s c d delay hdc] at hvd
        exact hvd
      have hvalidOld : Valid s d := by unfold Valid; omega
      have hpoint : holds (applyRelease s c delay) d m = holds s d m :=
        holds_applyRelease_other_of_valid s c d delay m hdc hInv.injective
          (fun m hh => hInv.expiry d m hvalidOld hh) hvd'
      have holdOld : holds s d m = true := by rw [hpoint] at hhold; exact hhold
      have hexpOld := hInv.expiry d m hvalidOld holdOld
      have hneTok : (s.clients c).token ≠ (s.masters m).owner := by
        rw [holds_eq_true_iff] at holdOld
        rcases holdOld with ⟨t, htok, howner, _⟩
        intro hc
        rw [howner] at hc
        exact hdc (hInv.injective d c t htok hc)
      have hexp : ((applyRelease s c delay).masters m).expiry = (s.masters m).expiry := by
        rw [release_masters, releaseToken_masters_of_ne s (s.clients c).token m hneTok]
      have hbel : ((applyRelease s c delay).clients d).beliefEnd = (s.clients d).beliefEnd :=
        congrArg ClientState.beliefEnd (release_clients_other s c d delay hdc)
      rw [hbel, hexp]
      exact hexpOld
  · -- clientsBelow
    intro d t htok
    by_cases hdc : d = c
    · subst d
      rw [release_token_self] at htok
      exact hInv.clientsBelow c t htok
    · rw [release_clients_other s c d delay hdc] at htok
      exact hInv.clientsBelow d t htok
  · -- ownersBelow
    intro m o ho
    rw [release_masters] at ho
    exact hInv.ownersBelow m o (releaseToken_owner_some s (s.clients c).token m o ho)
  · -- injective
    intro d e t hd he
    by_cases hdc : d = c
    · subst d
      rw [release_token_self] at hd
      by_cases hec : e = c
      · subst e; rfl
      · rw [release_clients_other s c e delay hec] at he
        exact hInv.injective c e t hd he
    · rw [release_clients_other s c d delay hdc] at hd
      by_cases hec : e = c
      · subst e
        rw [release_token_self] at he
        exact hInv.injective d c t hd he
      · rw [release_clients_other s c e delay hec] at he
        exact hInv.injective d e t hd he
  · -- beliefLe
    intro d
    by_cases hdc : d = c
    · subst d
      rw [release_beliefEnd_self_asis]
      by_cases hok : ReleaseOk s c = true
      · rw [if_pos hok]
        rw [release_now]
        omega
      · have hokf : ReleaseOk s c = false := by
          cases h : ReleaseOk s c <;> simp_all
        rw [if_neg (by simp [hokf])]
        have hbl := hInv.beliefLe c
        rw [release_now]
        omega
    · rw [release_clients_other s c d delay hdc]
      have hbl := hInv.beliefLe d
      rw [release_now]
      omega

theorem inv_step_advance (s : State) (hInv : Inv s) (delay : Nat) :
    Inv (applyAdvance s delay) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro d hvd
    unfold Valid at hvd
    rw [advance_now] at hvd
    have hvd' : s.now + delay < (s.clients d).beliefEnd := by
      simpa [applyAdvance] using hvd
    have hvalidOld : Valid s d := by unfold Valid; omega
    have hEq : holders (applyAdvance s delay) d = holders s d := by
      unfold holders
      exact List.filter_congr (fun m _ =>
        holds_applyAdvance_of_valid s delay d m hvd'
          (fun m hh => hInv.expiry d m hvalidOld hh))
    rw [hEq]
    exact hInv.quorum d hvalidOld
  · intro d m hvd hhold
    unfold Valid at hvd
    rw [advance_now] at hvd
    have hvd' : s.now + delay < (s.clients d).beliefEnd := by
      simpa [applyAdvance] using hvd
    have hvalidOld : Valid s d := by unfold Valid; omega
    have hpoint : holds (applyAdvance s delay) d m = holds s d m :=
      holds_applyAdvance_of_valid s delay d m hvd'
        (fun m hh => hInv.expiry d m hvalidOld hh)
    have holdOld : holds s d m = true := by rw [hpoint] at hhold; exact hhold
    have hexpOld := hInv.expiry d m hvalidOld holdOld
    simpa [applyAdvance] using hexpOld
  · intro d t htok
    simpa [applyAdvance] using hInv.clientsBelow d t htok
  · intro m o ho
    simpa [applyAdvance] using hInv.ownersBelow m o ho
  · intro d e t hd he
    exact hInv.injective d e t (by simpa [applyAdvance] using hd) (by simpa [applyAdvance] using he)
  · intro d
    have hbl := hInv.beliefLe d
    have hbl' : ((applyAdvance s delay).clients d).beliefEnd ≤ s.now + ValidityWindow := by
      simpa [applyAdvance] using hbl
    rw [advance_now]
    omega

end Redlock

namespace Redlock

theorem countP_add_countP_le_of_disjoint {α : Type} (l : List α) (p q : α → Bool)
    (h : ∀ a, a ∈ l → p a = true → q a = true → False) :
    List.countP p l + List.countP q l ≤ l.length := by
  induction l with
  | nil => simp
  | cons a t ih =>
    have ih' := ih (fun x hx => h x (List.mem_cons_of_mem a hx))
    by_cases hp : p a = true
    · have hq : ¬ q a = true := fun hq => h a (by simp) hp hq
      rw [List.countP_cons_of_pos hp, List.countP_cons_of_neg hq]
      simp only [List.length_cons]
      omega
    · by_cases hq : q a = true
      · rw [List.countP_cons_of_neg hp, List.countP_cons_of_pos hq]
        simp only [List.length_cons]
        omega
      · rw [List.countP_cons_of_neg hp, List.countP_cons_of_neg hq]
        simp only [List.length_cons]
        omega

theorem holders_length_eq_countP (s : State) (c : ClientId) :
    (holders s c).length =
      List.countP (fun m => holds s c m) (List.finRange NumMasters) := by
  unfold holders
  exact (List.countP_eq_length_filter).symm

theorem holders_pair_length_le (s : State) (c c' : ClientId) (hne : c ≠ c')
    (hinj : TokensInjective s) :
    (holders s c).length + (holders s c').length ≤ NumMasters := by
  rw [holders_length_eq_countP s c, holders_length_eq_countP s c']
  have hdisj : ∀ m, m ∈ List.finRange NumMasters →
      holds s c m = true → holds s c' m = true → False := by
    intro m _ hc hc'
    rw [holds_eq_true_iff] at hc hc'
    rcases hc with ⟨t, ht, ho, _⟩
    rcases hc' with ⟨t', ht', ho', _⟩
    rw [ho] at ho'
    have htt : t = t' := Option.some.inj ho'
    have hct' : (s.clients c').token = some t := by simpa [htt] using ht'
    exact hne (hinj c c' t ht hct')
  have hle := countP_add_countP_le_of_disjoint (List.finRange NumMasters)
    (fun m => holds s c m) (fun m => holds s c' m) hdisj
  simpa [List.length_finRange] using hle

theorem no_two_valid_of_inv (s : State) (h : Inv s) :
    ¬ ∃ c c', c ≠ c' ∧ Valid s c ∧ Valid s c' := by
  rintro ⟨c, c', hne, hc, hc'⟩
  have hq := h.quorum c hc
  have hq' := h.quorum c' hc'
  have hle := holders_pair_length_le s c c' hne h.injective
  have hQ : Quorum = 3 := by decide
  have hN : NumMasters = 5 := by decide
  rw [hQ] at hq hq'
  rw [hN] at hle
  omega

theorem atMostOne_of_inv (s : State) (h : Inv s) : AtMostOneValidHolder s := by
  have hnot := no_two_valid_of_inv s h
  unfold AtMostOneValidHolder validHolderCount
  rw [show List.finRange NumClients = [(0 : ClientId), (1 : ClientId)] by decide]
  by_cases h0 : Valid s 0
  · by_cases h1 : Valid s 1
    · exfalso
      exact hnot ⟨0, 1, by decide, h0, h1⟩
    · unfold Valid at h0 h1
      simp [h0, h1]
  · by_cases h1 : Valid s 1
    · unfold Valid at h0 h1
      simp [h0, h1]
    · unfold Valid at h0 h1
      simp [h0, h1]

theorem inv_step (s s' : State) (hInv : Inv s) (hstep : StepAsIs s s') : Inv s' := by
  rcases hstep with ⟨c, delay, chosen, hdel, hnd, hsub, hs⟩
    | ⟨c, delay, hdel, hext, hs⟩
    | ⟨c, delay, hdel, hs⟩
    | ⟨delay, hpos, hdel, hs⟩
  · rw [hs]
    exact inv_step_acquire s hInv c delay chosen hsub hnd
  · rw [hs]
    exact inv_step_extend s hInv c delay hext
  · rw [hs]
    exact inv_step_release s hInv c delay
  · rw [hs]
    exact inv_step_advance s hInv delay

theorem inv_reachable (s : State) (h : ReachableAsIs s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step _ hstep ih => exact inv_step _ _ ih hstep

end Redlock
