# copeland-voting

Onchain Copeland-method ranked choice voting for DAOs.

A standalone Solidity contract that runs Copeland elections fully onchain on Ethereum mainnet. Voters submit ranked ballots weighted by `IVotes` (ERC20Votes / ERC721Votes) snapshots. The contract outputs a deterministic ordering of all candidates — downstream consumers (Governors, council selection, budget allocators) interpret that ordering however they need.

## Highlights

- **Standalone**: no coupling to OpenZeppelin Governor or any specific DAO framework.
- **Generic**: any `IVotes` token works (ERC20Votes, ERC721Votes, custom checkpointed tokens).
- **Permissionless**: anyone can create an election; consumers pick the election ID they trust.
- **Replaceable ballots**: voters can recast at any time before the deadline.
- **Lazy batched tally**: pay gas only when you need the result; spread across multiple transactions.
- **Deterministic ordering**: Copeland score → sum of pairwise margins → candidate index. Always a strict total order.
- **Partial rankings**: voters rank any subset of candidates; unranked candidates contribute nothing (no implicit ordering).

## Design

The full design rationale, decision log, and API contract live in [docs/superpowers/specs/2026-05-24-copeland-voting-design.md](docs/superpowers/specs/2026-05-24-copeland-voting-design.md).

## Quick start

```bash
forge install
forge build
forge test
```

## Usage sketch

```solidity
// 1. Create an election
bytes32[] memory candidates = new bytes32[](3);
candidates[0] = keccak256("Alice");
candidates[1] = keccak256("Bob");
candidates[2] = keccak256("Carol");

uint256 electionId = voting.createElection(ICopelandVoting.ElectionConfig({
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

// 3. After endTime, anyone tallies and finalizes
while (!voting.tallyBallots(electionId, 50)) {}  // batched
voting.finalize(electionId);

// 4. Read the result
uint8[] memory orderedWinners = voting.getRanking(electionId);
// orderedWinners[0] is the top-ranked candidate index
```

## Limits

- Maximum 64 candidates per election (kept under mainnet gas constraints for finalize)
- Maximum 256-bit token weights per voter (standard `uint256`)

## License

MIT
