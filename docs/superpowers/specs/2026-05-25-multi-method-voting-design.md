# Multi-Method Ranked Choice Voting — Design Spec

**Date:** 2026-05-25
**Repo:** `blockful/copeland-voting`
**Status:** Approved for implementation
**Supersedes (additively):** [2026-05-24-copeland-voting-design.md](./2026-05-24-copeland-voting-design.md)

## 1. Purpose

Extend the existing Copeland implementation with a second Condorcet method — **Schulze** — and factor out a shared `IRankedChoiceVoting` interface so both contracts are interchangeable from a consumer's standpoint.

Additionally:
- Add a **`getCurrentResult`** view that returns the ranking the contract would produce if `finalize` were called right now. Works at any lifecycle phase. Lets UIs show a live preview during tallying.
- Add a **`docs/voting-methods.md`** documentation page with Mermaid diagrams for the voting cycle and per-method math walkthroughs.

## 2. Scope

In scope:
- Common interface `IRankedChoiceVoting` containing every method that both Copeland and Schulze support, plus all shared events/errors.
- `ICopelandVoting` and `ISchulzeVoting` extend the common interface with method-specific getters.
- `SchulzeVoting` contract — new implementation, mirroring `CopelandVoting`'s structure (no abstract base — see §4).
- `SchulzeTally` pure library (Floyd-Warshall + score + ranking).
- `getCurrentResult` added to both contracts.
- Full test parity for Schulze (unit, scenarios, fuzz, gas snapshot).
- Cross-method invariant test: when a Condorcet winner exists, both methods rank them first.
- Methodology docs with Mermaid diagrams.

