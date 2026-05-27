# ranked-choice-voting

Onchain ranked-choice voting for DAOs with Copeland and Schulze methods.

![CI](https://github.com/blockful/ranked-choice-voting/actions/workflows/test.yml/badge.svg) ![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg) ![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.26-363636) ![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C?logo=ethereum&logoColor=black)

## Overview

Two standalone Solidity contracts that run pairwise-Condorcet ranked-choice elections fully onchain. Voters submit ranked ballots weighted by `IVotes` (ERC20Votes / ERC721Votes) snapshots. `CopelandVoting` and `SchulzeVoting` both implement the common `IRankedChoiceVoting` interface — integrate once, swap methods with a single constructor change. Each contract outputs a deterministic strict total order over all candidates; downstream consumers (Governors, council selectors, budget allocators) interpret that ordering however they need.

Aimed at DAOs and onchain organizations that need a Condorcet-method election — council selection, grant allocation, prioritized lists, multi-winner committees — where the canonical "winner-take-all" Governor pattern doesn't fit and an ordered ranking is the natural output.

Explicitly **not**: an audited contract, an instant-runoff (IRV) implementation, or an OpenZeppelin Governor replacement. It produces a ranking; combining that ranking with proposal execution is the integrator's job.

## Features

- Two methods, one interface — swap `CopelandVoting` <-> `SchulzeVoting` with no integration changes.
- Standalone — no coupling to OpenZeppelin Governor or any DAO framework.
- Generic — any `IVotes` token works (ERC20Votes, ERC721Votes, custom checkpointed tokens).
- Permissionless — anyone can create an election, cast, tally, or finalize.
- Replaceable ballots — voters can recast at any time before the deadline.
- Lazy batched tally — pay gas only when you need the result; spread across multiple transactions.
- Live preview — `getCurrentResult(id)` returns the ranking the contract would produce if `finalize()` were called right now, at any lifecycle phase.
- Deterministic ordering — always a strict total order, with method-specific tiebreaks (Copeland: Minimax then index; Schulze: strongest-path then index).
- Partial rankings — voters rank any subset of candidates; unranked candidates contribute nothing.

## Methods

- **Copeland** — each candidate's score is (head-to-head wins − losses); Minimax breaks ties, then candidate index. Cheaper to finalize (O(C²)) and easier to explain. Default choice unless you specifically expect cyclical preferences.
- **Schulze** — Floyd-Warshall over the widest-path semiring produces strongest-path scores; candidate index breaks ties. Resolves asymmetric Condorcet cycles decisively at the cost of O(C³) finalize.

Full methodology, worked examples and tiebreak rules: [docs/voting-methods.md](docs/voting-methods.md).

## Quick start

```bash
forge install
forge build
forge test
```

Requires [Foundry](https://book.getfoundry.sh/).

## Usage

```solidity
import {IRankedChoiceVoting} from "src/interfaces/IRankedChoiceVoting.sol";
import {CopelandVoting} from "src/CopelandVoting.sol";
// or: import {SchulzeVoting} from "src/SchulzeVoting.sol";

// Integrate against the common interface — swap methods freely.
IRankedChoiceVoting voting = IRankedChoiceVoting(address(new CopelandVoting()));

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

// 3. Live preview at any time — no need to wait for finalize.
uint8[] memory provisional = voting.getCurrentResult(electionId);

// 4. After endTime, anyone tallies and finalizes
while (!voting.tallyBallots(electionId, 50)) {} // batched
voting.finalize(electionId);

// 5. Read the final result
uint8[] memory orderedWinners = voting.getRanking(electionId);
// orderedWinners[0] is the top-ranked candidate index
```

Limits: maximum 64 candidates per election; voter weights bounded by `int256` max.

## Deployments

Not yet deployed to mainnet. Run via the deploy scripts in [`script/`](script/) (`DeployCopelandVoting.s.sol`, `DeploySchulzeVoting.s.sol`).

## Documentation

- [docs/voting-methods.md](docs/voting-methods.md) — full methodology, worked examples, gas table, tiebreak rules.
- [docs/superpowers/specs/2026-05-25-multi-method-voting-design.md](docs/superpowers/specs/2026-05-25-multi-method-voting-design.md) — multi-method design spec.
- [docs/superpowers/specs/2026-05-24-copeland-voting-design.md](docs/superpowers/specs/2026-05-24-copeland-voting-design.md) — original Copeland design rationale and decision log.
- [docs/superpowers/plans/2026-05-25-multi-method-voting.md](docs/superpowers/plans/2026-05-25-multi-method-voting.md) — multi-method implementation plan.

## Contributing

Contributions welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, conventions, and PR process.

## Security

Report vulnerabilities per [SECURITY.md](SECURITY.md). **These contracts have not been independently audited** — production deployments should commission an audit first.

## License

[MIT](LICENSE).
