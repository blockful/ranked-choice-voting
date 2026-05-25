# Copeland Voting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone `CopelandVoting` contract on Ethereum mainnet that runs Copeland-method ranked choice elections weighted by `IVotes` snapshots, with replaceable ballots, lazy batched tally, and a deterministic final ordering of all candidates.

**Architecture:** A single registry contract holds many elections in a `mapping(uint256 => Election)`. Each Election stores candidates, replaceable ballots (overwritten on recast), and a flat int256 pairwise matrix. Tally is two-phase: `tallyBallots` paginates through `voters[]` to populate the matrix; `finalize` computes Copeland scores from the matrix, applies sum-of-margins tiebreaker, and sorts candidate indices into the final ranking. A pure `CopelandTally` library holds the scoring math so it's testable in isolation.

**Tech Stack:** Solidity ^0.8.26, Foundry (forge + forge-std), OpenZeppelin contracts (`IVotes` interface), MIT license.

**Spec:** [`docs/superpowers/specs/2026-05-24-copeland-voting-design.md`](../specs/2026-05-24-copeland-voting-design.md)

---

## File Structure

| File | Responsibility |
|---|---|
| `src/interfaces/ICopelandVoting.sol` | Public interface, structs (`ElectionConfig`, `ElectionView`), `TallyPhase` enum, events |
| `src/libraries/CopelandTally.sol` | Pure helpers: `computeScoresAndMargins(matrix, C)`, `sortRanking(scores, margins, C)` |
| `src/CopelandVoting.sol` | Main contract: storage, lifecycle, voting, tally orchestration, views |
| `test/mocks/MockVotesToken.sol` | Minimal `IVotes` implementation for tests |
| `test/CopelandTally.t.sol` | Library unit tests |
| `test/CopelandVoting.t.sol` | Contract unit tests (lifecycle, validation, basic flows) |
| `test/CopelandVoting.fuzz.t.sol` | Property tests (permutation invariant, determinism) |
| `test/CopelandVoting.scenarios.t.sol` | Named fixtures (Condorcet winner, cycle, ENS-style, replacement) |
| `script/Deploy.s.sol` | Deployment script (mainnet-targeted) |

---

## Task 1: Public Interface

**Files:**
- Create: `src/interfaces/ICopelandVoting.sol`

- [ ] **Step 1: Write the interface file**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface ICopelandVoting {
    enum TallyPhase {
        NotStarted,
        Tallying,
        Finalized
    }

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

    event ElectionCreated(uint256 indexed electionId, address indexed creator, ElectionConfig cfg);
    event BallotCast(uint256 indexed electionId, address indexed voter, uint8[] ranking);
    event TallyProgress(uint256 indexed electionId, uint256 ballotsProcessed, uint256 totalBallots);
    event Finalized(uint256 indexed electionId, uint8[] ranking);

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

    function createElection(ElectionConfig calldata cfg) external returns (uint256 electionId);
    function castBallot(uint256 electionId, uint8[] calldata ranking) external;
    function tallyBallots(uint256 electionId, uint256 maxBallots) external returns (bool done);
    function finalize(uint256 electionId) external;

    function getRanking(uint256 electionId) external view returns (uint8[] memory);
    function getElection(uint256 electionId) external view returns (ElectionView memory);
    function getBallot(uint256 electionId, address voter) external view returns (uint8[] memory);
    function getPairwiseMatrix(uint256 electionId) external view returns (int256[][] memory);
    function getCopelandScores(uint256 electionId) external view returns (int256[] memory);
    function getMarginSums(uint256 electionId) external view returns (int256[] memory);
    function getVoters(uint256 electionId) external view returns (address[] memory);
    function electionCount() external view returns (uint256);

    function MAX_CANDIDATES() external view returns (uint8);
}
```

- [ ] **Step 2: Verify it compiles**

Run: `forge build`
Expected: PASS (interface compiles even without implementation; OZ submodule resolves `IVotes`).

- [ ] **Step 3: Commit**

```bash
git add src/interfaces/ICopelandVoting.sol
git commit -m "feat: public ICopelandVoting interface"
```

---

## Task 2: MockVotesToken for tests

**Files:**
- Create: `test/mocks/MockVotesToken.sol`

- [ ] **Step 1: Write the mock**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @notice Minimal IVotes for testing. Stores a single past-vote weight per (voter, block).
contract MockVotesToken is IVotes {
    mapping(address => mapping(uint256 => uint256)) private _pastVotes;
    mapping(uint256 => uint256) private _pastTotalSupply;
    mapping(address => address) private _delegates;

    function setPastVotes(address account, uint256 blockNumber, uint256 weight) external {
        _pastVotes[account][blockNumber] = weight;
    }

    function setPastTotalSupply(uint256 blockNumber, uint256 supply) external {
        _pastTotalSupply[blockNumber] = supply;
    }

    function getVotes(address account) external view returns (uint256) {
        return _pastVotes[account][block.number];
    }

    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        return _pastVotes[account][timepoint];
    }

    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        return _pastTotalSupply[timepoint];
    }

    function delegates(address account) external view returns (address) {
        return _delegates[account];
    }

    function delegate(address delegatee) external {
        _delegates[msg.sender] = delegatee;
    }

    function delegateBySig(
        address delegatee,
        uint256, // nonce
        uint256, // expiry
        uint8,   // v
        bytes32, // r
        bytes32  // s
    ) external {
        _delegates[msg.sender] = delegatee;
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `forge build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/mocks/MockVotesToken.sol
git commit -m "test: MockVotesToken implementing IVotes for unit tests"
```

---

## Task 3: CopelandTally library — sortRanking

**Files:**
- Create: `src/libraries/CopelandTally.sol`
- Create: `test/CopelandTally.t.sol`

- [ ] **Step 1: Write the failing test for sortRanking**

Create `test/CopelandTally.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CopelandTally} from "../src/libraries/CopelandTally.sol";

