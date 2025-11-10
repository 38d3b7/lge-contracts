// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LGECalculationsLibrary {
    // ====== UNICHAIN SEPOLIA VALUES ======
    uint256 private constant TOTAL_BLOCKS = 3600;
    uint256 public constant MIN_TOKEN_PRICE = 1000000000;
    uint256 public constant MAX_TOKEN_PRICE = 4000000000;

    function calculateCurrentTokenPrice(
        uint256 currentBlock,
        uint256 startBlock
    ) public pure returns (uint256) {
        if (currentBlock >= startBlock + TOTAL_BLOCKS) {
            return MAX_TOKEN_PRICE;
        }

        return
        MIN_TOKEN_PRICE +
                (((MAX_TOKEN_PRICE - MIN_TOKEN_PRICE) * (currentBlock - startBlock)) /
                    TOTAL_BLOCKS);
        // return
        //     uint256(
        //         (((int256(minTokenPrice) - int256(maxTokenPrice)) *
        //             int256(currentBlock - startBlock)) / int256(TOTAL_BLOCKS)) +
        //             int256(minTokenPrice)
        //     );
    }

    function calculateEthNeeded(
        uint256 currentBlock,
        uint256 startBlock,
        uint256 amountOfTokens
    ) external pure returns (uint256 ethExpected) {
        uint256 ethPerToken = calculateCurrentTokenPrice(
            currentBlock,
            startBlock
        );
        uint256 ethForTokenAmount = amountOfTokens / ethPerToken;
        ethExpected = ethForTokenAmount * 2;
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
