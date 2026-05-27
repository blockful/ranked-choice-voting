# Contributing

Thanks for considering a contribution. This project is small and focused — two ranked-choice voting contracts behind one interface — so we try to keep changes correspondingly tight.

## Development setup

1. Install [Foundry](https://book.getfoundry.sh/) (`curl -L https://foundry.paradigm.xyz | bash`, then `foundryup`).
2. Clone the repo and pull submodules:

   ```bash
   git clone git@github.com:blockful/ranked-choice-voting.git
   cd ranked-choice-voting
   forge install
   ```

3. Build:

   ```bash
   forge build
   ```

## Running tests

```bash
forge test                              # full suite
forge test --match-contract CopelandVoting   # one contract
forge test --match-test test_wikipediaExample -vvv   # one test, verbose traces
FOUNDRY_FUZZ_RUNS=10000 forge test      # heavier fuzz pass before submitting
```

CI runs `forge fmt --check`, `forge build --sizes`, and `forge test -vvv` on every push and PR.

## Code style

- Formatting: `forge fmt` (settings in `foundry.toml`); CI rejects unformatted code.
- Solidity version: pinned to `^0.8.26` across `src/` and `test/`.
- Prefer custom errors over `require(..., "string")`.
- Tests follow `test_<thing>_<condition>` or scenario-style names matching the existing files in `test/`.

## Commit conventions

Lightweight Conventional Commits, matching the existing history:

- `feat:` new user-visible functionality
- `fix:` bug fix
- `test:` test-only changes (new scenarios, fuzz invariants, refactors)
- `docs:` README / `docs/` / NatSpec changes
- `chore:` infra, formatting, gas snapshots, deps
- `refactor:` internal restructuring with no behavior change
- `style:` formatting-only changes

Subject in imperative mood, lower-case, no trailing period. A short body is welcome when the "why" isn't obvious from the diff.

## Pull request process

1. Branch from `main`.
2. Keep PRs focused — one logical change per PR is easier to review than a grab-bag.
3. Ensure CI passes locally (`forge fmt --check && forge test`).
4. Link the relevant docs/specs in the PR body when the change touches algorithmic behavior — reviewers will check the change against the spec.
5. Update `docs/voting-methods.md` (or the relevant spec) if you change observable behavior or tiebreak semantics.

## Architecture overview

`IRankedChoiceVoting` (in `src/interfaces/`) defines the shared lifecycle and views. `CopelandVoting` and `SchulzeVoting` implement it; method-specific score getters live on `ICopelandVoting` / `ISchulzeVoting`. Tally math is factored into `src/libraries/{Copeland,Schulze}Tally.sol` so the storage contracts stay readable. See [`docs/voting-methods.md`](docs/voting-methods.md) for methodology and the design specs under `docs/superpowers/specs/` for the rationale behind each interface choice.