contract CopelandTallyTest is Test {
    function test_sortRanking_strictScoreOrder() public pure {
        int256[] memory scores = new int256[](3);
        int256[] memory margins = new int256[](3);
        scores[0] = 1;  margins[0] = 0;
        scores[1] = 2;  margins[1] = 0;
        scores[2] = 0;  margins[2] = 0;
        uint8[] memory r = CopelandTally.sortRanking(scores, margins);
        assertEq(r[0], 1);
        assertEq(r[1], 0);
        assertEq(r[2], 2);
    }

    function test_sortRanking_marginTiebreaker() public pure {
        int256[] memory scores = new int256[](3);
        int256[] memory margins = new int256[](3);
        scores[0] = 1;  margins[0] = 5;
        scores[1] = 1;  margins[1] = 10;
        scores[2] = 1;  margins[2] = 1;
        uint8[] memory r = CopelandTally.sortRanking(scores, margins);
        assertEq(r[0], 1);
        assertEq(r[1], 0);
        assertEq(r[2], 2);
    }

    function test_sortRanking_indexFallback() public pure {
        int256[] memory scores = new int256[](3);
        int256[] memory margins = new int256[](3);
        // all tied → ascending index order
        uint8[] memory r = CopelandTally.sortRanking(scores, margins);
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    function test_sortRanking_negativeScores() public pure {
        int256[] memory scores = new int256[](3);
        int256[] memory margins = new int256[](3);
        scores[0] = -2; margins[0] = -10;
        scores[1] = 0;  margins[1] = 0;
        scores[2] = 2;  margins[2] = 10;
        uint8[] memory r = CopelandTally.sortRanking(scores, margins);
        assertEq(r[0], 2);
        assertEq(r[1], 1);
        assertEq(r[2], 0);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-contract CopelandTallyTest -vv`
Expected: FAIL with compile error (CopelandTally library doesn't exist yet).

- [ ] **Step 3: Implement sortRanking (only)**

Create `src/libraries/CopelandTally.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CopelandTally
/// @notice Pure functions implementing Copeland-method tally math.
library CopelandTally {
    /// @notice Sort candidate indices by (score desc, margin desc, index asc).
    /// @dev Insertion sort — input sizes are bounded (C <= 64).
    /// @param scores Copeland scores per candidate (length = C)
    /// @param margins Sum of pairwise margins per candidate (length = C; same order as scores)
    /// @return ranking Candidate indices ordered most-preferred first
    function sortRanking(int256[] memory scores, int256[] memory margins)
        internal
        pure
        returns (uint8[] memory ranking)
    {
        uint256 c = scores.length;
        require(c == margins.length, "length mismatch");
        ranking = new uint8[](c);
        for (uint256 i = 0; i < c; i++) {
            ranking[i] = uint8(i);
        }
        // insertion sort: for each i, bubble ranking[i] leftward into place
        for (uint256 i = 1; i < c; i++) {
            uint8 cur = ranking[i];
            uint256 j = i;
            while (j > 0 && _isGreater(cur, ranking[j - 1], scores, margins)) {
                ranking[j] = ranking[j - 1];
                j--;
            }
            ranking[j] = cur;
        }
    }

    /// @dev True iff candidate `a` ranks above candidate `b` by (score, margin, index).
    function _isGreater(uint8 a, uint8 b, int256[] memory scores, int256[] memory margins)
        private
        pure
        returns (bool)
    {
        if (scores[a] != scores[b]) return scores[a] > scores[b];
        if (margins[a] != margins[b]) return margins[a] > margins[b];
        return a < b;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CopelandTallyTest -vv`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/libraries/CopelandTally.sol test/CopelandTally.t.sol
git commit -m "feat: CopelandTally.sortRanking with score+margin+index ordering"
```

---

## Task 4: CopelandTally library — computeScoresAndMargins

**Files:**
- Modify: `src/libraries/CopelandTally.sol`
- Modify: `test/CopelandTally.t.sol`

- [ ] **Step 1: Add failing tests for computeScoresAndMargins**

Append to `test/CopelandTally.t.sol` (inside the `CopelandTallyTest` contract):

```solidity
    function test_computeScoresAndMargins_simpleWin() public pure {
        // 2 candidates, A beats B with weight 100 vs 0
        int256[] memory matrix = new int256[](4); // C=2 → 2*2
        matrix[0 * 2 + 1] = 100; // A > B = 100
        matrix[1 * 2 + 0] = 0;   // B > A = 0
        (int256[] memory scores, int256[] memory margins) = CopelandTally.computeScoresAndMargins(matrix, 2);
        assertEq(scores[0], 1);
        assertEq(scores[1], -1);
        assertEq(margins[0], 100);
        assertEq(margins[1], -100);
    }

    function test_computeScoresAndMargins_threeWayTie() public pure {
        // 3 candidates, each pair tied 50-50
        int256[] memory matrix = new int256[](9); // C=3 → 3*3
        matrix[0 * 3 + 1] = 50; matrix[1 * 3 + 0] = 50;
        matrix[0 * 3 + 2] = 50; matrix[2 * 3 + 0] = 50;
        matrix[1 * 3 + 2] = 50; matrix[2 * 3 + 1] = 50;
        (int256[] memory scores, int256[] memory margins) = CopelandTally.computeScoresAndMargins(matrix, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(scores[i], 0);
            assertEq(margins[i], 0);
        }
    }

    function test_computeScoresAndMargins_condorcetWinner() public pure {
        // 3 candidates, A beats both B and C; B beats C
        int256[] memory matrix = new int256[](9);
        matrix[0 * 3 + 1] = 60; matrix[1 * 3 + 0] = 40; // A>B 60-40
        matrix[0 * 3 + 2] = 70; matrix[2 * 3 + 0] = 30; // A>C 70-30
        matrix[1 * 3 + 2] = 55; matrix[2 * 3 + 1] = 45; // B>C 55-45
        (int256[] memory scores, int256[] memory margins) = CopelandTally.computeScoresAndMargins(matrix, 3);
        assertEq(scores[0], 2);  // A wins both
        assertEq(scores[1], 0);  // B wins one, loses one
        assertEq(scores[2], -2); // C loses both
        assertEq(margins[0], (60 - 40) + (70 - 30));   // +50
        assertEq(margins[1], (40 - 60) + (55 - 45));   // -10
        assertEq(margins[2], (30 - 70) + (45 - 55));   // -50
    }

    function test_computeScoresAndMargins_emptyMatrix() public pure {
        int256[] memory matrix = new int256[](9);
        (int256[] memory scores, int256[] memory margins) = CopelandTally.computeScoresAndMargins(matrix, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(scores[i], 0);
            assertEq(margins[i], 0);
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract CopelandTallyTest -vv`
Expected: FAIL (function doesn't exist).

- [ ] **Step 3: Implement computeScoresAndMargins**

Append to `src/libraries/CopelandTally.sol` (inside the `CopelandTally` library, after `sortRanking`):

```solidity
    /// @notice Compute Copeland scores and sum-of-margin tiebreakers from a flat pairwise matrix.
    /// @param matrix Flat C*C matrix; matrix[i*C+j] = total weight of voters who explicitly preferred i over j.
    /// @param c Candidate count.
    /// @return scores Copeland score per candidate (+1 win, -1 loss, 0 tie, summed across opponents).
    /// @return margins Sum of (M[i][j] - M[j][i]) across all opponents, for use as tiebreaker.
    function computeScoresAndMargins(int256[] memory matrix, uint256 c)
        internal
        pure
        returns (int256[] memory scores, int256[] memory margins)
    {
        require(matrix.length == c * c, "matrix size");
        scores = new int256[](c);
        margins = new int256[](c);
        for (uint256 i = 0; i < c; i++) {
            for (uint256 j = 0; j < c; j++) {
                if (i == j) continue;
                int256 m = matrix[i * c + j] - matrix[j * c + i];
                margins[i] += m;
                if (m > 0) {
                    scores[i] += 1;
                } else if (m < 0) {
                    scores[i] -= 1;
                }
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CopelandTallyTest -vv`
Expected: PASS (8 tests total).

- [ ] **Step 5: Commit**

```bash
git add src/libraries/CopelandTally.sol test/CopelandTally.t.sol
git commit -m "feat: CopelandTally.computeScoresAndMargins from flat pairwise matrix"
```

---

## Task 5: CopelandVoting scaffold + createElection happy path

**Files:**
- Create: `src/CopelandVoting.sol`
- Create: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Write the failing test**

Create `test/CopelandVoting.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";
import {ICopelandVoting} from "../src/interfaces/ICopelandVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract CopelandVotingTest is Test {
    CopelandVoting internal voting;
    MockVotesToken internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB   = address(0xB0B);
    address internal constant CAROL = address(0xCA801);

    function setUp() public {
        voting = new CopelandVoting();
        token = new MockVotesToken();
        // Advance one block so snapshotBlock = block.number - 1 is valid
        vm.roll(block.number + 1);
    }

    function _baseConfig() internal view returns (ICopelandVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](3);
        cands[0] = keccak256("Alice");
        cands[1] = keccak256("Bob");
        cands[2] = keccak256("Carol");
        cfg = ICopelandVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: block.number - 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            metadataURI: bytes32(0)
        });
    }

    function test_createElection_assignsId0AndIncrementsCounter() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        assertEq(id, 0);
        assertEq(voting.electionCount(), 1);

        uint256 id2 = voting.createElection(cfg);
        assertEq(id2, 1);
        assertEq(voting.electionCount(), 2);
    }

    function test_createElection_emitsEvent() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        vm.expectEmit(true, true, false, true);
        emit ICopelandVoting.ElectionCreated(0, address(this), cfg);
        voting.createElection(cfg);
    }

    function test_createElection_storesConfig() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        ICopelandVoting.ElectionView memory v = voting.getElection(id);
        assertEq(v.candidates.length, 3);
        assertEq(v.candidates[0], cfg.candidates[0]);
        assertEq(address(v.votingToken), address(token));
        assertEq(v.snapshotBlock, cfg.snapshotBlock);
        assertEq(v.startTime, cfg.startTime);
        assertEq(v.endTime, cfg.endTime);
        assertEq(v.metadataURI, cfg.metadataURI);
        assertEq(v.creator, address(this));
        assertEq(v.voterCount, 0);
        assertEq(uint8(v.phase), uint8(ICopelandVoting.TallyPhase.NotStarted));
        assertEq(v.ballotsProcessed, 0);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: FAIL — CopelandVoting contract doesn't exist.

- [ ] **Step 3: Implement minimal CopelandVoting with createElection + getElection + electionCount**

Create `src/CopelandVoting.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ICopelandVoting} from "./interfaces/ICopelandVoting.sol";

/// @title CopelandVoting
/// @notice Onchain Copeland-method ranked choice voting for DAOs.
contract CopelandVoting is ICopelandVoting {
    uint8 public constant MAX_CANDIDATES = 64;

    struct Election {
        // immutable config
        bytes32[] candidates;
        IVotes votingToken;
        uint256 snapshotBlock;
        uint64 startTime;
        uint64 endTime;
        bytes32 metadataURI;
        address creator;
        // ballot storage
        address[] voters;
        mapping(address => uint8[]) ballots;
        mapping(address => uint256) voterIndexPlusOne;
        // tally state
        TallyPhase phase;
        uint256 ballotsProcessed;
        int256[] pairwiseFlat;
        int256[] copelandScores;
        int256[] marginSums;
        uint8[] finalRanking;
    }

    mapping(uint256 => Election) private _elections;
    uint256 private _electionCount;

    function electionCount() external view returns (uint256) {
        return _electionCount;
    }

    function createElection(ElectionConfig calldata cfg) external returns (uint256 electionId) {
        electionId = _electionCount;
        Election storage e = _elections[electionId];
        e.candidates = cfg.candidates;
        e.votingToken = cfg.votingToken;
        e.snapshotBlock = cfg.snapshotBlock;
        e.startTime = cfg.startTime;
        e.endTime = cfg.endTime;
        e.metadataURI = cfg.metadataURI;
        e.creator = msg.sender;
        e.pairwiseFlat = new int256[](cfg.candidates.length * cfg.candidates.length);
        unchecked {
            _electionCount = electionId + 1;
        }
        emit ElectionCreated(electionId, msg.sender, cfg);
    }

    function getElection(uint256 electionId) external view returns (ElectionView memory v) {
        Election storage e = _elections[electionId];
        v = ElectionView({
            candidates: e.candidates,
            votingToken: e.votingToken,
            snapshotBlock: e.snapshotBlock,
            startTime: e.startTime,
            endTime: e.endTime,
            metadataURI: e.metadataURI,
            creator: e.creator,
            voterCount: e.voters.length,
            phase: e.phase,
            ballotsProcessed: e.ballotsProcessed
        });
    }

    // --- stubs (to be implemented in later tasks) ---

    function castBallot(uint256, uint8[] calldata) external pure {
        revert("not implemented");
    }

    function tallyBallots(uint256, uint256) external pure returns (bool) {
        revert("not implemented");
    }

    function finalize(uint256) external pure {
        revert("not implemented");
    }

    function getRanking(uint256) external pure returns (uint8[] memory) {
        revert("not implemented");
    }

    function getBallot(uint256, address) external pure returns (uint8[] memory) {
        revert("not implemented");
    }

    function getPairwiseMatrix(uint256) external pure returns (int256[][] memory) {
        revert("not implemented");
    }

    function getCopelandScores(uint256) external pure returns (int256[] memory) {
        revert("not implemented");
    }

    function getMarginSums(uint256) external pure returns (int256[] memory) {
        revert("not implemented");
    }

    function getVoters(uint256) external pure returns (address[] memory) {
        revert("not implemented");
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/CopelandVoting.sol test/CopelandVoting.t.sol
git commit -m "feat: CopelandVoting scaffold + createElection happy path"
```

---

## Task 6: createElection validation reverts

**Files:**
- Modify: `src/CopelandVoting.sol` (createElection)
- Modify: `test/CopelandVoting.t.sol` (add revert tests)

- [ ] **Step 1: Add failing tests for each revert path**

Append to `CopelandVotingTest` in `test/CopelandVoting.t.sol`:

```solidity
    function test_createElection_revertsOnEmptyCandidates() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates = new bytes32[](0);
        vm.expectRevert(ICopelandVoting.EmptyCandidates.selector);
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnTooManyCandidates() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates = new bytes32[](65);
        for (uint256 i = 0; i < 65; i++) cfg.candidates[i] = bytes32(i + 1);
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.TooManyCandidates.selector, 65, 64));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnDuplicateCandidate() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates[2] = cfg.candidates[0]; // duplicate
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.DuplicateCandidate.selector, cfg.candidates[0]));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnFutureSnapshotBlock() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.snapshotBlock = block.number; // not strictly past
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.InvalidSnapshotBlock.selector, block.number, block.number));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnInvalidTimeWindow() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.endTime = cfg.startTime; // not strictly greater
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.InvalidTimeWindow.selector, cfg.startTime, cfg.endTime));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnEndTimeInPast() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        vm.warp(cfg.endTime + 1);
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.EndTimeInPast.selector, cfg.endTime, block.timestamp));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnZeroToken() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.votingToken = IVotes(address(0));
        vm.expectRevert(ICopelandVoting.ZeroToken.selector);
        voting.createElection(cfg);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: 7 new tests FAIL (no validation present yet).

