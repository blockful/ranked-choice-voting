// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRankedChoiceVoting} from "./IRankedChoiceVoting.sol";

interface ISchulzeVoting is IRankedChoiceVoting {
    /// @notice Strongest-paths matrix p[i][j] computed via Floyd-Warshall.
    /// @dev Recomputed on each call (O(C³)). Not persisted to storage due to gas cost
    ///      (4096 slots at C=64 would exceed block gas limit on finalize).
    function getStrongestPaths(uint256 electionId) external view returns (int256[][] memory);

    /// @notice Schulze score per candidate: count of opponents j where p[i][j] > p[j][i].
    /// @dev Populated by finalize(); empty array before then.
    function getSchulzeScores(uint256 electionId) external view returns (uint256[] memory);
}
