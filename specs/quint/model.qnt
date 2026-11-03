/**
 * pottery Redlock — Quint model of the G1-confirmed rules in specs/quint/RULES.md.
 *
 * Scope: synchronous Redlock semantics (ACT-14 / A6): quorum may return early.
 * Time is modelled in integer milliseconds.  `now` is the client's monotonic
 * clock; master keys expire when `expiry <= now` (ACT-13 / ENV-5).
 *
 * The model deliberately keeps the as-is `extend` behaviour (ACT-9) available
 * through `STRICT_EXTEND = false`, and the INV-6 proposal (RX) through
 * `STRICT_EXTEND = true`, so one model can both expose the counterexample and
 * check the corrected rule.  It never changes the rule text in RULES.md.
 *
 * Candidate findings are produced by `quint run`, never by `quint verify`.
 */

module redlock {
  type ClientId = int
  type MasterId = int
  type Token = int

  type MasterState = {
    owner: Token,   // 0 means "no key"
    expiry: int,    // absolute time in ms; key is absent when expiry <= now
  }

  type ClientState = {
    token: Token,
    extensions: int,
    beliefEnd: int,             // end of the last successful acquire/extend interval
    lastAcquireOk: bool,
    lastAcquireSets: int,
    lastAcquireStart: int,
    lastAcquireEnd: int,
    lastExtendTried: bool,
    lastExtendOk: bool,
    lastExtendRenewals: int,
    lastExtendStart: int,
    lastExtendEnd: int,
    lastReleaseOk: bool,
    lastReleaseDels: int,
    lastLockReport: int,
    lastLockHolders: int,
    lastLockAt: int,
    lastLockBeliefEnd: int,
  }

  // domain_justification: the number of independent Redis masters. The
  // program accepts any non-empty iterable of masters (pottery/base.py:302-310;
  // an empty iterable falls back to the single default Redis). It imposes no
  // upper bound, and quorum is `> len(masters)//2` (pottery/redlock.py:343).
  // Instances cover n=5 (README.md:331-335 production recommendation), n=4
  // (even-size strict-majority boundary), and n=1 (lower bound).
  const N_MASTERS: int

  // domain_justification: auto_release_time is a float with no validation
  // (pottery/redlock.py:239,271); PX is int(auto_release_time*1000)
  // (pottery/redlock.py:282). Documented/tested values include 10 (default,
  // pottery/redlock.py:229), 0.2 (README.md:327), 1 (tests/test_redlock.py:92),
  // 1.5 (README.md:465), and 0.001 (tests/test_redlock.py:51, used to force a
  // failure). Model ticks are milliseconds; see DRIFT. Instances cover 200,
  // 1000, and the 1 ms boundary.
  const ART: int

  // domain_justification: the program has no client-count limit; a Redlock is
  // just an object. Mutual exclusion is pairwise, so two clients are enough for
  // the property and keep the sampled state space small.
  const NUM_CLIENTS: int

  // domain_justification: num_extensions defaults to 3 and is not validated
  // (pottery/redlock.py:232,272). Values >= 0 are accepted; 0 makes every
  // extend throw TooManyExtensions (pottery/redlock.py:523-524). Instances use
  // 3 (default) and 0 (boundary).
  const NUM_EXTENSIONS: int

  // domain_justification: the program does not bound how long an acquire,
  // extend, release, or locked() call may take; elapsed time is whatever the
  // monotonic clock reports (pottery/timer.py:123-127). MAX_OP_DELAY is a
  // simulation bound only, never an assumption of the real system. It is set
  // above ART so that both `ART-DRIFT < delay < ART` (keys still alive at
  // completion) and `delay >= ART` (keys already expired) are reachable.
  const MAX_OP_DELAY: int

  // domain_justification: not a program input. `false` encodes the as-is
  // extend() (pottery/redlock.py:526-546: quorum only, no completion check, no
  // compensation); `true` encodes INV-6's confirmed RX (quorum AND
  // completion-time validity, else compensate and throw). Both values are
  // modelled explicitly; neither is an assumption about the code.
  const STRICT_EXTEND: bool

