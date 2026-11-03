/**
 * Scenario witnesses and checks for specs/quint/model.qnt.
 *
 * Each rule in specs/quint/RULES.md has at least one positive witness: the
 * scenario describes the situation the rule protects, not the negation of an
 * invariant, and no witness is already true at `init`.
 *
 * `asIsTest` intentionally demonstrates the as-is extend deviation (INV-6).
 * `fixedTest` demonstrates the same scenario under the confirmed RX.
 * `boundaryTest` covers the one-master / 1 ms / num_extensions=0 boundary.
 */

module asIsTest {
  // Same constants as instances.qnt::as_is (kept explicit because a module that
  // only imports another module does not re-export its definitions).
  import redlock(
    N_MASTERS = 5,
    ART = 200,
    NUM_CLIENTS = 2,
    NUM_EXTENSIONS = 3,
    MAX_OP_DELAY = 205,
    STRICT_EXTEND = false,
  ).* from "./model"

  // INV-1: while A is inside its validity interval, B cannot become valid.
  run inv1SingleValidHolderTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .expect(now < clients.get(0).beliefEnd)
      .expect(clients.get(1).beliefEnd == 0)
      .expect(atMostOneValidHolder)
      .then(acquireWith(1, 0, Set(3, 4)))
      .expect(not(clients.get(1).lastAcquireOk))
      .expect(clients.get(1).beliefEnd == 0)
      .then(releaseWith(0, 0))
      .expect(clients.get(0).beliefEnd == 0)
      .then(acquireWith(1, 0, Set(0, 1, 2)))
      .expect(now < clients.get(1).beliefEnd)
      .expect(clients.get(0).beliefEnd == 0)
      .expect(atMostOneValidHolder)

  // INV-2: acquire success needs quorum SET NX and validity > 0 at completion;
  // the same action can fail when the completion is too late.
  run inv2AcquireValidityTest =
    init
      .then(acquireWith(0, 100, Set(0, 1, 2)))
      .expect(clients.get(0).lastAcquireOk)
      .expect(clients.get(0).lastAcquireSets == 3)
      .expect(clients.get(0).lastAcquireEnd < clients.get(0).lastAcquireStart + ART - DRIFT)
      .then(releaseWith(0, 0))
      .then(acquireWith(0, 200, Set(0, 1, 2)))
      .expect(not(clients.get(0).lastAcquireOk))
      .expect(clients.get(0).lastAcquireEnd >= clients.get(0).lastAcquireStart + ART - DRIFT)
      .expect(countHolders(masters, clients.get(0).token, now) == 0)

  // INV-3: a second acquire attempt uses a new token, never the old one.
  run inv3FreshTokenTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(releaseWith(0, 0))
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .expect(clients.get(0).token == 2)
      .expect(issuedTokens.size() == 2)
      .expect(tokensAreFresh)

  // INV-4: A has a quorum; B can only obtain the remaining minority, so B fails
  // and no two distinct tokens ever have a majority.
  run inv4QuorumIntersectionTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(acquireWith(1, 0, Set(3, 4)))
      .expect(not(clients.get(1).lastAcquireOk))
      .expect(noTwoTokenMajorities)

  // INV-5: extend/release with a token that is not on any master is a no-op;
  // A's keys are untouched by B's calls.
  run inv5TokenMatchTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(extendWith(1, 0))
      .expect(not(clients.get(1).lastExtendOk))
      .expect(countHolders(masters, clients.get(0).token, now) == 3)
      .then(releaseWith(1, 0))
      .expect(not(clients.get(1).lastReleaseOk))
      .expect(countHolders(masters, clients.get(0).token, now) == 3)

  // ACT-13: after the lease expires the keys are gone and a second client can
  // acquire the same quorum; the first client's belief has also expired.
  run act13ExpiryFreesLockTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .expect(now < clients.get(0).beliefEnd)
      .then(advanceTimeBy(200))
      .expect(countHolders(masters, clients.get(0).token, now) == 0)
      .expect(now >= clients.get(0).beliefEnd)
      .then(acquireWith(1, 0, Set(0, 1, 2)))
      .expect(clients.get(1).lastAcquireOk)
      .expect(now < clients.get(1).beliefEnd)
      .expect(atMostOneValidHolder)

  // ACT-15: re-acquiring while the old keys are still present mints a new token,
  // blocks on the old majority, and leaves the old keys to expire.
  run act15NonReentrantTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(acquireWith(0, 0, Set(3, 4)))
      .expect(not(clients.get(0).lastAcquireOk))
      .expect(clients.get(0).token == 2)
      .expect(countHolders(masters, 1, now) == 3)
      .expect(countHolders(masters, clients.get(0).token, now) == 0)

