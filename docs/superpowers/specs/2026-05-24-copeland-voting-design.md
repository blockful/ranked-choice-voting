# Onchain Copeland Voting — Design Spec

**Date:** 2026-05-24
**Repo:** `blockful/copeland-voting`
**Status:** Approved for implementation

## 1. Purpose

A standalone Solidity contract that runs Copeland-method ranked choice elections fully onchain on Ethereum mainnet. Voters submit ranked ballots weighted by `IVotes` (ERC20Votes / ERC721Votes) snapshots. The contract outputs a deterministic ordering of all candidates. Downstream consumers (Governors, council selection logic, budget allocators) interpret that ordering however they need.

The framework intentionally does **one thing well**: turn ranked ballots into a strict ordering using the Copeland method. It does not execute proposals, allocate funds, or decide what "winning" means.

## 2. Why Copeland

Copeland is Condorcet-consistent (if a candidate beats every other in head-to-head, they always win), produces a full ordering naturally, and has tractable onchain cost: O(C²) pairwise comparisons for C candidates. Alternatives considered and rejected:

| Method | Reason rejected |
|---|---|
| Borda count | Vulnerable to clones; not Condorcet |
| Schulze | Requires O(C³) Floyd-Warshall — bad onchain |
| IRV / Hare | Not monotonic; multi-round logic adds complexity |
| Minimax | Counterintuitive winner under cycles |

YAGNI: ship Copeland only. A pluggable strategy interface can be added later if needed.

## 3. Decisions (locked)

| Decision | Choice |
|---|---|
| Use case | Generic DAO governance framework |
| Onchain scope | Onchain ballots + lazy batched tally |
| Voting power | `IVotes` snapshot (ERC20Votes / ERC721Votes) |
| Election outputs | Ordered list of all candidates (consumer interprets) |
| Integration | Standalone contract (no Governor coupling) |
| Ballot format | Partial ranking with explicit abstention (silent on unranked pairs) |
| Voting method | Copeland only |
| Tiebreaker | Sum of pairwise margins; final fallback = candidate index |
| Vote changes | Replaceable (latest ballot wins) |
| Deployment shape | Single registry contract holding many elections |
| Target chain | Ethereum mainnet first |
| Tooling | Solidity ^0.8.26, Foundry |
| License | MIT |

## 4. Public API

```solidity
interface ICopelandVoting {
    enum TallyPhase { NotStarted, Tallying, Finalized }

    struct ElectionConfig {
        bytes32[] candidates;   // arbitrary IDs (string hashes, addresses, ENS namehashes, etc.)
        IVotes votingToken;     // ERC20Votes or ERC721Votes
        uint256 snapshotBlock;  // past block; voting power = token.getPastVotes(voter, snapshotBlock)
        uint64 startTime;
        uint64 endTime;
        bytes32 metadataURI;    // IPFS/Arweave pointer to titles/descriptions (optional, zero allowed)
    }

    // Returned by getElection — same as ElectionConfig plus runtime state, no mappings.
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

    // Lifecycle
    function createElection(ElectionConfig calldata cfg) external returns (uint256 electionId);

    // Voting (replaceable; overwrites previous ballot)
    function castBallot(uint256 electionId, uint8[] calldata ranking) external;

    // Tally — anyone may call, paginated
    function tallyBallots(uint256 electionId, uint256 maxBallots) external returns (bool done);
    function finalize(uint256 electionId) external;

    // Reads
    function getRanking(uint256 electionId) external view returns (uint8[] memory);
    function getElection(uint256 electionId) external view returns (ElectionView memory);
    function getBallot(uint256 electionId, address voter) external view returns (uint8[] memory);
    function getPairwiseMatrix(uint256 electionId) external view returns (int256[][] memory);
    function getCopelandScores(uint256 electionId) external view returns (int256[] memory);
    function getMarginSums(uint256 electionId) external view returns (int256[] memory);
    function getVoters(uint256 electionId) external view returns (address[] memory);
    function electionCount() external view returns (uint256);

    // Events
    event ElectionCreated(uint256 indexed electionId, address indexed creator, ElectionConfig cfg);
    event BallotCast(uint256 indexed electionId, address indexed voter, uint8[] ranking);
    event TallyProgress(uint256 indexed electionId, uint256 ballotsProcessed, uint256 totalBallots);
    event Finalized(uint256 indexed electionId, uint8[] ranking);
}
```

