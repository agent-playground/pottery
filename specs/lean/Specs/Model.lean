/-
Lean model of the synchronous Redlock state machine.

Scope: the G1-confirmed rules transcribed in `specs/lean/RULES.md`.
The model keeps the decisions that can change mutual exclusion or the
extend contract: tokens, quorum, lease expiry, monotonic time, and the
as-is vs. INV-6 `extend` behaviour.  It deliberately drops retries,
backoff, logging, Redis exception plumbing, and `locked()`.

Time is integer milliseconds.  `now` is the client's monotonic clock
(`pottery/timer.py:106,123-127`).  A master key is live while
`now < expiry`; this is the model of the Redis PTTL (ENV-5).

Only Lean core is used: finite master/client sets are `List (Fin n)`
built with `List.finRange`, not `Finset` (which is not in core).
-/

namespace Redlock

/-! ## Fixed instance

The values below are the `as_is` instance of the Quint model
(`specs/quint/instances.qnt`): five masters (README.md:331-335), a 200 ms
lease (README.md:327), drift = 200*0.01 + 2 ms = 4 ms
(`pottery/redlock.py:315-316`), and two clients (mutual exclusion is
pairwise).  The program itself accepts any positive number of masters
and any float `auto_release_time`; fixing one instance is what makes the
counterexample witnesses concrete. -/

abbrev NumMasters : Nat := 5
abbrev NumClients : Nat := 2
abbrev AutoReleaseTime : Nat := 200
abbrev Drift : Nat := 4
abbrev ValidityWindow : Nat := AutoReleaseTime - Drift
abbrev MaxOpDelay : Nat := 205
abbrev Quorum : Nat := NumMasters / 2 + 1
abbrev NumExtensions : Nat := 3

abbrev MasterId := Fin NumMasters
abbrev ClientId := Fin NumClients

/-- A Redis master's single lock key.  `owner = none` means "no key".
`expiry` is the absolute monotonic-ms instant at which the key disappears. -/
structure MasterState where
  owner : Option Nat
  expiry : Nat
  deriving DecidableEq, Repr

/-- The per-client state that the model needs.  `token` is the UUID
(`pottery/redlock.py:322`), `beliefEnd` is the A1(b) end of the interval
in which the client considers itself a valid holder
(`pottery/redlock.py:343-348`), and the `last*` fields mirror the values
recorded in the Quint traces. -/
structure ClientState where
  token : Option Nat
  extensions : Nat
  beliefEnd : Nat
  lastAcquireStart : Nat
  lastAcquireEnd : Nat
  lastAcquireOk : Bool
  lastAcquireSets : Nat
  lastExtendStart : Nat
  lastExtendEnd : Nat
  lastExtendOk : Bool
  lastExtendRenewals : Nat
  lastReleaseOk : Bool
  lastReleaseDels : Nat
  deriving DecidableEq, Repr

structure State where
  now : Nat
  masters : MasterId → MasterState
  clients : ClientId → ClientState
  nextToken : Nat

def emptyMaster : MasterState :=
  { owner := none, expiry := 0 }

def emptyClient : ClientState :=
  { token := none
    extensions := 0
    beliefEnd := 0
    lastAcquireStart := 0
    lastAcquireEnd := 0
    lastAcquireOk := false
    lastAcquireSets := 0
    lastExtendStart := 0
    lastExtendEnd := 0
    lastExtendOk := false
    lastExtendRenewals := 0
    lastReleaseOk := false
    lastReleaseDels := 0 }

def initState : State :=
  { now := 0
    masters := fun _ => emptyMaster
    clients := fun _ => emptyClient
    nextToken := 1 }

/-! ## Predicates and helpers -/

/-- A key is live when it has an owner and its PTTL has not elapsed
(`pottery/redlock.py:282`, ENV-5). -/
def live (m : MasterState) (t : Nat) : Bool :=
  m.owner.isSome && decide (t < m.expiry)

/-- `m` currently stores the same token as client `c` and the key is live.
This is the model of the Lua scripts' `GET == ARGV[1] and pttl > 0`
(`pottery/redlock.py:113-148`). -/
def holds (s : State) (c : ClientId) (m : MasterId) : Bool :=
  match (s.clients c).token, (s.masters m).owner with
  | some t, some o => (t == o) && decide (s.now < (s.masters m).expiry)
  | _, _ => false

