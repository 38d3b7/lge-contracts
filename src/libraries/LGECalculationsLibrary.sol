// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LGECalculationsLibrary {
    function calculateCurrentTokenPrice(
        uint256 currentBlock,
        uint256 startBlock,
        uint256 streamBlocks,
        uint256 minTokenPrice,
        uint256 maxTokenPrice
    ) public pure returns (uint256) {
        if (currentBlock <= startBlock) {
            return minTokenPrice;
        }
        if (currentBlock >= startBlock + streamBlocks) {
            return maxTokenPrice;
        }
        return
            minTokenPrice +
            (((maxTokenPrice - minTokenPrice) * (currentBlock - startBlock)) /
                streamBlocks);
    }

    function calculateUsdcNeeded(
        uint256 currentBlock,
        uint256 startBlock,
        uint256 streamBlocks,
        uint256 minTokenPrice,
        uint256 maxTokenPrice,
        uint256 amountOfTokens
    ) external pure returns (uint256 usdcExpected) {
        uint256 tokensPerUsdc = calculateCurrentTokenPrice(
            currentBlock,
            startBlock,
            streamBlocks,
            minTokenPrice,
            maxTokenPrice
        );
        // tokensPerUsdc is a raw wei-to-wei ratio (token-wei per usdc-wei;
        // both legs are 18-dec so "20000 tokens per USDC" is simply 20000).
        // Round UP — floor division undercharges, and quotes exactly 0 for
        // buys smaller than the ratio (free tokens).
        uint256 usdcForTokenAmount = (amountOfTokens + tokensPerUsdc - 1) / tokensPerUsdc;
        usdcExpected = usdcForTokenAmount * 2;
    }

    function getSqrtPrice(
        uint256 averagePrice
    ) external pure returns (uint160) {
        return uint160(Math.sqrt(averagePrice) * 2 ** 96);
    }

    function getAmountsForLiquidity(
        uint160 sqrtPriceX96, // current sqrt price
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint256 tokenAmount
    ) external pure returns (uint256 ethNeeded, uint128 liquidity) {
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
