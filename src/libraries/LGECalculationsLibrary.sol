// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

library LGECalculationsLibrary {
    uint256 private constant TOTAL_SUPPLY = 17_745_440_000;

    function ticksForClaim(
        uint256 batchSize,
        int24 baseTick,
        int24 currentTick,
        int24 tickSpacing
    ) public pure returns (int24 tickLower, int24 tickUpper, int256 tick) {
        // batchSize = batchSize / 1e18;
        tick =
            baseTick +
            150000 -
            int256((30000 * batchSize) / (TOTAL_SUPPLY * 1e18));

        tick = (tick / tickSpacing) * tickSpacing;

        int24 rangeSize = 100 * tickSpacing;

        if (currentTick < tick - rangeSize) {
            tickLower =
                ((currentTick - 10 * tickSpacing) / tickSpacing) *
                tickSpacing;
            tickUpper = tickLower + rangeSize * 2;
        } else if (currentTick > tick + rangeSize) {
            tickUpper =
                ((currentTick + 10 * tickSpacing) / tickSpacing) *
                tickSpacing;
            tickLower = tickUpper - rangeSize * 2;
        } else {
            tickLower = int24((tick - rangeSize) / tickSpacing) * tickSpacing;
            tickUpper = int24((tick + rangeSize) / tickSpacing) * tickSpacing;
        }

        if (tickLower < -887272) tickLower = -887272;
        if (tickUpper > 887272) tickUpper = 887272;
    }

    function getETHPriceFromRange(
        uint256 batchSize, // amount1 in wei
        int24 baseTick,
        int24 currentTick,
        int24 tickSpacing
    ) public pure returns (uint256 ethPricePerBatch, int256 tick) {
        (, , tick) = ticksForClaim(
            batchSize,
            baseTick,
            currentTick,
            tickSpacing
        );

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(int24(tick));
        uint256 sqrtPriceSquared = uint256(sqrtPriceX96) *
            uint256(sqrtPriceX96);

        ethPricePerBatch = FullMath.mulDiv(
            batchSize,
            1 << 192,
            sqrtPriceSquared
        );
    }
}