- [ ] **Step 3: Add validation to createElection**

Edit `src/CopelandVoting.sol`. Replace the `createElection` body with:

```solidity
    function createElection(ElectionConfig calldata cfg) external returns (uint256 electionId) {
        uint256 c = cfg.candidates.length;
        if (c == 0) revert EmptyCandidates();
        if (c > MAX_CANDIDATES) revert TooManyCandidates(c, MAX_CANDIDATES);
        if (address(cfg.votingToken) == address(0)) revert ZeroToken();
        if (cfg.snapshotBlock >= block.number) revert InvalidSnapshotBlock(cfg.snapshotBlock, block.number);
        if (cfg.startTime >= cfg.endTime) revert InvalidTimeWindow(cfg.startTime, cfg.endTime);
        if (cfg.endTime <= block.timestamp) revert EndTimeInPast(cfg.endTime, block.timestamp);

        // Duplicate-candidate check: O(c^2) is fine since c <= 64
        for (uint256 i = 0; i < c; i++) {
            for (uint256 j = i + 1; j < c; j++) {
                if (cfg.candidates[i] == cfg.candidates[j]) {
                    revert DuplicateCandidate(cfg.candidates[i]);
                }
            }
        }

        electionId = _electionCount;
        Election storage e = _elections[electionId];
        e.candidates = cfg.candidates;
        e.votingToken = cfg.votingToken;
        e.snapshotBlock = cfg.snapshotBlock;
        e.startTime = cfg.startTime;
        e.endTime = cfg.endTime;
        e.metadataURI = cfg.metadataURI;
        e.creator = msg.sender;
        e.pairwiseFlat = new int256[](c * c);
        unchecked {
            _electionCount = electionId + 1;
        }
        emit ElectionCreated(electionId, msg.sender, cfg);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (all 10 tests in CopelandVotingTest).

- [ ] **Step 5: Commit**

```bash
git add src/CopelandVoting.sol test/CopelandVoting.t.sol
git commit -m "feat: createElection input validation"
```

---

## Task 7: castBallot happy path

**Files:**
- Modify: `src/CopelandVoting.sol` (replace castBallot stub; add getBallot + getVoters)
- Modify: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Add failing tests**

Append to `CopelandVotingTest`:

```solidity
    function test_castBallot_storesRankingAndAppendsVoter() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](3);
        r[0] = 2; r[1] = 0; r[2] = 1;

        vm.prank(ALICE);
        voting.castBallot(id, r);

        uint8[] memory stored = voting.getBallot(id, ALICE);
        assertEq(stored.length, 3);
        assertEq(stored[0], 2);
        assertEq(stored[1], 0);
        assertEq(stored[2], 1);

        address[] memory vs = voting.getVoters(id);
        assertEq(vs.length, 1);
        assertEq(vs[0], ALICE);
    }

    function test_castBallot_emitsEvent() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](2);
        r[0] = 0; r[1] = 1;

        vm.expectEmit(true, true, false, true);
        emit ICopelandVoting.BallotCast(id, ALICE, r);
        vm.prank(ALICE);
        voting.castBallot(id, r);
    }

    function test_castBallot_emptyBallotAllowed() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](0);
        vm.prank(ALICE);
        voting.castBallot(id, r);
        assertEq(voting.getBallot(id, ALICE).length, 0);
        assertEq(voting.getVoters(id).length, 1);
    }

    function test_castBallot_multipleVotersAppendInOrder() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](1);
        r[0] = 0;
        vm.prank(ALICE); voting.castBallot(id, r);
        vm.prank(BOB);   voting.castBallot(id, r);
        vm.prank(CAROL); voting.castBallot(id, r);
        address[] memory vs = voting.getVoters(id);
        assertEq(vs.length, 3);
        assertEq(vs[0], ALICE);
        assertEq(vs[1], BOB);
        assertEq(vs[2], CAROL);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: 4 new tests FAIL.

