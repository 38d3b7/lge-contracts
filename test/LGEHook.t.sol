// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
// import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";

import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";
import {LGECalculationsLibrary} from "../src/libraries/LGECalculationsLibrary.sol";

import {console} from "forge-std/console.sol";

contract LGEHookTest is Test, Deployers {
    LGEManager lgeManager;
    LGEHook lgeHook;

    PoolId poolId;

    address owner = address(0xABCD);
    address tokenAdmin = address(0x1234);
    address tokenCreator = address(0x5678);
    address user = address(0x9ABC);

    address tokenAddress;
    address hookAddress;

    uint256 startingBlock;

    int24 tickSpacing = 1;
    uint160 initialSqrtPrice = 79228162514264337593543950336000;

    function setUp() public {
        deployFreshManagerAndRouters();

        lgeManager = new LGEManager(manager, address(this));

        LGEManager.TokenConfig memory tokenConfig = LGEManager.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "Test Token",
            symbol: "TEST",
            image: "https://example.com/image.png",
            metadata: "https://example.com/metadata.json"
        });
        LGEManager.PoolConfig memory poolConfig =
            LGEManager.PoolConfig({initialSqrtPriceX96: initialSqrtPrice, fee: 1000, tickSpacing: tickSpacing});
        LGEManager.DeploymentConfig memory deploymentConfig =
            LGEManager.DeploymentConfig({tokenConfig: tokenConfig, poolConfig: poolConfig});

        vm.prank(tokenCreator);
        vm.roll(10);
        (tokenAddress, hookAddress, poolId) = lgeManager.deployToken(deploymentConfig);
        startingBlock = block.number;
    }

    function test_addLiquidity() public {
        vm.roll(13);
        vm.deal(user, 180 ether);
        vm.prank(user);
        int24 baseTick = TickMath.getTickAtSqrtPrice(initialSqrtPrice);
        (uint160 sqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolId);

        console.log("Current Tick before add liquidity:", currentTick);

        uint256 tokensAvailable = LGEHook(hookAddress).tokensAvailable();
        uint256 tokenAmount = tokensAvailable / 2;
        (int24 tickLower, int24 tickUpper,) =
            LGECalculationsLibrary.ticksForClaim(tokensAvailable, baseTick, currentTick, tickSpacing);
        // (uint256 ethExpected, uint128 liquidity) = LGECalculationsLibrary
        //     .getETHPriceFromRange(
        //         LGEHook(hookAddress).tokensAvailable(),
        //         tokensAvailable,
        //         baseTick,
        //         currentTick,
        //         tickSpacing
        //     );
        // console.log("ETH price per desired tokens amount:", maxETH);
        console.log("Tokens Available:", LGEHook(hookAddress).tokensAvailable());
        console.log("Desired Tokens Amount:", tokenAmount);

        (uint256 ethAmount, uint128 liquidity) =
            LGECalculationsLibrary.getAmountsForLiquidity(sqrtPriceX96, tickLower, tickUpper, currentTick, tokenAmount);

        console.log("ETH Amount calculated:", ethAmount);
        console.log("Liquidity calculated:", liquidity);
        LGEHook(hookAddress).addLiquidity{value: ethAmount * 2}(tokenAmount);

        console.log("Balance:", address(hookAddress).balance);

        console.log("Liquidity:", StateLibrary.getLiquidity(manager, poolId));
    }
}