  // The code computes drift = ART*0.01 + .002 seconds (pottery/redlock.py:315-316).
  // With millisecond ticks that is ART/100 + 2 ms.  The model uses
  // ceil(ART/100)+2 so that non-multiples of 100 ms do not need fractional
  // ticks.  For every documented value that is a multiple of 100 ms the value
  // is exact; for ART=1 ms it is 3 ms instead of 2.01 ms, which is conservative
  // (validity is only smaller) and preserves the documented "always fails"
  // outcome of the .001 s test.
  pure val DRIFT: int = (ART + 99) / 100 + 2

  pure val MASTERS: Set[MasterId] = 0.to(N_MASTERS - 1)
  pure val CLIENTS: Set[ClientId] = 0.to(NUM_CLIENTS - 1)

  pure val NO_MASTER: MasterState = { owner: 0, expiry: 0 }

  pure val NO_CLIENT: ClientState = {
    token: 0,
    extensions: 0,
    beliefEnd: 0,
    lastAcquireOk: false,
    lastAcquireSets: 0,
    lastAcquireStart: 0,
    lastAcquireEnd: 0,
    lastExtendTried: false,
    lastExtendOk: false,
    lastExtendRenewals: 0,
    lastExtendStart: 0,
    lastExtendEnd: 0,
    lastReleaseOk: false,
    lastReleaseDels: 0,
    lastLockReport: 0,
    lastLockHolders: 0,
    lastLockAt: 0,
    lastLockBeliefEnd: 0,
  }

  // Strict majority, matching `> len(masters)//2` (pottery/redlock.py:343).
  pure def hasQuorum(count: int): bool = count > N_MASTERS / 2

  pure def isLive(m: MasterState, at: int): bool =
    m.owner != 0 and m.expiry > at

  pure def holdersOf(ms: MasterId -> MasterState, token: Token, at: int): Set[MasterId] =
    MASTERS.filter(m => ms.get(m).owner == token and ms.get(m).expiry > at)

  pure def countHolders(ms: MasterId -> MasterState, token: Token, at: int): int =
    holdersOf(ms, token, at).size()

  pure def freeMasters(ms: MasterId -> MasterState, at: int): Set[MasterId] =
    MASTERS.filter(m => not(isLive(ms.get(m), at)))

  // The Lua release script deletes only when GET == token (pottery/redlock.py:142-148).
  pure def releaseToken(ms: MasterId -> MasterState, token: Token): MasterId -> MasterState =
    MASTERS.fold(ms, (acc, m) =>
      if (acc.get(m).owner == token) acc.put(m, NO_MASTER) else acc)

  // The Lua extend script PEXPIREs only when GET == token and the key is alive
  // (pottery/redlock.py:128-134); a minority node that lost the key is not re-SET (A4).
  pure def renewHolders(
    ms: MasterId -> MasterState,
    hs: Set[MasterId],
    token: Token,
    at: int,
  ): MasterId -> MasterState =
    hs.fold(ms, (acc, m) => acc.put(m, { owner: token, expiry: at + ART }))

  pure def minTtlOf(ms: MasterId -> MasterState, hs: Set[MasterId], at: int): int =
    hs.fold(ART, (acc, m) =>
      if (ms.get(m).expiry - at < acc) ms.get(m).expiry - at else acc)

  pure def clipNonNegative(x: int): int = if (x > 0) x else 0

  var now: int
  var masters: MasterId -> MasterState
  var clients: ClientId -> ClientState
  var nextToken: int
  var issuedTokens: Set[Token]

  action init: bool = all {
    now' = 0,
    masters' = MASTERS.mapBy(_ => NO_MASTER),
    clients' = CLIENTS.mapBy(_ => NO_CLIENT),
    nextToken' = 1,
    issuedTokens' = Set(),
  }