  // INV-6 as-is: a 197 ms extend completes after the 196 ms deadline, still
  // reports success, increments the counter, and leaves the renewed keys.
  run asIsLateExtendWitnessTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(extendWith(0, 197))
      .expect(clients.get(0).lastExtendOk)
      .expect(clients.get(0).lastExtendEnd >= clients.get(0).lastExtendStart + ART - DRIFT)
      .expect(clients.get(0).extensions == 1)
      .expect(countHolders(masters, clients.get(0).token, now) == 3)

  // INV-7: after num_extensions successful renewals the next extend is blocked.
  run inv7ExtensionLimitTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(extendWith(0, 0))
      .then(extendWith(0, 0))
      .then(extendWith(0, 0))
      .expect(clients.get(0).extensions == 3)
      .then(extendWith(0, 0).fail())

  // INV-8: B's release (no keys) fails; A's release of three keys succeeds.
  run inv8ReleaseQuorumTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(releaseWith(1, 0))
      .expect(not(clients.get(1).lastReleaseOk))
      .then(releaseWith(0, 0))
      .expect(clients.get(0).lastReleaseOk)
      .expect(clients.get(0).lastReleaseDels == 3)
      .expect(clients.get(0).beliefEnd == 0)
      .expect(countHolders(masters, clients.get(0).token, now) == 0)

  // INV-9: a positive locked() report comes from a quorum and stays within the
  // safe remaining time (200 - 4 - 50 = 146 ms here).
  run inv9LockedReportTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(lockedWith(0, 50))
      .expect(clients.get(0).lastLockReport == 146)
      .expect(clients.get(0).lastLockHolders == 3)
      .expect(lockedReportWithinSafeBound)

  // INV-10: the contract gives a body exception priority; the as-is expression
  // is the pre-fix behaviour that overwrites it.
  run inv10ExitPriorityTest =
    init
      .expect(contractExit(true, false) == BodyException)
      .expect(contractExit(true, true) == BodyException)
      .expect(contractExit(false, false) == ReleaseException)
      .expect(contractExit(false, true) == NoException)
      .expect(asIsExit(true, false) == ReleaseException)
}

module fixedTest {
  // Same constants as instances.qnt::fixed.
  import redlock(
    N_MASTERS = 5,
    ART = 200,
    NUM_CLIENTS = 2,
    NUM_EXTENSIONS = 3,
    MAX_OP_DELAY = 205,
    STRICT_EXTEND = true,
  ).* from "./model"

  // INV-6 RX: the same late extend now fails and compensates every renewed node.
  run inv6FixedLateExtendTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(extendWith(0, 197))
      .expect(not(clients.get(0).lastExtendOk))
      .expect(clients.get(0).extensions == 0)
      .expect(clients.get(0).lastExtendEnd >= clients.get(0).lastExtendStart + ART - DRIFT)
      .expect(countHolders(masters, clients.get(0).token, now) == 0)
      .expect(lateExtendCompensated)

  // INV-6 RX: a fast extend still succeeds and renews the quorum.
  run inv6FixedFastExtendTest =
    init
      .then(acquireWith(0, 0, Set(0, 1, 2)))
      .then(extendWith(0, 0))
      .expect(clients.get(0).lastExtendOk)
      .expect(clients.get(0).extensions == 1)
      .expect(clients.get(0).lastExtendEnd < clients.get(0).lastExtendStart + ART - DRIFT)
      .expect(countHolders(masters, clients.get(0).token, now) == 3)
      .expect(extendSuccessNeedsQuorumAndValidity)
}

module boundaryTest {
  // Same constants as instances.qnt::boundary_tiny.
  import redlock(
    N_MASTERS = 1,
    ART = 1,
    NUM_CLIENTS = 1,
    NUM_EXTENSIONS = 0,
    MAX_OP_DELAY = 5,
    STRICT_EXTEND = true,
  ).* from "./model"

  // ART = 1 ms is below the fixed drift, so acquire always fails (the same
  // outcome the repository's .001 s test expects).
  run tinyAcquireFailsTest =
    init
      .then(acquireWith(0, 0, Set(0)))
      .expect(not(clients.get(0).lastAcquireOk))
      .expect(clients.get(0).lastAcquireSets == 1)
      .expect(countHolders(masters, clients.get(0).token, now) == 0)

  // num_extensions = 0 is the lower boundary: every extend is blocked.
  run noExtensionsBoundaryTest =
    init
      .then(extendWith(0, 0).fail())
}
