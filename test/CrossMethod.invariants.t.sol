// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";
import {SchulzeVoting} from "../src/SchulzeVoting.sol";
import {IRankedChoiceVoting} from "../src/interfaces/IRankedChoiceVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract CrossMethodInvariants is Test {
    CopelandVoting internal copeland;
    SchulzeVoting internal schulze;
    MockVotesToken internal token;

    function setUp() public {
        copeland = new CopelandVoting();
        schulze = new SchulzeVoting();
        token = new MockVotesToken();
        vm.roll(block.number + 1);
    }

    function _cfg(uint8 c) internal view returns (IRankedChoiceVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](c);
        for (uint8 i = 0; i < c; i++) {
            cands[i] = bytes32(uint256(i + 1));
        }
        cfg = IRankedChoiceVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: block.number - 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            metadataURI: bytes32(0)
        });
    }

    function test_condorcetWinnerAgreedByBothMethods() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(4);
        uint256 cId = copeland.createElection(cfg);
        uint256 sId = schulze.createElection(cfg);

        address[5] memory voters = [address(0x3001), address(0x3002), address(0x3003), address(0x3004), address(0x3005)];
        uint8[5] memory secondChoice = [1, 2, 3, 1, 2];

        for (uint256 i = 0; i < 5; i++) {
            token.setPastVotes(voters[i], cfg.snapshotBlock, 100);
            uint8[] memory r = new uint8[](2);
            r[0] = 0; // Condorcet winner
            r[1] = secondChoice[i];
            vm.prank(voters[i]);
            copeland.castBallot(cId, r);
            vm.prank(voters[i]);
            schulze.castBallot(sId, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!copeland.tallyBallots(cId, 10)) {}
        while (!schulze.tallyBallots(sId, 10)) {}
        copeland.finalize(cId);
        schulze.finalize(sId);

        uint8[] memory cR = copeland.getRanking(cId);
        uint8[] memory sR = schulze.getRanking(sId);
        assertEq(cR[0], 0, "Copeland: Condorcet winner first");
        assertEq(sR[0], 0, "Schulze: Condorcet winner first");
    }

    function test_identityRankingOnEmptyAgrees() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(5);
        uint256 cId = copeland.createElection(cfg);
        uint256 sId = schulze.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        copeland.tallyBallots(cId, 10);
        schulze.tallyBallots(sId, 10);
        copeland.finalize(cId);
        schulze.finalize(sId);

        uint8[] memory cR = copeland.getRanking(cId);
        uint8[] memory sR = schulze.getRanking(sId);
        assertEq(cR.length, sR.length);
        for (uint256 i = 0; i < cR.length; i++) {
            assertEq(cR[i], i);
            assertEq(sR[i], i);
        }
    }

    function test_getCurrentResultIdentityAcrossMethods() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(4);
        uint256 cId = copeland.createElection(cfg);
        uint256 sId = schulze.createElection(cfg);

        uint8[] memory cR = copeland.getCurrentResult(cId);
        uint8[] memory sR = schulze.getCurrentResult(sId);
        assertEq(cR.length, 4);
        assertEq(sR.length, 4);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(cR[i], i);
            assertEq(sR[i], i);
        }
    }

    function testFuzz_dominantCandidateRanksFirstInBothMethods(uint8 cRaw, uint8 numVotersRaw) public {
        uint8 c = uint8(bound(cRaw, 2, 6));
        uint8 numVoters = uint8(bound(numVotersRaw, 1, 8));

        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(c);
        uint256 cId = copeland.createElection(cfg);
        uint256 sId = schulze.createElection(cfg);

        for (uint160 vi = 1; vi <= numVoters; vi++) {
            address v = address(vi);
            token.setPastVotes(v, cfg.snapshotBlock, uint256(vi) * 10);
            uint8[] memory r = new uint8[](c);
            r[0] = 0;
            // Fill the rest with candidates 1..c-1 in some order (rotation)
            for (uint8 j = 1; j < c; j++) {
                r[j] = uint8(1 + ((j - 1 + vi) % (c - 1)));
            }
            vm.prank(v);
            copeland.castBallot(cId, r);
            vm.prank(v);
            schulze.castBallot(sId, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!copeland.tallyBallots(cId, 10)) {}
        while (!schulze.tallyBallots(sId, 10)) {}
        copeland.finalize(cId);
        schulze.finalize(sId);

        assertEq(copeland.getRanking(cId)[0], 0, "Copeland ranks dominant first");
        assertEq(schulze.getRanking(sId)[0], 0, "Schulze ranks dominant first");
    }
}