  // ACT-1/2/3 and ACT-4.  `chosen` is the set of masters on which SET NX
  // succeeded before the synchronous client returned at quorum; it may be any
  // subset of the free masters.  Effects are placed at operation start and
  // `finish = now + delay`, the earliest-possible execution instant, which is
  // the worst case for safety (keys expire earliest relative to completion).
  action acquireWith(c: ClientId, delay: int, chosen: Set[MasterId]): bool = {
    val cl = clients.get(c)
    val token = nextToken
    val sets = chosen.size()
    val finish = now + delay
    val valid = finish < now + ART - DRIFT
    val ok = hasQuorum(sets) and valid
    val acquired = chosen.fold(masters, (acc, m) =>
      acc.put(m, { owner: token, expiry: now + ART }))
    val compensated = releaseToken(acquired, token)
    val base = {
      ...cl,
      token: token,
      lastAcquireOk: ok,
      lastAcquireSets: sets,
      lastAcquireStart: now,
      lastAcquireEnd: finish,
      lastExtendTried: false,
      lastExtendOk: false,
      lastReleaseOk: false,
    }
    all {
      delay >= 0,
      delay <= MAX_OP_DELAY,
      chosen.subseteq(freeMasters(masters, now)),
      now' = finish,
      nextToken' = nextToken + 1,
      issuedTokens' = issuedTokens.union(Set(token)),
      any {
        all {
          ok,
          clients' = clients.put(c, { ...base, extensions: 0, beliefEnd: now + ART - DRIFT }),
          masters' = acquired,
        },
        all {
          not(ok),
          clients' = clients.put(c, { ...base, extensions: cl.extensions, beliefEnd: 0 }),
          masters' = compensated,
        },
      },
    }
  }

  // ACT-5/ACT-15 block/retry semantics are liveness and out of scope (OUT-6);
  // the model exposes one acquire attempt at a time.
  action acquire(c: ClientId): bool = {
    nondet delay = 0.to(MAX_OP_DELAY).oneOf()
    nondet chosen = freeMasters(masters, now).powerset().oneOf()
    acquireWith(c, delay, chosen)
  }

