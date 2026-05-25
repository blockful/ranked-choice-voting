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