- [ ] **Step 3: Implement castBallot + getBallot + getVoters**

In `src/CopelandVoting.sol`, replace the three stubs (`castBallot`, `getBallot`, `getVoters`) with:

```solidity
    function castBallot(uint256 electionId, uint8[] calldata ranking) external {
        Election storage e = _elections[electionId];
        if (e.candidates.length == 0) revert UnknownElection(electionId);
        // (Time window / phase / index validation added in Task 9)

        e.ballots[msg.sender] = ranking;
        if (e.voterIndexPlusOne[msg.sender] == 0) {
            e.voters.push(msg.sender);
            e.voterIndexPlusOne[msg.sender] = e.voters.length; // 1-based
        }
        emit BallotCast(electionId, msg.sender, ranking);
    }

    function getBallot(uint256 electionId, address voter) external view returns (uint8[] memory) {
        return _elections[electionId].ballots[voter];
    }

    function getVoters(uint256 electionId) external view returns (address[] memory) {
        return _elections[electionId].voters;
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (all 14 tests).

- [ ] **Step 5: Commit**

```bash
git add src/CopelandVoting.sol test/CopelandVoting.t.sol
git commit -m "feat: castBallot happy path + getBallot/getVoters"
```

---

## Task 8: castBallot replacement (recast overwrites)

**Files:**
- Modify: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Add failing tests for replacement**

Append to `CopelandVotingTest`:

```solidity
    function test_castBallot_recastOverwrites() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r1 = new uint8[](2);
        r1[0] = 0; r1[1] = 1;
        uint8[] memory r2 = new uint8[](3);
        r2[0] = 2; r2[1] = 1; r2[2] = 0;

        vm.startPrank(ALICE);
        voting.castBallot(id, r1);
        voting.castBallot(id, r2);
        vm.stopPrank();

        uint8[] memory stored = voting.getBallot(id, ALICE);
        assertEq(stored.length, 3);
        assertEq(stored[0], 2);
        assertEq(stored[1], 1);
        assertEq(stored[2], 0);

        address[] memory vs = voting.getVoters(id);
        assertEq(vs.length, 1);
        assertEq(vs[0], ALICE);
    }
```

- [ ] **Step 2: Run tests to verify they pass already**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS — replacement already works because Task 7's `castBallot` overwrites via `e.ballots[msg.sender] = ranking;` and skips re-append when `voterIndexPlusOne != 0`. This test locks in that behavior.

- [ ] **Step 3: Commit**

```bash
git add test/CopelandVoting.t.sol
git commit -m "test: castBallot recast overwrites previous ballot"
```

---

## Task 9: castBallot validation reverts

**Files:**
- Modify: `src/CopelandVoting.sol` (castBallot)
- Modify: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Add failing tests**

Append to `CopelandVotingTest`:

```solidity
    function test_castBallot_revertsOnUnknownElection() public {
        uint8[] memory r = new uint8[](1);
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.UnknownElection.selector, 42));
        voting.castBallot(42, r);
    }

    function test_castBallot_revertsBeforeStart() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.startTime = uint64(block.timestamp + 1 hours);
        cfg.endTime   = uint64(block.timestamp + 2 hours);
        uint256 id = voting.createElection(cfg);
        uint8[] memory r = new uint8[](1);
        vm.expectRevert(abi.encodeWithSelector(
            ICopelandVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp
        ));
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsAfterEnd() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        uint8[] memory r = new uint8[](1);
        vm.expectRevert(abi.encodeWithSelector(
            ICopelandVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp
        ));
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsRankingTooLong() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](4); // candidates.length is 3
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.RankingTooLong.selector, 4, 3));
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsOutOfBoundsIndex() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](1);
        r[0] = 3; // candidate count is 3 → valid indices are 0,1,2
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.CandidateIndexOutOfBounds.selector, 3, 3));
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsDuplicateRanking() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](3);
        r[0] = 1; r[1] = 0; r[2] = 1; // duplicate of 1
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.DuplicateRanking.selector, 1));
        voting.castBallot(id, r);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: 6 new tests FAIL.