  // ACT-7/8/9/10.  The as-is branch (STRICT_EXTEND = false) increments the
  // extension count on quorum alone and keeps the renewed minority keys when
  // the completion-time check would have failed.  The RX branch performs the
  // INV-6 completion check and compensates every node still holding the token.
  action extendWith(c: ClientId, delay: int): bool = {
    val cl = clients.get(c)
    val token = cl.token
    val hs = holdersOf(masters, token, now)
    val renewals = hs.size()
    val finish = now + delay
    val valid = finish < now + ART - DRIFT
    val quorumOk = hasQuorum(renewals)
    val ok = if (STRICT_EXTEND) quorumOk and valid else quorumOk
    val renewed = renewHolders(masters, hs, token, now)
    val compensated = releaseToken(renewed, token)
    val base = {
      ...cl,
      lastExtendTried: true,
      lastExtendOk: ok,
      lastExtendRenewals: renewals,
      lastExtendStart: now,
      lastExtendEnd: finish,
    }
    all {
      delay >= 0,
      delay <= MAX_OP_DELAY,
      cl.extensions < NUM_EXTENSIONS,
      now' = finish,
      masters' = if (ok) renewed else if (STRICT_EXTEND) compensated else renewed,
      clients' = clients.put(
        c,
        if (ok)
          { ...base, extensions: cl.extensions + 1, beliefEnd: now + ART - DRIFT }
        else
          { ...base, extensions: cl.extensions,
            beliefEnd: if (STRICT_EXTEND) 0 else cl.beliefEnd }
      ),
      nextToken' = nextToken,
      issuedTokens' = issuedTokens,
    }
  }

  action extend(c: ClientId): bool = {
    nondet delay = 0.to(MAX_OP_DELAY).oneOf()
    extendWith(c, delay)
  }

  // ACT-11.  The script deletes every matching key, then only quorum success is
  // reported as success (pottery/redlock.py:579-599).
  action releaseWith(c: ClientId, delay: int): bool = {
    val cl = clients.get(c)
    val token = cl.token
    val hs = holdersOf(masters, token, now)
    val dels = hs.size()
    val ok = hasQuorum(dels)
    val finish = now + delay
    val after = releaseToken(masters, token)
    val base = { ...cl, lastReleaseOk: ok, lastReleaseDels: dels }
    all {
      delay >= 0,
      delay <= MAX_OP_DELAY,
      now' = finish,
      masters' = after,
      clients' = clients.put(
        c,
        if (ok)
          { ...base, beliefEnd: 0 }
        else
          base
      ),
      nextToken' = nextToken,
      issuedTokens' = issuedTokens,
    }
  }

  action release(c: ClientId): bool = {
    nondet delay = 0.to(MAX_OP_DELAY).oneOf()
    releaseWith(c, delay)
  }

  // ACT-6.  The model takes the minimum TTL over all live token holders; the
  // synchronous code takes the minimum over the first quorum it collects
  // (pottery/redlock.py:492-498), so the modelled report is never larger.
  action lockedWith(c: ClientId, delay: int): bool = {
    val cl = clients.get(c)
    val hs = holdersOf(masters, cl.token, now)
    val ttl = minTtlOf(masters, hs, now)
    val report = if (hasQuorum(hs.size())) clipNonNegative(ttl - DRIFT - delay) else 0
    val finish = now + delay
    all {
      delay >= 0,
      delay <= MAX_OP_DELAY,
      now' = finish,
      masters' = masters,
      clients' = clients.put(c, {
        ...cl,
        lastLockReport: report,
        lastLockHolders: hs.size(),
        lastLockAt: finish,
        lastLockBeliefEnd: cl.beliefEnd,
      }),
      nextToken' = nextToken,
      issuedTokens' = issuedTokens,
    }
  }

  action locked(c: ClientId): bool = {
    nondet delay = 0.to(MAX_OP_DELAY).oneOf()
    lockedWith(c, delay)
  }

  // Time passing between calls.  The program has no such API; this is the
  // environment advancing the monotonic clock (ENV-2/ENV-5).  It is required so
  // that expiry is reachable without a client operation.
  action advanceTimeBy(delay: int): bool = all {
    delay >= 0,
    delay <= MAX_OP_DELAY,
    now' = now + delay,
    masters' = masters,
    clients' = clients,
    nextToken' = nextToken,
    issuedTokens' = issuedTokens,
  }

  action advanceTime: bool = {
    nondet delay = 1.to(MAX_OP_DELAY).oneOf()
    advanceTimeBy(delay)
  }

  action step: bool = {
    nondet c = CLIENTS.oneOf()
    any {
      acquire(c),
      extend(c),
      release(c),
      locked(c),
      advanceTime,
    }
  }

  // INV-1: at most one client's A1(b) validity interval contains the current
  // instant.  The interval is [successful completion, operation start + ART - DRIFT).
  val atMostOneValidHolder: bool =
    CLIENTS.filter(c => now < clients.get(c).beliefEnd).size() <= 1

  // INV-2 / ACT-3: acquire success implies quorum SET NX and validity > 0 at completion.
  val acquireSuccessNeedsQuorumAndValidity: bool =
    CLIENTS.forall(c => {
      val cl = clients.get(c)
      not(cl.lastAcquireOk)
      or (hasQuorum(cl.lastAcquireSets)
          and cl.lastAcquireEnd < cl.lastAcquireStart + ART - DRIFT)
    })

  // INV-3 / ACT-1: every acquire attempt mints a fresh token from a monotonic counter.
  val tokensAreFresh: bool = {
    val tokensInUse = CLIENTS.map(c => clients.get(c).token)
    all {
      issuedTokens.size() == nextToken - 1,
      issuedTokens.forall(t => t > 0 and t < nextToken),
      tokensInUse.forall(t => t >= 0 and t < nextToken),
    }
  }

  // INV-4: no two distinct tokens can each have a strict majority of live keys.
  val noTwoTokenMajorities: bool = {
    val liveTokens = MASTERS.map(m => masters.get(m).owner).filter(t => t != 0)
    liveTokens.forall(t1 => liveTokens.forall(t2 =>
      t1 == t2
      or not(hasQuorum(holdersOf(masters, t1, now).size())
             and hasQuorum(holdersOf(masters, t2, now).size()))))
  }

  // Derived from INV-2/INV-6: a client inside its A1(b) interval still has quorum keys.
  val validHolderHasQuorum: bool =
    CLIENTS.forall(c => {
      val cl = clients.get(c)
      not(now < cl.beliefEnd) or hasQuorum(holdersOf(masters, cl.token, now).size())
    })

  // INV-6 first clause: successful extend implies quorum PEXPIRE and completion validity.
  val extendSuccessNeedsQuorumAndValidity: bool =
    CLIENTS.forall(c => {
      val cl = clients.get(c)
      not(cl.lastExtendOk)
      or (hasQuorum(cl.lastExtendRenewals)
          and cl.lastExtendEnd < cl.lastExtendStart + ART - DRIFT)
    })

  // INV-6 compensation clause: a failed extend leaves no node holding this token.
  val failedExtendCompensated: bool =
    CLIENTS.forall(c => {
      val cl = clients.get(c)
      not(cl.lastExtendTried and not(cl.lastExtendOk))
      or holdersOf(masters, cl.token, now).size() == 0
    })

  // INV-6 compensation clause for a completed-too-late extend, including the
  // as-is case where the late extend incorrectly reports success.
  val lateExtendCompensated: bool =
    CLIENTS.forall(c => {
      val cl = clients.get(c)
      not(cl.lastExtendTried)
      or cl.lastExtendEnd < cl.lastExtendStart + ART - DRIFT
      or holdersOf(masters, cl.token, now).size() == 0
    })

  // INV-7: successful extensions never exceed num_extensions.
  val extensionLimit: bool =
    CLIENTS.forall(c => clients.get(c).extensions <= NUM_EXTENSIONS)

  // INV-8: release success implies quorum DEL of this token.
  val releaseSuccessNeedsQuorum: bool =
    CLIENTS.forall(c => {
      val cl = clients.get(c)
      not(cl.lastReleaseOk) or hasQuorum(cl.lastReleaseDels)
    })

  // INV-9: locked() may report a positive value only with quorum holders, and
  // never more than the safe remaining time implied by the A1(b) interval.
  val lockedReportWithinSafeBound: bool =
    CLIENTS.forall(c => {
      val cl = clients.get(c)
      val safe = clipNonNegative(cl.lastLockBeliefEnd - cl.lastLockAt)
      cl.lastLockReport <= safe
      and (cl.lastLockReport <= 0 or hasQuorum(cl.lastLockHolders))
    })

  // INV-10 is a control-flow rule, not a reachable lock-state predicate; it is
  // checked by the pure functions below and the corresponding `run` witnesses.
  type ExitResult = NoException | BodyException | ReleaseException

  // As-is __exit__/__aexit__: a release failure overwrites the body exception
  // (pottery/redlock.py:673, pottery/aioredlock.py:560).
  pure def asIsExit(bodyRaised: bool, releaseOk: bool): ExitResult =
    if (releaseOk)
      (if (bodyRaised) BodyException else NoException)
    else
      ReleaseException

  // INV-10 contract (A2): body exception wins; without a body exception a
  // release failure is propagated.
  pure def contractExit(bodyRaised: bool, releaseOk: bool): ExitResult =
    if (bodyRaised)
      BodyException
    else
      (if (releaseOk) NoException else ReleaseException)
}