**Notes:**
- `uint8` for candidate indices caps candidates at **256 per election**. With Copeland's O(C²) that's already at the edge of mainnet practicality; we hard-cap at **64 candidates** in v1 to keep tally feasible.
- `ranking[i]` is a candidate index (0..C-1). Order is preference order: `ranking[0]` is the voter's top choice. Length may be 0..C. Duplicates revert.
- Election creation is **permissionless**. Anyone can create one; consumers (DAOs) pick which election ID they trust.

## 5. Data Model

```solidity
struct Election {
    // immutable config (set at creation)
    bytes32[] candidates;
    IVotes votingToken;
    uint256 snapshotBlock;
    uint64 startTime;
    uint64 endTime;
    bytes32 metadataURI;
    address creator;

    // ballot storage
    address[] voters;                              // ordered append on first ballot
    mapping(address => uint8[]) ballots;           // voter → ranking
    mapping(address => uint256) voterIndexPlusOne; // membership check; 0 = not voted, else index+1

    // tally state
    TallyPhase phase;                              // NotStarted | Tallying | Finalized
    uint256 ballotsProcessed;                      // cursor into voters[]
    int256[] pairwiseFlat;                         // C×C matrix flattened; pairwise[i*C+j] = sum of voter weights for i preferred to j
    int256[] copelandScores;                       // size C; +1 win / -1 loss / 0 tie per pair
    int256[] marginSums;                           // size C; tiebreaker
    uint8[] finalRanking;                          // size C; set in finalize()
}
```

**Why flat matrix:** Solidity 2D dynamic arrays are awkward to read/write efficiently; a flat `int256[]` with explicit `i*C+j` indexing is cheaper and simpler.

**Why `voterIndexPlusOne`:** Lets `castBallot` know if a voter is new (append to `voters[]`) or updating (already in array) in O(1). The `+1` offset distinguishes "not voted" from "index 0."

## 6. Tally Algorithm

Pairwise matrix `M[i][j]` = total voting weight of voters who explicitly ranked candidate `i` above candidate `j`. "Explicitly ranked above" means both `i` and `j` appear in the voter's ranking, and `i` comes before `j`. Pairs involving an unranked candidate contribute nothing.

For each ballot with ranking `r[0..k-1]` and voter weight `w`:
```
for each pair (a, b) where 0 ≤ a < b < k:
    M[r[a]][r[b]] += w
```

Copeland score for candidate `i`:
```
score[i] = sum over j ≠ i of sign(M[i][j] - M[j][i])
          = (# pairs i won) - (# pairs i lost)
```

Margin sum tiebreaker:
```
margin[i] = sum over j ≠ i of (M[i][j] - M[j][i])
```

Final ordering: sort candidates by `(score desc, margin desc, candidate index asc)`. Index ordering is the final deterministic fallback.

### Two-phase batched tally

Tally cannot complete in one tx on mainnet for nontrivial elections. Split into two phases:

**Phase 1 — `tallyBallots(electionId, maxBallots)`:** Iterates `voters[]` from the `ballotsProcessed` cursor, fetches each voter's weight via `votingToken.getPastVotes(voter, snapshotBlock)`, walks the ballot, updates the flat matrix. Advances cursor; returns `true` when all ballots processed. Can be called many times until done.

**Phase 2 — `finalize(electionId)`:** Requires phase 1 done. Walks the C² matrix once to compute `copelandScores[]` and `marginSums[]`. Then performs insertion sort on `[0..C-1]` by the comparator above to produce `finalRanking`. Sets phase to `Finalized`. Single-tx — C ≤ 64 means at most 4096 matrix cells and a tiny sort.