- [ ] **Step 3: Add validation to castBallot**

Replace `castBallot` in `src/CopelandVoting.sol`:

```solidity
    function castBallot(uint256 electionId, uint8[] calldata ranking) external {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        if (c == 0) revert UnknownElection(electionId);
        if (e.phase == TallyPhase.Finalized) revert ElectionFinalized();
        if (block.timestamp < e.startTime || block.timestamp > e.endTime) {
            revert VotingNotOpen(e.startTime, e.endTime, block.timestamp);
        }
        if (ranking.length > c) revert RankingTooLong(ranking.length, c);

        // Duplicate check via bitmap. MAX_CANDIDATES <= 256 → single uint256 is enough,
        // but use uint256(1) << index pattern which works for any uint8.
        uint256 seen;
        for (uint256 i = 0; i < ranking.length; i++) {
            uint8 idx = ranking[i];
            if (idx >= c) revert CandidateIndexOutOfBounds(idx, c);
            uint256 bit = uint256(1) << idx;
            if (seen & bit != 0) revert DuplicateRanking(idx);
            seen |= bit;
        }

        e.ballots[msg.sender] = ranking;
        if (e.voterIndexPlusOne[msg.sender] == 0) {
            e.voters.push(msg.sender);
            e.voterIndexPlusOne[msg.sender] = e.voters.length;
        }
        emit BallotCast(electionId, msg.sender, ranking);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (all 20 tests).

- [ ] **Step 5: Commit**

```bash
git add src/CopelandVoting.sol test/CopelandVoting.t.sol
git commit -m "feat: castBallot validation (time, phase, length, bounds, duplicates)"
```

---

## Task 10: tallyBallots happy path (single call)

**Files:**
- Modify: `src/CopelandVoting.sol` (tallyBallots)
- Modify: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Add failing tests**

Append to `CopelandVotingTest`:

```solidity
    function _giveWeight(address voter, uint256 snapshotBlock, uint256 weight) internal {
        token.setPastVotes(voter, snapshotBlock, weight);
    }

    function test_tallyBallots_singleCallBuildsMatrix() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 100);
        _giveWeight(BOB,   cfg.snapshotBlock, 50);

        // Alice ranks 0>1>2
        uint8[] memory ra = new uint8[](3);
        ra[0] = 0; ra[1] = 1; ra[2] = 2;
        vm.prank(ALICE); voting.castBallot(id, ra);

        // Bob ranks 2>1 (partial, says nothing about 0)
        uint8[] memory rb = new uint8[](2);
        rb[0] = 2; rb[1] = 1;
        vm.prank(BOB); voting.castBallot(id, rb);

        vm.warp(cfg.endTime + 1);
        bool done = voting.tallyBallots(id, 10);
        assertTrue(done);

        int256[][] memory M = voting.getPairwiseMatrix(id);
        assertEq(M.length, 3);
        // From Alice: (0,1)+=100, (0,2)+=100, (1,2)+=100
        // From Bob:   (2,1)+=50
        assertEq(M[0][1], 100);
        assertEq(M[0][2], 100);
        assertEq(M[1][2], 100);
        assertEq(M[2][1], 50);
        // Diagonal and unstated entries stay 0
        assertEq(M[0][0], 0);
        assertEq(M[1][0], 0);
        assertEq(M[2][0], 0);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-test test_tallyBallots_singleCallBuildsMatrix -vv`
Expected: FAIL — tallyBallots/getPairwiseMatrix still stubbed.

- [ ] **Step 3: Implement tallyBallots + getPairwiseMatrix**

In `src/CopelandVoting.sol`, replace the `tallyBallots` and `getPairwiseMatrix` stubs:

```solidity
    function tallyBallots(uint256 electionId, uint256 maxBallots) external returns (bool done) {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        if (c == 0) revert UnknownElection(electionId);
        if (e.phase == TallyPhase.Finalized) revert TallyAlreadyFinalized();
        if (block.timestamp <= e.endTime) revert VotingStillOpen(e.endTime, block.timestamp);

        if (e.phase == TallyPhase.NotStarted) e.phase = TallyPhase.Tallying;

        uint256 total = e.voters.length;
        uint256 cursor = e.ballotsProcessed;
        if (cursor >= total) {
            return true;
        }
        uint256 end = cursor + maxBallots;
        if (end > total) end = total;

        for (uint256 vi = cursor; vi < end; vi++) {
            address voter = e.voters[vi];
            uint256 weight = e.votingToken.getPastVotes(voter, e.snapshotBlock);
            if (weight == 0) continue;
            uint8[] storage ranking = e.ballots[voter];
            uint256 k = ranking.length;
            for (uint256 a = 0; a < k; a++) {
                uint8 ia = ranking[a];
                for (uint256 b = a + 1; b < k; b++) {
                    uint8 ib = ranking[b];
                    e.pairwiseFlat[uint256(ia) * c + uint256(ib)] += int256(weight);
                }
            }
        }

        e.ballotsProcessed = end;
        emit TallyProgress(electionId, end, total);
        done = end == total;
    }

    function getPairwiseMatrix(uint256 electionId) external view returns (int256[][] memory matrix) {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        matrix = new int256[][](c);
        for (uint256 i = 0; i < c; i++) {
            int256[] memory row = new int256[](c);
            for (uint256 j = 0; j < c; j++) {
                row[j] = e.pairwiseFlat[i * c + j];
            }
            matrix[i] = row;
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (all 21 tests).

- [ ] **Step 5: Commit**

```bash
git add src/CopelandVoting.sol test/CopelandVoting.t.sol
git commit -m "feat: tallyBallots single-call + getPairwiseMatrix"
```

---

## Task 11: tallyBallots batched across calls

**Files:**
- Modify: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Add failing tests**

Append to `CopelandVotingTest`:

```solidity
    function test_tallyBallots_batchedAcrossCalls() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);

        // 5 voters, weight 1 each, all ranking 0>1>2
        address[5] memory voters = [
            address(0x1), address(0x2), address(0x3), address(0x4), address(0x5)
        ];
        uint8[] memory r = new uint8[](3);
        r[0] = 0; r[1] = 1; r[2] = 2;
        for (uint256 i = 0; i < 5; i++) {
            _giveWeight(voters[i], cfg.snapshotBlock, 1);
            vm.prank(voters[i]); voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        assertFalse(voting.tallyBallots(id, 2));
        assertFalse(voting.tallyBallots(id, 2));
        assertTrue (voting.tallyBallots(id, 2));
        // Once done, further calls return true and are idempotent
        assertTrue (voting.tallyBallots(id, 50));

        int256[][] memory M = voting.getPairwiseMatrix(id);
        assertEq(M[0][1], 5);
        assertEq(M[0][2], 5);
        assertEq(M[1][2], 5);
    }

    function test_tallyBallots_zeroMaxIsNoop() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 10);
        uint8[] memory r = new uint8[](1); r[0] = 0;
        vm.prank(ALICE); voting.castBallot(id, r);
        vm.warp(cfg.endTime + 1);
        assertFalse(voting.tallyBallots(id, 0));
        assertEq(voting.getElection(id).ballotsProcessed, 0);
    }

    function test_tallyBallots_zeroWeightVoterContributesNothing() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        // ALICE has weight 0 (default); BOB has weight 7
        _giveWeight(BOB, cfg.snapshotBlock, 7);
        uint8[] memory r = new uint8[](2); r[0] = 0; r[1] = 1;
        vm.prank(ALICE); voting.castBallot(id, r);
        vm.prank(BOB);   voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        int256[][] memory M = voting.getPairwiseMatrix(id);
        assertEq(M[0][1], 7);
        assertEq(M[1][0], 0);
    }
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (the implementation from Task 10 already supports batching).

- [ ] **Step 3: Commit**

```bash
git add test/CopelandVoting.t.sol
git commit -m "test: tallyBallots batching + zero-weight + zero-max behaviors"
```

---

## Task 12: tallyBallots reverts

**Files:**
- Modify: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Add failing tests**

Append to `CopelandVotingTest`:

```solidity
    function test_tallyBallots_revertsBeforeEndTime() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.VotingStillOpen.selector, cfg.endTime, block.timestamp));
        voting.tallyBallots(id, 10);
    }

    function test_tallyBallots_revertsOnUnknownElection() public {
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.UnknownElection.selector, 99));
        voting.tallyBallots(99, 10);
    }
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (implementation already enforces these).