def holders (s : State) (c : ClientId) : List MasterId :=
  (List.finRange NumMasters).filter (fun m => holds s c m)

def freeMasters (s : State) : List MasterId :=
  (List.finRange NumMasters).filter (fun m => !live (s.masters m) s.now)

def listSubset (a b : List MasterId) : Bool :=
  a.all (fun x => b.contains x)

/-- The Lua release script deletes only a token-matching key
(`pottery/redlock.py:142-148`); expiry does not matter for `DEL`. -/
def releaseToken (s : State) (token : Option Nat) : State :=
  { s with
    masters := fun m =>
      match token, (s.masters m).owner with
      | some t, some o => if t = o then emptyMaster else s.masters m
      | _, _ => s.masters m }

/-- The Lua extend script PEXPIREs only a live token-matching key
(`pottery/redlock.py:128-134`).  It never re-`SET`s a node that lost the
key (G1 A4 / OUT-3). -/
def renewHolders (s : State) (c : ClientId) : State :=
  { s with
    masters := fun m =>
      if holds s c m then
        { owner := (s.clients c).token, expiry := s.now + AutoReleaseTime }
      else s.masters m }

/-! ## Transitions

Each operation has a `delay`; its master-side effects are placed at the
operation start and it completes at `start + delay`.  This is the
timing abstraction recorded as A-1 in `MODEL-MAP.md`: it is one
admissible schedule (the command executes early and its response is
observed later), not a proof that the real network produces it.
-/

/-- ACT-1..ACT-4 / INV-2.  `chosen` is the set of masters whose
`SET ... NX` succeeded.  The synchronous client may return as soon as a
quorum is collected, so `chosen` can be any subset of the free masters
(`pottery/redlock.py:325-348`). -/
def applyAcquire (s : State) (c : ClientId) (delay : Nat)
    (chosen : List MasterId) : State :=
  let finish := s.now + delay
  let token := s.nextToken
  let ok : Bool :=
    decide (Quorum ≤ chosen.length ∧ finish < s.now + ValidityWindow)
  let acquired := fun m =>
    if chosen.contains m then
      { owner := some token, expiry := s.now + AutoReleaseTime }
    else s.masters m
  let withKeys : State := { s with masters := acquired }
  let finalMasters :=
    if ok then acquired else (releaseToken withKeys (some token)).masters
  let cl := s.clients c
  let cl' : ClientState :=
    { cl with
      token := some token
      extensions := 0
      beliefEnd := if ok then s.now + ValidityWindow else 0
      lastAcquireStart := s.now
      lastAcquireEnd := finish
      lastAcquireOk := ok
      lastAcquireSets := chosen.length
      lastExtendStart := 0
      lastExtendEnd := 0
      lastExtendOk := false
      lastExtendRenewals := 0
      lastReleaseOk := false
      lastReleaseDels := 0 }
  { s with
    now := finish
    masters := finalMasters
    clients := fun c' => if c' = c then cl' else s.clients c'
    nextToken := s.nextToken + 1 }

/-- ACT-7..ACT-10 / INV-6.  `strict = false` is the as-is code: quorum
alone succeeds, there is no completion-time validity check, and a late
or failed extend is not compensated (`pottery/redlock.py:526-553`).
`strict = true` is G1 A3's RX: success also requires the A3
completion-time window, and every failure releases all nodes that still
hold this token. -/
def applyExtend (strict : Bool) (s : State) (c : ClientId)
    (delay : Nat) : State :=
  let cl := s.clients c
  let hs := holders s c
  let renewals := hs.length
  let finish := s.now + delay
  let quorumOk : Bool := decide (Quorum ≤ renewals)
  let valid : Bool := decide (finish < s.now + ValidityWindow)
  let ok : Bool := if strict then (quorumOk && valid) else quorumOk
  let renewed := renewHolders s c
  let compensated := releaseToken renewed (s.clients c).token
  let finalMasters :=
    if ok then renewed.masters
    else if strict then compensated.masters
    else renewed.masters
  let cl' : ClientState :=
    { cl with
      lastExtendStart := s.now
      lastExtendEnd := finish
      lastExtendOk := ok
      lastExtendRenewals := renewals
      extensions := if ok then cl.extensions + 1 else cl.extensions
      beliefEnd :=
        if ok then s.now + ValidityWindow
        else if strict then 0
        else cl.beliefEnd }
  { s with
    now := finish
    masters := finalMasters
    clients := fun c' => if c' = c then cl' else s.clients c' }

