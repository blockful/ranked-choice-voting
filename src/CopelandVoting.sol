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