- [ ] **Step 3: Commit**

```bash
git add test/CopelandVoting.t.sol
git commit -m "test: tallyBallots reverts when voting still open / unknown id"
```

---

## Task 13: finalize

**Files:**
- Modify: `src/CopelandVoting.sol` (finalize, getRanking, getCopelandScores, getMarginSums)
- Modify: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Add failing tests**

Append to `CopelandVotingTest`:

```solidity
    function test_finalize_setsPhaseAndRanking() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 10);

        uint8[] memory r = new uint8[](3);
        r[0] = 1; r[1] = 0; r[2] = 2; // Alice: 1>0>2
        vm.prank(ALICE); voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);

        vm.expectEmit(true, false, false, false);
        emit ICopelandVoting.Finalized(id, new uint8[](0)); // payload not strictly checked
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking.length, 3);
        assertEq(ranking[0], 1); // candidate 1 wins (beats 0 and 2)
        assertEq(ranking[1], 0); // candidate 0 second (beats 2)
        assertEq(ranking[2], 2); // candidate 2 last

        ICopelandVoting.ElectionView memory v = voting.getElection(id);
        assertEq(uint8(v.phase), uint8(ICopelandVoting.TallyPhase.Finalized));

        int256[] memory scores = voting.getCopelandScores(id);
        assertEq(scores[1], 2);
        assertEq(scores[0], 0);
        assertEq(scores[2], -2);

        int256[] memory margins = voting.getMarginSums(id);
        // candidate 1: (10 vs 0) over 0 + (10 vs 0) over 2 = +20
        assertEq(margins[1], 20);
    }

    function test_finalize_revertsIfTallyNotComplete() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        // No voters at all → ballotsProcessed (0) == voters.length (0), so finalize should SUCCEED.
        // To test the revert: add a voter, partial tally, then try finalize.
        _giveWeight(ALICE, cfg.snapshotBlock, 1);
        uint8[] memory r = new uint8[](1); r[0] = 0;
        vm.prank(ALICE); voting.castBallot(id, r);
        // Add a second voter we won't process
        _giveWeight(BOB, cfg.snapshotBlock, 1);
        vm.prank(BOB); voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 1); // process only 1 of 2
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.TallyNotComplete.selector, 1, 2));
        voting.finalize(id);
    }

    function test_finalize_revertsIfAlreadyFinalized() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);
        vm.expectRevert(ICopelandVoting.TallyAlreadyFinalized.selector);
        voting.finalize(id);
    }

    function test_finalize_noBallotsYieldsIdentityRanking() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);
        uint8[] memory r = voting.getRanking(id);
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: 4 new tests FAIL.

- [ ] **Step 3: Implement finalize + score/margin/ranking getters**

In `src/CopelandVoting.sol`:
- Add an import at the top: `import {CopelandTally} from "./libraries/CopelandTally.sol";`
- Replace the `finalize`, `getRanking`, `getCopelandScores`, `getMarginSums` stubs with:

```solidity
    function finalize(uint256 electionId) external {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        if (c == 0) revert UnknownElection(electionId);
        if (e.phase == TallyPhase.Finalized) revert TallyAlreadyFinalized();
        if (block.timestamp <= e.endTime) revert VotingStillOpen(e.endTime, block.timestamp);
        // Auto-advance phase to Tallying if there are no voters (so the check below holds trivially).
        if (e.phase == TallyPhase.NotStarted) e.phase = TallyPhase.Tallying;
        if (e.ballotsProcessed != e.voters.length) {
            revert TallyNotComplete(e.ballotsProcessed, e.voters.length);
        }

        (int256[] memory scores, int256[] memory margins) =
            CopelandTally.computeScoresAndMargins(e.pairwiseFlat, c);
        uint8[] memory ranking = CopelandTally.sortRanking(scores, margins);

        e.copelandScores = scores;
        e.marginSums = margins;
        e.finalRanking = ranking;
        e.phase = TallyPhase.Finalized;
        emit Finalized(electionId, ranking);
    }

    function getRanking(uint256 electionId) external view returns (uint8[] memory) {
        return _elections[electionId].finalRanking;
    }

    function getCopelandScores(uint256 electionId) external view returns (int256[] memory) {
        return _elections[electionId].copelandScores;
    }

    function getMarginSums(uint256 electionId) external view returns (int256[] memory) {
        return _elections[electionId].marginSums;
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (all 27 tests).

- [ ] **Step 5: Commit**

```bash
git add src/CopelandVoting.sol test/CopelandVoting.t.sol
git commit -m "feat: finalize + ranking/score/margin getters via CopelandTally"
```

---

## Task 14: Castability after voting closes

**Files:**
- Modify: `test/CopelandVoting.t.sol`

- [ ] **Step 1: Add tests for cast-after-finalize and cast-during-tally**

Append to `CopelandVotingTest`:

```solidity
    function test_castBallot_revertsWhenFinalized() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);

        // The election is finalized — VotingNotOpen reverts first (time-based check is earlier),
        // but we want to ensure no ballot can land. Either revert is acceptable.
        uint8[] memory r = new uint8[](1);
        vm.prank(ALICE);
        vm.expectRevert();
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsAfterEndDuringTallying() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 1);
        uint8[] memory r = new uint8[](1); r[0] = 0;
        vm.prank(ALICE); voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10); // phase becomes Tallying

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(
            ICopelandVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp
        ));
        voting.castBallot(id, r);
    }
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `forge test --match-contract CopelandVotingTest -vv`
Expected: PASS (existing time check covers both).

- [ ] **Step 3: Commit**

```bash
git add test/CopelandVoting.t.sol
git commit -m "test: castBallot blocked after voting period ends and after finalize"
```

---

## Task 15: Property / fuzz tests

**Files:**
- Create: `test/CopelandVoting.fuzz.t.sol`

- [ ] **Step 1: Write the fuzz suite**

Create `test/CopelandVoting.fuzz.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";
import {ICopelandVoting} from "../src/interfaces/ICopelandVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract CopelandVotingFuzz is Test {
    CopelandVoting internal voting;
    MockVotesToken internal token;

    function setUp() public {
        voting = new CopelandVoting();
        token = new MockVotesToken();
        vm.roll(block.number + 1);
    }

    function _config(uint8 numCandidates) internal view returns (ICopelandVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](numCandidates);
        for (uint8 i = 0; i < numCandidates; i++) cands[i] = bytes32(uint256(i + 1));
        cfg = ICopelandVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: block.number - 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            metadataURI: bytes32(0)
        });
    }

    /// @dev Final ranking is always a permutation of [0..C-1].
    function testFuzz_rankingIsPermutation(uint8 cRaw, uint64 weightSeed) public {
        uint8 c = uint8(bound(cRaw, 2, 8));
        ICopelandVoting.ElectionConfig memory cfg = _config(c);
        uint256 id = voting.createElection(cfg);

        // 5 voters, simple ballots, random weights
        for (uint160 vi = 1; vi <= 5; vi++) {
            address v = address(vi);
            uint256 weight = uint256(keccak256(abi.encode(weightSeed, vi))) % 1000 + 1;
            token.setPastVotes(v, cfg.snapshotBlock, weight);
            // Each voter ranks first 3 candidates in a rotating order
            uint8[] memory r = new uint8[](3);
            uint8 offset = uint8(vi % c);
            r[0] = offset;
            r[1] = (offset + 1) % c;
            r[2] = (offset + 2) % c;
            vm.prank(v);
            voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking.length, c);

        // Every index 0..c-1 appears exactly once
        bool[] memory seen = new bool[](c);
        for (uint256 i = 0; i < c; i++) {
            assertTrue(ranking[i] < c, "index out of range");
            assertFalse(seen[ranking[i]], "duplicate in ranking");
            seen[ranking[i]] = true;
        }
        for (uint256 i = 0; i < c; i++) {
            assertTrue(seen[i], "missing candidate");
        }
    }

    /// @dev Same inputs → same final ranking.
    function testFuzz_deterministic(uint8 cRaw) public {
        uint8 c = uint8(bound(cRaw, 2, 6));

        // First run
        ICopelandVoting.ElectionConfig memory cfg1 = _config(c);
        uint256 id1 = voting.createElection(cfg1);
        _castFixedBallots(id1, cfg1.snapshotBlock, c);
        vm.warp(cfg1.endTime + 1);
        while (!voting.tallyBallots(id1, 10)) {}
        voting.finalize(id1);
        uint8[] memory r1 = voting.getRanking(id1);

        // Reset block + create second election with identical config and ballots
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICopelandVoting.ElectionConfig memory cfg2 = _config(c);
        cfg2.startTime = uint64(block.timestamp);
        cfg2.endTime = uint64(block.timestamp + 1 days);
        uint256 id2 = voting.createElection(cfg2);
        _castFixedBallots(id2, cfg2.snapshotBlock, c);
        vm.warp(cfg2.endTime + 1);
        while (!voting.tallyBallots(id2, 10)) {}
        voting.finalize(id2);
        uint8[] memory r2 = voting.getRanking(id2);

        assertEq(r1.length, r2.length);
        for (uint256 i = 0; i < r1.length; i++) {
            assertEq(r1[i], r2[i]);
        }
    }

    function _castFixedBallots(uint256 id, uint256 snapshotBlock, uint8 c) internal {
        for (uint160 vi = 1; vi <= 4; vi++) {
            address v = address(vi);
            token.setPastVotes(v, snapshotBlock, vi * 10);
            uint8[] memory r = new uint8[](c);
            // Ballot: shift by vi
            for (uint8 i = 0; i < c; i++) r[i] = uint8((i + vi) % c);
            vm.prank(v);
            voting.castBallot(id, r);
        }
    }
}
```

- [ ] **Step 2: Run fuzz tests**

Run: `forge test --match-contract CopelandVotingFuzz -vv`
Expected: PASS (256 fuzz runs by default).

- [ ] **Step 3: Commit**

```bash
git add test/CopelandVoting.fuzz.t.sol
git commit -m "test: fuzz invariants — ranking is permutation, finalize is deterministic"
```

---

## Task 16: Scenario tests

**Files:**
- Create: `test/CopelandVoting.scenarios.t.sol`

- [ ] **Step 1: Write the scenario suite**

Create `test/CopelandVoting.scenarios.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";
import {ICopelandVoting} from "../src/interfaces/ICopelandVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract CopelandVotingScenariosTest is Test {
    CopelandVoting internal voting;
    MockVotesToken internal token;

    function setUp() public {
        voting = new CopelandVoting();
        token = new MockVotesToken();
        vm.roll(block.number + 1);
    }

    function _cfg(uint8 c) internal view returns (ICopelandVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](c);
        for (uint8 i = 0; i < c; i++) cands[i] = bytes32(uint256(i + 1));
        cfg = ICopelandVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: block.number - 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            metadataURI: bytes32(0)
        });
    }

    /// @dev A Condorcet winner (beats every other candidate head-to-head) must rank first.
    function test_condorcetWinnerRanksFirst() public {
        ICopelandVoting.ElectionConfig memory cfg = _cfg(4);
        uint256 id = voting.createElection(cfg);

        // Make candidate 0 a Condorcet winner: every voter ranks 0 first.
        address[5] memory voters = [address(0x11), address(0x12), address(0x13), address(0x14), address(0x15)];
        uint8[5] memory secondChoice = [1, 2, 3, 1, 2];

        for (uint256 i = 0; i < 5; i++) {
            token.setPastVotes(voters[i], cfg.snapshotBlock, 100);
            uint8[] memory r = new uint8[](2);
            r[0] = 0;
            r[1] = secondChoice[i];
            vm.prank(voters[i]);
            voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking[0], 0, "Condorcet winner should rank first");
    }

    /// @dev Condorcet cycle: A>B, B>C, C>A all with equal margins.
    /// Tiebreaker should produce a deterministic strict order.
    function test_condorcetCycleResolvedDeterministically() public {
        ICopelandVoting.ElectionConfig memory cfg = _cfg(3);
        uint256 id = voting.createElection(cfg);

        // Three voter groups
        address grpAB = address(0x21); // ranks A > B
        address grpBC = address(0x22); // ranks B > C
        address grpCA = address(0x23); // ranks C > A
        token.setPastVotes(grpAB, cfg.snapshotBlock, 100);
        token.setPastVotes(grpBC, cfg.snapshotBlock, 100);
        token.setPastVotes(grpCA, cfg.snapshotBlock, 100);

        uint8[] memory ab = new uint8[](2); ab[0] = 0; ab[1] = 1;
        uint8[] memory bc = new uint8[](2); bc[0] = 1; bc[1] = 2;
        uint8[] memory ca = new uint8[](2); ca[0] = 2; ca[1] = 0;
        vm.prank(grpAB); voting.castBallot(id, ab);
        vm.prank(grpBC); voting.castBallot(id, bc);
        vm.prank(grpCA); voting.castBallot(id, ca);

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory r = voting.getRanking(id);
        assertEq(r.length, 3);
        // All three candidates tied on Copeland score and margins — falls back to index ascending
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    /// @dev ENS Service Provider-style: 12 candidates, 20 voters, varying partial ballots.
    function test_ensServiceProviderStyle() public {
        ICopelandVoting.ElectionConfig memory cfg = _cfg(12);
        uint256 id = voting.createElection(cfg);

        // 20 voters, varying weights
        for (uint160 vi = 1; vi <= 20; vi++) {
            address v = address(vi);
            uint256 weight = (uint256(vi) * 137) % 5000 + 1;
            token.setPastVotes(v, cfg.snapshotBlock, weight);
            // ballot length is 3-8, contents pseudo-random
            uint8 len = uint8(((vi * 7) % 6) + 3);
            uint8[] memory r = new uint8[](len);
            bool[] memory used = new bool[](12);
            uint8 placed = 0;
            uint256 seed = uint256(vi);
            while (placed < len) {
                seed = uint256(keccak256(abi.encode(seed)));
                uint8 idx = uint8(seed % 12);
                if (!used[idx]) {
                    used[idx] = true;
                    r[placed++] = idx;
                }
            }
            vm.prank(v);
            voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 5)) {} // small batches to exercise pagination
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking.length, 12);
        // Permutation invariant
        bool[] memory seen = new bool[](12);
        for (uint256 i = 0; i < 12; i++) seen[ranking[i]] = true;
        for (uint256 i = 0; i < 12; i++) assertTrue(seen[i]);
    }

    /// @dev Replaceable ballots: last vote stands.
    function test_replacementLastBallotWins() public {
        ICopelandVoting.ElectionConfig memory cfg = _cfg(3);
        uint256 id = voting.createElection(cfg);
        address voter = address(0x31);
        token.setPastVotes(voter, cfg.snapshotBlock, 50);

        uint8[] memory first = new uint8[](2); first[0] = 0; first[1] = 1;
        uint8[] memory second = new uint8[](2); second[0] = 2; second[1] = 1;
        vm.startPrank(voter);
        voting.castBallot(id, first);
        voting.castBallot(id, second);
        vm.stopPrank();

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);

        int256[][] memory M = voting.getPairwiseMatrix(id);
        // Only the second ballot contributes: 2>1 with weight 50
        assertEq(M[2][1], 50);
        assertEq(M[0][1], 0); // first ballot fully discarded
    }
}
```

- [ ] **Step 2: Run scenario tests**

Run: `forge test --match-contract CopelandVotingScenariosTest -vv`
Expected: PASS (4 scenarios).

- [ ] **Step 3: Commit**

```bash
git add test/CopelandVoting.scenarios.t.sol
git commit -m "test: scenarios — Condorcet winner, cycle, ENS-style, replacement"
```

---

## Task 17: Deploy script

**Files:**
- Create: `script/Deploy.s.sol`

- [ ] **Step 1: Write the deploy script**

Create `script/Deploy.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";

