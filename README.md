# copeland-voting

Onchain ranked-choice voting for DAOs — two interchangeable methods: Copeland and Schulze, sharing a common `IRankedChoiceVoting` interface.

Two standalone Solidity contracts that run pairwise-Condorcet elections fully onchain on Ethereum mainnet. Voters submit ranked ballots weighted by `IVotes` (ERC20Votes / ERC721Votes) snapshots. Each contract outputs a deterministic ordering of all candidates — downstream consumers (Governors, council selection, budget allocators) interpret that ordering however they need. Pick **Copeland** for lower gas and simpler explainability, or **Schulze** when you expect Condorcet cycles and want a more discriminating tiebreaker.

## Highlights

- **Two methods, one interface**: `CopelandVoting` and `SchulzeVoting` both implement `IRankedChoiceVoting` — integrate once, swap methods with a single constructor change.
- **Standalone**: no coupling to OpenZeppelin Governor or any specific DAO framework.
- **Generic**: any `IVotes` token works (ERC20Votes, ERC721Votes, custom checkpointed tokens).
- **Permissionless**: anyone can create an election; consumers pick the election ID they trust.
- **Replaceable ballots**: voters can recast at any time before the deadline.
- **Lazy batched tally**: pay gas only when you need the result; spread across multiple transactions.
- **Live preview**: `getCurrentResult(id)` returns the ranking the contract would produce if `finalize()` were called right now — at any lifecycle phase.
- **Deterministic ordering**: always a strict total order, with method-specific tiebreaks (Copeland → Minimax → index; Schulze → strongest-path → index).
- **Partial rankings**: voters rank any subset of candidates; unranked candidates contribute nothing.

## Methods

The full methodology, worked examples and tiebreak rules for both methods are in [docs/voting-methods.md](docs/voting-methods.md). Original Copeland design rationale and decision log: [docs/superpowers/specs/2026-05-24-copeland-voting-design.md](docs/superpowers/specs/2026-05-24-copeland-voting-design.md).

## Quick start

```bash
forge install
forge build
forge test
```

## Usage sketch

```solidity
import {IRankedChoiceVoting} from "src/interfaces/IRankedChoiceVoting.sol";

// Integrate against the common interface — swap CopelandVoting <-> SchulzeVoting freely.
IRankedChoiceVoting voting = IRankedChoiceVoting(address(new CopelandVoting()));
// or: IRankedChoiceVoting voting = IRankedChoiceVoting(address(new SchulzeVoting()));

// 1. Create an election
bytes32[] memory candidates = new bytes32[](3);
candidates[0] = keccak256("Alice");
candidates[1] = keccak256("Bob");
candidates[2] = keccak256("Carol");

uint256 electionId = voting.createElection(IRankedChoiceVoting.ElectionConfig({
    candidates: candidates,
    votingToken: ensToken,
    snapshotBlock: block.number - 1,
    startTime: uint64(block.timestamp),
    endTime: uint64(block.timestamp + 7 days),
    metadataURI: bytes32(0)
}));

// 2. Voters cast ranked ballots
uint8[] memory ranking = new uint8[](3);
ranking[0] = 2; // Carol first
ranking[1] = 0; // Alice second
ranking[2] = 1; // Bob third
voting.castBallot(electionId, ranking);

// 3. Live preview at any time — no need to wait for finalize
uint8[] memory provisional = voting.getCurrentResult(electionId);

// 4. After endTime, anyone tallies and finalizes
while (!voting.tallyBallots(electionId, 50)) {} // batched
voting.finalize(electionId);

// 5. Read the final result
uint8[] memory orderedWinners = voting.getRanking(electionId);
// orderedWinners[0] is the top-ranked candidate index
```

## Limits

- Maximum 64 candidates per election (kept under mainnet gas constraints for finalize)
- Maximum 256-bit token weights per voter (standard `uint256`)

## License

MIT
