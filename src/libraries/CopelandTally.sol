// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CopelandTally
/// @notice Pure functions implementing Copeland-method tally math.
library CopelandTally {
    /// @notice Sort candidate indices by (score desc, margin desc, index asc).
    /// @dev Insertion sort — input sizes are bounded (C <= 64).
    /// @param scores Copeland scores per candidate (length = C)
    /// @param margins Sum of pairwise margins per candidate (length = C; same order as scores)
    /// @return ranking Candidate indices ordered most-preferred first
    function sortRanking(int256[] memory scores, int256[] memory margins)
        internal
        pure
        returns (uint8[] memory ranking)
    {
        uint256 c = scores.length;
        require(c == margins.length, "length mismatch");
        ranking = new uint8[](c);
        for (uint256 i = 0; i < c; i++) {
            ranking[i] = uint8(i);
        }
        // insertion sort: for each i, bubble ranking[i] leftward into place
        for (uint256 i = 1; i < c; i++) {
            uint8 cur = ranking[i];
            uint256 j = i;
            while (j > 0 && _isGreater(cur, ranking[j - 1], scores, margins)) {
                ranking[j] = ranking[j - 1];
                j--;
            }
            ranking[j] = cur;
        }
    }

    /// @dev True iff candidate `a` ranks above candidate `b` by (score, margin, index).
    function _isGreater(uint8 a, uint8 b, int256[] memory scores, int256[] memory margins)
        private
        pure
        returns (bool)
    {
        if (scores[a] != scores[b]) return scores[a] > scores[b];
        if (margins[a] != margins[b]) return margins[a] > margins[b];
        return a < b;
    }
}