Gas estimate (rough, mainnet pricing):
- Per ballot: ~30k base + k(k-1)/2 SSTORE-adjacent ops + 1 `getPastVotes` external call. For k=10 candidates ranked, ~50k–200k gas.
- For 1000 voters: cumulative ~150M gas, spread across many `tallyBallots` calls (say 50 batches of 20 voters).
- `finalize` with C=30: ~5M gas.

### Why batched only on phase 1

Phase 2 cost is dominated by C, which is bounded to ≤64. Phase 1 cost scales with N voters, which is unbounded. Batching where it matters; keeping the rest simple.

## 7. Voting Power

`votingToken.getPastVotes(voter, snapshotBlock)` returns the voter's voting weight at `snapshotBlock`. Standard `IVotes` semantics. The snapshot is set at election creation and cannot change.

- Zero-weight voters can still call `castBallot` (it just contributes 0 to the matrix). We don't validate weight at cast time — voters might delegate after creation, or accept that their submitted ballot is null. Less surface for griefing reverts.
- Weight is read **only during tally**, not at cast time. This avoids surprises if `getPastVotes` ever reverts (it shouldn't for past blocks past the checkpoint, but defensive).
- Snapshot block must be strictly less than `block.number` at creation time (i.e., a past block). Enforced in `createElection`.

## 8. Validation & Reverts

```
createElection reverts if:
- candidates.length == 0 or > 64
- candidates has duplicates (check via in-memory set)
- snapshotBlock >= block.number
- startTime >= endTime
- endTime <= block.timestamp
- votingToken == address(0)

castBallot reverts if:
- block.timestamp < startTime or > endTime
- election is finalized
- ranking.length > candidates.length
- any ranking[i] >= candidates.length
- ranking contains duplicates

tallyBallots reverts if:
- block.timestamp <= endTime (voting still open)
- phase == Finalized

finalize reverts if:
- phase != Tallying or ballotsProcessed != voters.length
```

Duplicate-in-ranking check: use a 256-bit bitmap (since indices ≤ 63 fit in a single `uint256`). O(k) check, no extra storage.

## 9. Edge Cases

| Case | Behavior |
|---|---|
| No ballots cast | Final ranking = `[0, 1, 2, ..., C-1]` (all scores 0, sorted by index). Finalize succeeds. |
| All voters have 0 weight | Same as above; matrix is all zeros. |
| Empty ballot (`ranking.length == 0`) | Cast succeeds; contributes nothing to matrix. Allowed — equivalent to "I voted but expressed no preferences." |
| Single-candidate ballot | Allowed; contributes nothing (no pairs). |
| Ranking has all C candidates | Standard full ranking; contributes C(C-1)/2 pairs. |
| Two candidates tied on every axis | Finalize uses candidate index as last-resort tiebreaker. Always strict total order. |
| Same voter casts twice | Second cast overwrites first; voter stays at same `voters[]` index. |
| Voter casts then transfers tokens | Doesn't matter — weight is read at `snapshotBlock`, which is fixed in the past. |
| Tally called with `maxBallots = 0` | No-op; returns `done = (ballotsProcessed == voters.length)`. Safe. |

## 10. Security Considerations

- **Reentrancy:** `castBallot` and `tallyBallots` make no external calls except `getPastVotes` (a view), which cannot reenter mutating functions. No reentrancy guards needed.
- **DoS via huge voter lists:** Phase 1 is batched; anyone can advance it. No single-call gas blowup.
- **DoS via huge candidate lists:** Bounded by the `candidates.length <= 64` cap.
- **Front-running election creation:** Permissionless creation means anyone can mint election IDs. Consumers must reference a specific `electionId` they trust (e.g., one they created). The contract does not enforce uniqueness of candidates across elections.
- **Token compatibility:** Assumes `IVotes.getPastVotes` is honest. A malicious token contract can rig results — but that's outside our trust scope; DAOs choose the token they use.
- **Integer math:** Pairwise weights are summed as `int256`. Max possible weight per voter is the token's max supply; sum over 10k voters times 10k pairs is well within `int256` for any realistic token.
- **No upgradeability in v1.** The contract is immutable once deployed. A v2 would require redeployment.

## 11. Testing Strategy

**Unit tests** (forge std):
- `createElection`: each revert path; happy path; event emission; election ID increment.
- `castBallot`: each revert path; replacement (cast twice); zero-length ballot; weight read timing.
- `tallyBallots`: cursor advancement; idempotent when done; batching boundaries; correct matrix updates for known ballots.
- `finalize`: scoring math against precomputed examples; tiebreaker correctness; index fallback; final ranking output.

**Property tests** (forge fuzz):
- Ranking output is a permutation of `[0..C-1]` (all candidates appear exactly once).
- Order is total (no ties left unresolved).
- Deterministic: same inputs → same output.
- Pairwise matrix antisymmetry: `M[i][j]` and `M[j][i]` come from disjoint voter sets per ballot.

**Scenario tests** (named fixtures):
- Condorcet winner exists → wins. (Plant a candidate who beats every other; verify they rank #1.)
- Condorcet cycle (rock-paper-scissors): three candidates each beat one other; verify tiebreaker resolves deterministically.
- ENS Service Provider-style: 12 candidates, 100 voters, varying ballot lengths.
- All ballots replaced before deadline: verify last-write-wins.

**Gas snapshots** (forge snapshot):
- `castBallot` for ranking lengths 1, 5, 10, 30.
- `tallyBallots` for batch sizes 1, 10, 50.
- `finalize` for C = 5, 30, 64.

## 12. Repository Layout

```
copeland-voting/
├── src/
│   ├── CopelandVoting.sol         # main contract
│   ├── interfaces/
│   │   └── ICopelandVoting.sol    # public interface + types
│   └── libraries/
│       └── CopelandTally.sol      # pure scoring helpers (testable in isolation)
├── test/
│   ├── CopelandVoting.t.sol       # main test file
│   ├── CopelandVoting.fuzz.t.sol  # property tests
│   ├── CopelandVoting.scenarios.t.sol # named scenario fixtures
│   └── mocks/
│       └── MockVotesToken.sol     # minimal IVotes for tests
├── script/
│   └── Deploy.s.sol               # deployment script
├── docs/
│   └── superpowers/specs/2026-05-24-copeland-voting-design.md  # this file
├── .github/workflows/ci.yml       # forge build + test on push
├── foundry.toml
├── remappings.txt
├── LICENSE                        # MIT
└── README.md
```

## 13. Out of Scope (v1)

- Commit-reveal voting (public ballots are fine for v1)
- ZK proofs of correct tally (we rely on onchain re-computation)
- Multiple voting methods (Borda, Schulze, IRV) — Copeland only
- Governor adapter — separate concern
- Frontend / subgraph
- Multi-chain deployment scripts (deploy script is mainnet-only)
- Professional security audit (code is production-shaped but unaudited)

## 14. Open Items (deferred decisions, with defaults applied)

| Item | Default | Rationale |
|---|---|---|
| Max candidates per election | 64 | Keeps `finalize` under a few M gas; uint8 indexing covers up to 256 if ever raised. |
| Solidity version | `^0.8.26` | Modern, has transient storage / PUSH0 / etc. Safely deployable on mainnet. |
| License | MIT | OZ ecosystem standard. |
| Naming: `castBallot` vs `vote` | `castBallot` | Avoids confusion with OZ Governor's `castVote(uint8 support)` semantics. |
| Naming: `tallyBallots` + `finalize` vs single `tally` | Split | Two-phase makes the gas model legible to callers. |
| Storage: `voters[]` ordering | Insertion order | Deterministic, no sort needed. |
| Tally permission | Permissionless | Standard for "anyone can advance the state." |
| Finalize permission | Permissionless | Same; the result is deterministic so anyone calling produces the same answer. |
