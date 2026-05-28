// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";
import {SchulzeVoting} from "../src/SchulzeVoting.sol";
import {IRankedChoiceVoting} from "../src/interfaces/IRankedChoiceVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @notice Production-like gas benchmarks. Run with:
///   forge test --match-contract GasBenchmark -vvv
/// Per-phase gas is logged via console2 (visible at -vvv).
///
/// Scenario: 10 candidates, 100 voters, partial ballots of length 4-7.
/// Tally is batched at 20 voters per call to mirror realistic mainnet pagination.
/// These tests carry no scoring assertions — they exist purely to measure gas.
contract GasBenchmark is Test {
    uint8 internal constant NUM_CANDIDATES = 10;
    uint256 internal constant NUM_VOTERS = 100;
    uint256 internal constant BATCH_SIZE = 20;

    MockVotesToken internal token;

    function setUp() public {
        token = new MockVotesToken();
        vm.roll(block.number + 1);
    }

    function _cfg(uint256 snapshotBlock, uint64 startTime, uint64 endTime)
        internal
        view
        returns (IRankedChoiceVoting.ElectionConfig memory cfg)
    {
        bytes32[] memory cands = new bytes32[](NUM_CANDIDATES);
        for (uint8 i = 0; i < NUM_CANDIDATES; i++) {
            cands[i] = bytes32(uint256(i + 1));
        }
        cfg = IRankedChoiceVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: snapshotBlock,
            startTime: startTime,
            endTime: endTime,
            metadataURI: bytes32(0)
        });
    }

    /// @dev Deterministic partial ballot for voter index `vi`: length 4-7, distinct candidates.
    function _ballot(uint160 vi) internal pure returns (uint8[] memory) {
        uint8 len = uint8(((vi * 13) % 4) + 4); // 4-7 inclusive
        uint8[] memory r = new uint8[](len);
        bool[] memory used = new bool[](NUM_CANDIDATES);
        uint256 seed = uint256(vi) * 1_000_003;
        uint8 placed = 0;
        while (placed < len) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint8 idx = uint8(seed % NUM_CANDIDATES);
            if (!used[idx]) {
                used[idx] = true;
                r[placed++] = idx;
            }
        }
        return r;
    }

    function test_gasBenchmark_copeland_100voters_10candidates() public {
        CopelandVoting voting = new CopelandVoting();
        _runBenchmark(IRankedChoiceVoting(address(voting)), "Copeland");
    }

    function test_gasBenchmark_schulze_100voters_10candidates() public {
        SchulzeVoting voting = new SchulzeVoting();
        _runBenchmark(IRankedChoiceVoting(address(voting)), "Schulze");
    }

    function _runBenchmark(IRankedChoiceVoting voting, string memory label) internal {
        IRankedChoiceVoting.ElectionConfig memory cfg =
            _cfg(block.number - 1, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        // Pre-seed voter weights (token-side state; not part of the measured contract phases).
        for (uint160 vi = 1; vi <= NUM_VOTERS; vi++) {
            uint256 weight = (uint256(vi) * 37) % 5_000 + 1;
            token.setPastVotes(address(vi), cfg.snapshotBlock, weight);
        }

        console2.log("");
        console2.log(string.concat("=== Gas benchmark: ", label, " (100 voters x 10 candidates) ==="));

        // Phase A: createElection
        uint256 g = gasleft();
        uint256 id = voting.createElection(cfg);
        uint256 createGas = g - gasleft();
        console2.log("createElection            :", createGas);

        // Phase B: castBallot (first / avg / total)
        uint256 firstCast;
        uint256 lastCast;
        uint256 totalCast;
        for (uint160 vi = 1; vi <= NUM_VOTERS; vi++) {
            uint8[] memory r = _ballot(vi);
            vm.prank(address(vi));
            g = gasleft();
            voting.castBallot(id, r);
            uint256 used = g - gasleft();
            if (vi == 1) firstCast = used;
            if (vi == NUM_VOTERS) lastCast = used;
            totalCast += used;
        }
        console2.log("castBallot (first)        :", firstCast);
        console2.log("castBallot (last)         :", lastCast);
        console2.log("castBallot (avg of 100)   :", totalCast / NUM_VOTERS);
        console2.log("castBallot (total of 100) :", totalCast);

        // Phase C: tallyBallots, batched at BATCH_SIZE
        vm.warp(cfg.endTime + 1);
        uint256 totalTally;
        uint256 batches;
        bool done;
        while (!done) {
            g = gasleft();
            done = voting.tallyBallots(id, BATCH_SIZE);
            totalTally += g - gasleft();
            batches++;
        }
        console2.log("tallyBallots batches      :", batches);
        console2.log("tallyBallots (per batch)  :", totalTally / batches);
        console2.log("tallyBallots (total)      :", totalTally);

        // Phase D: finalize
        g = gasleft();
        voting.finalize(id);
        uint256 finalizeGas = g - gasleft();
        console2.log("finalize                  :", finalizeGas);

        // Phase E: getCurrentResult (view; storage warm in this tx, so a lower bound on cold cost)
        g = gasleft();
        voting.getCurrentResult(id);
        uint256 currentResultGas = g - gasleft();
        console2.log("getCurrentResult (view)   :", currentResultGas);

        uint256 grandTotal = createGas + totalCast + totalTally + finalizeGas;
        console2.log("GRAND TOTAL (write path)  :", grandTotal);

        // Sanity only: the run completed and produced a full ranking.
        assertEq(voting.getRanking(id).length, NUM_CANDIDATES);
    }
}