/-- ACT-11 / INV-8.  The script deletes every matching key, and only a
strict majority of deletions is reported as success
(`pottery/redlock.py:573-599`). -/
def applyRelease (s : State) (c : ClientId) (delay : Nat) : State :=
  let cl := s.clients c
  let dels := (holders s c).length
  let ok : Bool := decide (Quorum ≤ dels)
  let after := releaseToken s (s.clients c).token
  let cl' : ClientState :=
    { cl with
      lastReleaseOk := ok
      lastReleaseDels := dels
      beliefEnd := if ok then 0 else cl.beliefEnd }
  { s with
    now := s.now + delay
    masters := after.masters
    clients := fun c' => if c' = c then cl' else s.clients c' }

/-- ACT-13 / ENV-5: the environment advances the monotonic clock. -/
def applyAdvance (s : State) (delay : Nat) : State :=
  { s with now := s.now + delay }

/-! ## Step relations and reachability -/

def StepAsIs (s s' : State) : Prop :=
  (∃ (c : ClientId) (delay : Nat) (chosen : List MasterId),
      delay ≤ MaxOpDelay ∧
      chosen.Nodup ∧
      listSubset chosen (freeMasters s) = true ∧
      s' = applyAcquire s c delay chosen)
  ∨ (∃ (c : ClientId) (delay : Nat),
      delay ≤ MaxOpDelay ∧
      (s.clients c).extensions < NumExtensions ∧
      s' = applyExtend false s c delay)
  ∨ (∃ (c : ClientId) (delay : Nat),
      delay ≤ MaxOpDelay ∧
      s' = applyRelease s c delay)
  ∨ (∃ (delay : Nat),
      0 < delay ∧ delay ≤ MaxOpDelay ∧ s' = applyAdvance s delay)

def StepContract (s s' : State) : Prop :=
  (∃ (c : ClientId) (delay : Nat) (chosen : List MasterId),
      delay ≤ MaxOpDelay ∧
      chosen.Nodup ∧
      listSubset chosen (freeMasters s) = true ∧
      s' = applyAcquire s c delay chosen)
  ∨ (∃ (c : ClientId) (delay : Nat),
      delay ≤ MaxOpDelay ∧
      (s.clients c).extensions < NumExtensions ∧
      s' = applyExtend true s c delay)
  ∨ (∃ (c : ClientId) (delay : Nat),
      delay ≤ MaxOpDelay ∧
      s' = applyRelease s c delay)
  ∨ (∃ (delay : Nat),
      0 < delay ∧ delay ≤ MaxOpDelay ∧ s' = applyAdvance s delay)

inductive ReachableAsIs : State → Prop where
  | init : ReachableAsIs initState
  | step {s s'} : ReachableAsIs s → StepAsIs s s' → ReachableAsIs s'

inductive ReachableContract : State → Prop where
  | init : ReachableContract initState
  | step {s s'} : ReachableContract s → StepContract s s' → ReachableContract s'

/-! ## Rules as state predicates -/

/-- INV-1: the number of clients whose A1(b) interval contains `now`. -/
def validHolderCount (s : State) : Nat :=
  ((List.finRange NumClients).filter
    (fun c => decide (s.now < (s.clients c).beliefEnd))).length

def AtMostOneValidHolder (s : State) : Prop :=
  validHolderCount s ≤ 1

/-- INV-6 first clause for the contract model. -/
def ExtendSucceededWithinValidity (s : State) (c : ClientId) : Prop :=
  (s.clients c).lastExtendOk = true →
    (s.clients c).lastExtendEnd <
      (s.clients c).lastExtendStart + ValidityWindow

end Redlock