contract DeployCopelandVoting is Script {
    function run() external returns (CopelandVoting voting) {
        vm.startBroadcast();
        voting = new CopelandVoting();
        vm.stopBroadcast();
        console2.log("CopelandVoting deployed at:", address(voting));
    }
}
```

- [ ] **Step 2: Verify compile + dry run**

Run: `forge build` then `forge script script/Deploy.s.sol --sig "run()"`
Expected: Both PASS. Script prints the deployed address from a simulated run.

- [ ] **Step 3: Commit**

```bash
git add script/Deploy.s.sol
git commit -m "feat: deploy script for CopelandVoting"
```

---

## Task 18: Format check + final pass

**Files:**
- Possibly modify any source file to satisfy `forge fmt`

- [ ] **Step 1: Run formatter in check mode**

Run: `forge fmt --check`
Expected: PASS, or specific diffs printed.

- [ ] **Step 2: If diffs exist, apply them**

Run: `forge fmt`
Then `forge test` again to confirm nothing broke.

- [ ] **Step 3: Run the full suite once more**

Run: `forge test -vv`
Expected: All tests PASS across CopelandTallyTest, CopelandVotingTest, CopelandVotingFuzz, CopelandVotingScenariosTest.

- [ ] **Step 4: Commit format changes (if any)**

```bash
git add -A
git commit -m "style: apply forge fmt" || echo "no fmt changes"
```

---

## Task 19: Gas snapshot

**Files:**
- Create: `.gas-snapshot`

- [ ] **Step 1: Generate snapshot**

Run: `forge snapshot`
Expected: `.gas-snapshot` file written at the repo root.

- [ ] **Step 2: Commit**

```bash
git add .gas-snapshot
git commit -m "chore: initial gas snapshot"
```

---

## Self-Review

**Spec coverage:**
- §4 Public API → Task 1 (interface), Tasks 5/7/10/13 (implementation), Task 15 (views included)
- §5 Data model → Task 5 (storage struct)
- §6 Tally algorithm → Tasks 3, 4, 10, 11, 13
- §7 Voting power → Task 10 (calls `getPastVotes` at snapshot block)
- §8 Validation & reverts → Tasks 6, 9, 12, 13 (createElection / castBallot / tallyBallots / finalize)
- §9 Edge cases → Tasks 11 (zero weight, zero-max), 13 (no ballots), 14 (cast-after-end), 16 (replacement)
- §10 Security → Implicit in the storage/code patterns; no separate task needed
- §11 Testing strategy → Tasks 3, 4, 6, 9, 12, 14, 15 (units), 15 (fuzz), 16 (scenarios), 19 (gas)
- §12 Repository layout → already present from forge init + Tasks 1, 2, 3, 5, 15, 16, 17

**Placeholder scan:** No TBDs, no "implement later" — every step has full code or commands.

**Type consistency:** `castBallot(uint256, uint8[])`, `tallyBallots(uint256, uint256) returns (bool)`, `finalize(uint256)`, `getRanking(uint256) returns (uint8[])` — used consistently across tasks. `MAX_CANDIDATES = 64` referenced in interface (Task 1) and contract (Task 5).

---

## Execution Handoff

The user has requested fully autonomous execution. We will run tasks 1–19 inline through fresh sub-agents (one per task), with the main session verifying each task and managing convergence. After all tasks pass, we run the full suite (`forge test -vv`, `forge fmt --check`), push to `origin`, and report back.
