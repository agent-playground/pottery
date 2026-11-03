/**
 * Concrete instances for specs/quint/model.qnt.
 *
 * All values are explicit.  The rationale for each value is repeated in
 * specs/quint/REPORT.md.  No instance weakens or strengthens a RULES.md rule:
 * `as_is`/`as_is_even`/`as_is_slow` encode the current code (ACT-9/ACT-10),
 * while `fixed` is the same model with the confirmed INV-6 RX switch on.
 */

// Production-recommended 5-master cluster (README.md:331-335); 0.2 s lease is
// the value used throughout README.md and tests; 205 ms delay bound is above
// ART so a completion-time violation is reachable.
module as_is {
  import redlock(
    N_MASTERS = 5,
    ART = 200,
    NUM_CLIENTS = 2,
    NUM_EXTENSIONS = 3,
    MAX_OP_DELAY = 205,
    STRICT_EXTEND = false,
  ).* from "./model"
}

// Same constants as as_is, with the INV-6 completion check and compensation.
module fixed {
  import redlock(
    N_MASTERS = 5,
    ART = 200,
    NUM_CLIENTS = 2,
    NUM_EXTENSIONS = 3,
    MAX_OP_DELAY = 205,
    STRICT_EXTEND = true,
  ).* from "./model"
}

// Even master count: strict majority is 3 of 4, not 2 of 4.
module as_is_even {
  import redlock(
    N_MASTERS = 4,
    ART = 200,
    NUM_CLIENTS = 2,
    NUM_EXTENSIONS = 3,
    MAX_OP_DELAY = 205,
    STRICT_EXTEND = false,
  ).* from "./model"
}

// Larger lease (1 s) with exact integer drift (12 ms): checks that the result
// does not depend on the 0.2 s scale.
module as_is_slow {
  import redlock(
    N_MASTERS = 5,
    ART = 1000,
    NUM_CLIENTS = 2,
    NUM_EXTENSIONS = 3,
    MAX_OP_DELAY = 1025,
    STRICT_EXTEND = false,
  ).* from "./model"
}

// Lower-bound instance: one master, 1 ms lease, no extensions.  The code's
// drift (.002 s = 2 ms) exceeds the lease, so acquire can never succeed; this
// covers the documented .001 s failure case (tests/test_redlock.py:50-58).
module boundary_tiny {
  import redlock(
    N_MASTERS = 1,
    ART = 1,
    NUM_CLIENTS = 1,
    NUM_EXTENSIONS = 0,
    MAX_OP_DELAY = 5,
    STRICT_EXTEND = true,
  ).* from "./model"
}