Out of scope:
- Adding more methods (Borda, IRV, Tideman, etc.) — YAGNI; the interface fits Condorcet/pairwise methods only.
- An abstract base contract or strategy pattern. Slight duplication between Copeland/Schulze contracts is preferred to inheritance complexity (see §4).
- ZK proofs, commit-reveal, multi-chain.
- Re-audit of CopelandVoting (it's still unaudited; same disclaimer applies to SchulzeVoting).

## 3. Common Interface — `IRankedChoiceVoting`

```solidity
interface IRankedChoiceVoting {
    enum TallyPhase { NotStarted, Tallying, Finalized }

    struct ElectionConfig {
        bytes32[] candidates;
        IVotes votingToken;
        uint256 snapshotBlock;
        uint64 startTime;
        uint64 endTime;
        bytes32 metadataURI;
    }

    struct ElectionView {
        bytes32[] candidates;
        IVotes votingToken;
        uint256 snapshotBlock;
        uint64 startTime;
        uint64 endTime;
        bytes32 metadataURI;
        address creator;
        uint256 voterCount;
        TallyPhase phase;
        uint256 ballotsProcessed;
    }

    // Events (identical across methods)
    event ElectionCreated(uint256 indexed electionId, address indexed creator, ElectionConfig cfg);
    event BallotCast(uint256 indexed electionId, address indexed voter, uint8[] ranking);
    event TallyProgress(uint256 indexed electionId, uint256 ballotsProcessed, uint256 totalBallots);
    event Finalized(uint256 indexed electionId, uint8[] ranking);

    // Errors (all 17 from the Copeland v1; no new common errors)
    error EmptyCandidates();
    error TooManyCandidates(uint256 provided, uint256 max);
    error DuplicateCandidate(bytes32 candidate);
    error InvalidSnapshotBlock(uint256 snapshotBlock, uint256 currentBlock);
    error InvalidTimeWindow(uint64 startTime, uint64 endTime);
    error EndTimeInPast(uint64 endTime, uint256 currentTime);
    error ZeroToken();
    error UnknownElection(uint256 electionId);
    error VotingNotOpen(uint64 startTime, uint64 endTime, uint256 currentTime);
    error VotingStillOpen(uint64 endTime, uint256 currentTime);
    error ElectionFinalized();
    error TallyNotComplete(uint256 processed, uint256 total);
    error TallyAlreadyFinalized();
    error RankingTooLong(uint256 provided, uint256 max);
    error CandidateIndexOutOfBounds(uint8 index, uint256 max);
    error DuplicateRanking(uint8 index);
    error WeightExceedsInt256Max(address voter, uint256 weight);

    // Lifecycle
    function createElection(ElectionConfig calldata cfg) external returns (uint256 electionId);
    function castBallot(uint256 electionId, uint8[] calldata ranking) external;
    function tallyBallots(uint256 electionId, uint256 maxBallots) external returns (bool done);
    function finalize(uint256 electionId) external;

    // Results
    function getRanking(uint256 electionId) external view returns (uint8[] memory);

    /// @notice The ranking the contract would produce if finalize() were called right now.
    /// Works at any lifecycle phase. During tallying, returns the ranking based on the
    /// partially-built pairwise matrix (i.e., "if we stopped now, this is the result").
    /// For NotStarted or empty matrix: returns the identity ranking [0..C-1].
    /// Always reverts UnknownElection if the id doesn't exist.
    function getCurrentResult(uint256 electionId) external view returns (uint8[] memory);

    // State
    function getElection(uint256 electionId) external view returns (ElectionView memory);
    function getBallot(uint256 electionId, address voter) external view returns (uint8[] memory);
    function getPairwiseMatrix(uint256 electionId) external view returns (int256[][] memory);
    function getVoters(uint256 electionId) external view returns (address[] memory);
    function electionCount() external view returns (uint256);

    function MAX_CANDIDATES() external view returns (uint8);
}
```

### Method-specific interfaces

```solidity
interface ICopelandVoting is IRankedChoiceVoting {
    /// @notice Copeland score per candidate: (# pairs i won) - (# pairs i lost). Populated by finalize().
    function getCopelandScores(uint256 electionId) external view returns (int256[] memory);
    /// @notice Minimax tiebreaker per candidate: smallest pairwise margin across opponents. Populated by finalize().
    function getMinimaxScores(uint256 electionId) external view returns (int256[] memory);
}

interface ISchulzeVoting is IRankedChoiceVoting {
    /// @notice Strongest-paths matrix p[i][j] = strength of strongest path from i to j. Computed on-the-fly
    /// from the pairwise matrix; O(C³) per call. Not persisted (too expensive at C=64).
    function getStrongestPaths(uint256 electionId) external view returns (int256[][] memory);
    /// @notice Schulze score: count of opponents j with p[i][j] > p[j][i]. Populated by finalize().
    function getSchulzeScores(uint256 electionId) external view returns (uint256[] memory);
}
```

## 4. Architecture choice — separate contracts, no abstract base

Two complete contracts (`CopelandVoting`, `SchulzeVoting`), each implementing the common interface. ~150 lines of shared logic are duplicated between them.

**Why not an abstract base:**
- The user explicitly said "don't overengineer." Inheritance with virtual hooks (one view + one state-changing for `_computeRanking`) adds Solidity complexity readers must track across files.
- The two contracts will likely evolve at different rates; duplication is cheap to maintain because the shared logic is tightly scoped (60-line lifecycle methods).
- Each contract reads top-to-bottom in one file.

**Risk accepted:** a bug fix to shared logic must be applied to both contracts. We mitigate via a shared test fixture pattern (see §7).

## 5. Schulze method

### Algorithm

Pairwise matrix `d[i][j]` = total voting weight of voters who preferred i over j (same as Copeland — reuses the existing `tallyBallots` flow that builds `pairwiseFlat`).

**Strongest paths matrix** `p[i][j]` = strength of the strongest path from i to j, where path strength is the *minimum* edge weight along the path. Computed via Floyd-Warshall:

```
# Initialize
for i, j with i != j:
    if d[i][j] > d[j][i]:
        p[i][j] = d[i][j]
    else:
        p[i][j] = 0

# Floyd-Warshall
for k in 0..C:
    for i in 0..C, i != k:
        for j in 0..C, j != i, j != k:
            p[i][j] = max(p[i][j], min(p[i][k], p[k][j]))
```

**Schulze score** for candidate i: `s[i] = count of j (j != i) such that p[i][j] > p[j][i]`.

**Ranking:** sort by `(s desc, candidate index asc)`. Index ordering is the final fallback for ties.

### Tiebreaker

When two candidates have equal Schulze scores, candidate index breaks the tie (ascending). This is simpler than Copeland's two-level (score → minimax → index) because Schulze scores tend to discriminate more strongly (the path-strength algorithm captures more pairwise information).

### Gas / storage

- **Tally (phase 1):** identical to Copeland — builds `pairwiseFlat` paginated. ~50-200k gas per ballot.
- **Finalize:** runs Floyd-Warshall in memory (O(C³)) then computes scores + sorts. For C=10: ~500k gas. For C=64: ~12M gas (within block limit; user warned in docs).
- **Persisted on finalize:** `finalRanking` (C uint8) and `schulzeScores` (C uint256). Cheap.
- **NOT persisted:** strongest paths matrix (C=64 → 4096 storage slots × 20k gas each = 80M+ gas, exceeds block limit). `getStrongestPaths` recomputes on each view call (free for view, but slow on the RPC side).

### `getCurrentResult` for Schulze

View function. Reads `pairwiseFlat` from storage (cold SLOAD cost ~4096 × 2100 = 8.6M gas at C=64; ~210k gas at C=10). Runs Floyd-Warshall + scoring + sort in memory. Returns the ranking. No state changes.

For empty matrix (no votes yet or NotStarted phase): all scores zero → identity ranking `[0, 1, ..., C-1]`.

## 6. `getCurrentResult` semantics (both methods)

| Phase | Matrix state | Returned ranking |
|---|---|---|
| `NotStarted` (voting open or just closed, before any tally) | Empty (all zeros) | `[0, 1, ..., C-1]` (identity) |
| `Tallying` (some ballots processed) | Partial | Whatever the algorithm produces from the partial matrix — **a preview, not a prediction** |
| `Finalized` | Full | Same as `getRanking` |

Reverts `UnknownElection` if the id is invalid. Never reverts based on phase (intentional — it's a preview).

**Important caveat documented in `voting-methods.md`:** during `Tallying`, the result reflects only the ballots already processed. It changes as more voters are tallied. UI integrators should display "preliminary" or "X of Y ballots tallied" alongside the result.

## 7. Test strategy

### Shared test fixture

A `test/RankedChoiceVotingTest.t.sol` abstract test contract holds tests that any `IRankedChoiceVoting` implementation must satisfy:
- Lifecycle: createElection happy + all 7 revert paths
- castBallot happy + recast + all 6 revert paths
- tallyBallots single-call + batched + reverts + zero-weight + zero-max
- finalize + revert paths + no-ballots-identity
- getCurrentResult: NotStarted, Tallying mid-state, Finalized
- View functions return-shape sanity

Concrete test contracts (`CopelandVotingTest`, `SchulzeVotingTest`) inherit this abstract base, plug in their constructor, and add method-specific assertions (Copeland scores/minimax, Schulze scores).

This catches divergence between the two contracts on shared behavior.

### Method-specific test suites

| Test file | Coverage |
|---|---|
| `test/CopelandTally.t.sol` | Pure library: scoring, minimax, sort. Already exists. |
| `test/SchulzeTally.t.sol` | NEW: Floyd-Warshall, scores, sort. Worked Wikipedia example. |
| `test/CopelandVoting.t.sol` | Refactor to use shared fixture + add `getCurrentResult` tests. |
| `test/SchulzeVoting.t.sol` | NEW: mirror Copeland's but with Schulze assertions. |
| `test/CopelandVoting.scenarios.t.sol` | Existing 4 scenarios. |
| `test/SchulzeVoting.scenarios.t.sol` | NEW: Schulze winner from Wikipedia example, Condorcet cycle (Schulze produces a definite winner unlike Copeland's index fallback), ENS-style 12-candidate, replacement. |
| `test/CopelandVoting.fuzz.t.sol` | Existing 2 invariants. |
| `test/SchulzeVoting.fuzz.t.sol` | NEW: permutation, determinism. |
| `test/CrossMethod.invariants.t.sol` | NEW: **when a Condorcet winner exists, both methods rank them first**. |

### Test counts target

- Existing: 48 tests passing
- Target after this change: ~95-105 tests passing (Schulze adds parallel coverage; common fixture adds shared parameterized tests)

## 8. Documentation — `docs/voting-methods.md`

Sections:

1. **Overview** — when to use this contract, what problem it solves.
2. **The common interface** — table of every method on `IRankedChoiceVoting` with one-line semantics.
3. **Election lifecycle** — Mermaid state diagram (`NotStarted → Tallying → Finalized`) + Mermaid sequence diagram showing creator/voter/tallier interactions.
4. **Ballot semantics** — what a partial ranking means, how unranked candidates are treated, replacement rules.
5. **Tally processing** — Mermaid flowchart: ballot → pairwise pair contributions → matrix → method-specific scoring → ranking.
6. **Copeland method** — math, tie resolution (Copeland score → Minimax → index), worked 3-candidate example with hand-computed matrix and ranking.
7. **Schulze method** — math, Floyd-Warshall walked through with a small example, tie resolution (Schulze score → index), reference to Wikipedia's canonical example.
8. **Choosing between methods** — Copeland is cheaper for large C; Schulze resolves Condorcet cycles deterministically without falling back to index ordering.
9. **Parameters & limits** — max candidates (64), max ballot length (= C), gas notes per method per C.
10. **Tie resolution summary table** — both methods side-by-side.
11. **Production-readiness notes** — not audited; defense-in-depth in place.

All diagrams use Mermaid (renders natively on GitHub).

## 9. Edge cases (both methods)

| Case | Copeland | Schulze |
|---|---|---|
| No ballots cast | Identity ranking | Identity ranking |
| All voters have 0 weight | Identity ranking | Identity ranking |
| Condorcet winner exists | Wins (Copeland score = C-1, max) | Wins (Schulze score = C-1, max) |
| Condorcet cycle, equal margins | All Copeland scores tied at 0, all Minimax tied → falls back to index | Resolves to a definite winner via Floyd-Warshall path strengths |
| C == 1 | Ranking = [0] | Ranking = [0] |
| C == 2 | Direct pairwise | Direct pairwise (Floyd-Warshall trivial) |

Both methods are deterministic given identical inputs.

## 10. Migration / compatibility

- Existing `CopelandVoting` consumers see no breaking changes: `ICopelandVoting` still exposes every method it did before (via inheritance from `IRankedChoiceVoting`).
- New `getCurrentResult` is purely additive.
- Storage layout of `CopelandVoting.Election` is **unchanged**. (The field set didn't move; we only added a new view function.)

## 11. Acceptance criteria

- All existing 48 tests continue to pass.
- New Schulze contract + library land with ≥30 dedicated tests + 4 scenarios + 2 fuzz invariants.
- `getCurrentResult` works on both contracts in all three lifecycle phases.
- `docs/voting-methods.md` renders correctly on GitHub with working Mermaid diagrams.
- CI green on the rewritten head.
- Repo pushed to `main` on `blockful/copeland-voting`.
