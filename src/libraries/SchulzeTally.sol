// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SchulzeTally
/// @notice Pure Schulze-method math: strongest paths, scores, ranking.
library SchulzeTally {
    /// @notice Compute strongest-paths matrix via Floyd-Warshall.
    /// @dev O(c³); operates in memory. For c=64 → 262,144 inner iterations.
    function computeStrongestPaths(int256[] memory d, uint256 c) internal pure returns (int256[] memory p) {
        require(d.length == c * c, "matrix size");
        p = new int256[](c * c);
        // Initialize p[i][j] = d[i][j] if d[i][j] > d[j][i], else 0.
        for (uint256 i = 0; i < c; i++) {
            for (uint256 j = 0; j < c; j++) {
                if (i == j) continue;
                int256 dij = d[i * c + j];
                int256 dji = d[j * c + i];
                p[i * c + j] = dij > dji ? dij : int256(0);
            }
        }
        // Floyd-Warshall on widest-path semiring.
        for (uint256 k = 0; k < c; k++) {
            for (uint256 i = 0; i < c; i++) {
                if (i == k) continue;
                for (uint256 j = 0; j < c; j++) {
                    if (j == i || j == k) continue;
                    int256 a = p[i * c + k];
                    int256 b = p[k * c + j];
                    int256 viaK = a < b ? a : b;
                    if (viaK > p[i * c + j]) {
                        p[i * c + j] = viaK;
                    }
                }
            }
        }
    }

    /// @notice Schulze score per candidate: count of opponents j where p[i][j] > p[j][i].
    function computeScores(int256[] memory p, uint256 c) internal pure returns (uint256[] memory scores) {
        require(p.length == c * c, "matrix size");
        scores = new uint256[](c);
        for (uint256 i = 0; i < c; i++) {
            for (uint256 j = 0; j < c; j++) {
                if (i == j) continue;
                if (p[i * c + j] > p[j * c + i]) {
                    scores[i] += 1;
                }
            }
        }
    }

    /// @notice Sort candidates by Schulze score (desc), candidate index (asc) as fallback.
    function sortRanking(uint256[] memory scores) internal pure returns (uint8[] memory ranking) {
        uint256 c = scores.length;
        ranking = new uint8[](c);
        for (uint256 i = 0; i < c; i++) {
            ranking[i] = uint8(i);
        }
        for (uint256 i = 1; i < c; i++) {
            uint8 cur = ranking[i];
            uint256 j = i;
            while (j > 0 && _ranksAbove(cur, ranking[j - 1], scores)) {
                ranking[j] = ranking[j - 1];
                j--;
            }
            ranking[j] = cur;
        }
    }

    function _ranksAbove(uint8 a, uint8 b, uint256[] memory scores) private pure returns (bool) {
        if (scores[a] != scores[b]) return scores[a] > scores[b];
        return a < b;
    }
}
