/-
Axiom audit for the headline theorems (Rule 3 guardrail).
Run from `specs/lean`: `lake env lean Audit.lean`.
The proofs phase requires only `propext`, `Classical.choice`, `Quot.sound`,
or no axioms.
-/
import Specs

#print axioms Redlock.at_most_one_valid_holder
#print axioms Redlock.as_is_late_extend_reports_success
#print axioms Redlock.as_is_late_extend_no_compensation
#print axioms Redlock.contract_extend_success_implies_validity
#print axioms Redlock.contract_late_extend_compensates
