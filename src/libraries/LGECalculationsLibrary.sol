// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LGECalculationsLibrary {
    uint256 private constant TOTAL_BLOCKS = 5000;

    function calculateCurrentTokenPrice(
        uint256 minTokenPrice,
        uint256 maxTokenPrice,
        uint256 currentBlock,
        uint256 startBlock
    ) public pure returns (uint256) {
        return
            uint256(
                (((int256(minTokenPrice) - int256(maxTokenPrice)) *
                    int256(currentBlock)) / int256(startBlock + TOTAL_BLOCKS)) +
                    int256(minTokenPrice)
            );
    }

    function getSqrtPrice(uint256 averagePrice) public pure returns (uint160) {
        return uint160(Math.sqrt(averagePrice) * 2 ** 96);
    }

    // function ticksForClaim(
    //     uint256 batchSize,
    //     int24 baseTick,
    //     int24 currentTick,
    //     int24 tickSpacing
    // ) public pure returns (int24 tickLower, int24 tickUpper, int256 tick) {
    //     batchSize = batchSize / 1e18;
    //     int256 m;
    //     int256 c;
    //     int256 baseTick_ = int256(baseTick) * 1e18;
    //     int256 totalSupply_ = int256(TOTAL_SUPPLY);
    //     int256 lowThreshold_ = int256(LOW_THRESHOLD);
    //     int256 highThreshold_ = int256(HIGH_THRESHOLD);

    //     if (batchSize < LOW_THRESHOLD) {
    //         m =
    //             ((baseTick_ / 10 + 100000 * 1e18)) /
    //             (lowThreshold_ - TOKENS_PER_BLOCK);
    //         c = (baseTick_ - 100000 * 1e18 - (m * TOKENS_PER_BLOCK)) / 1e18;
    //     } else if (LOW_THRESHOLD <= batchSize && batchSize <= HIGH_THRESHOLD) {
    //         m =
    //             ((baseTick_ - (9 * baseTick_) / 10)) /
    //             (highThreshold_ - lowThreshold_);
    //         c = (((9 * baseTick_) / 10) - (m * lowThreshold_)) / 1e18;
    //     } else if (batchSize > HIGH_THRESHOLD) {
    //         m = (100000 * 1e18) / (totalSupply_ - highThreshold_);
    //         c = (baseTick_ - m * highThreshold_) / 1e18;
    //     }

    //     tick = ((m * int256(batchSize)) / 1e18 + c);
    //     tick = (tick / tickSpacing) * tickSpacing;

    //     int24 rangeWidth = 1000; // This means 1000 tick spacing units on each side

    //     // Calculate range bounds
    //     tickLower = int24(tick) - (rangeWidth * tickSpacing);
    //     tickUpper = int24(tick) + (rangeWidth * tickSpacing);

    //     // These should already be aligned since:
    //     // - tick is aligned to tickSpacing
    //     // - rangeWidth * tickSpacing is a multiple of tickSpacing
    //     // But ensure alignment for safety:
    //     tickLower = (tickLower / tickSpacing) * tickSpacing;
    //     tickUpper = (tickUpper / tickSpacing) * tickSpacing;

    //     // Apply bounds
    //     if (tickLower < -887272) tickLower = -887272;
    //     if (tickUpper > 887272) tickUpper = 887272;

    //     // Ensure valid range
    //     require(tickUpper > tickLower, "Invalid range");
    // }

    function getAmountsForLiquidity(
        uint160 sqrtPriceX96, // current sqrt price
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint256 tokenAmount
    ) public pure returns (uint256 ethNeeded, uint128 liquidity) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (currentTick < tickLower) {
            revert("Cannot add token-only liquidity below range");
        } else if (currentTick >= tickUpper) {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioBX96,
                tokenAmount
            );
            ethNeeded = 0;
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtPriceX96,
                tokenAmount
            );

            ethNeeded = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtPriceX96,
                sqrtRatioBX96,
                liquidity
            );
        }

        if (ethNeeded > 0) {
            ethNeeded += 1;
        }
    }
}
