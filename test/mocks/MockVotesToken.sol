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
