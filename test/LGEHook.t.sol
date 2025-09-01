// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

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
    int24 tickSpacing = 60;

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
        LGEManager.PoolConfig memory poolConfig = LGEManager.PoolConfig({
            initialSqrtPriceX96: 792281625142643375935439503360,
            fee: 3000,
            tickSpacing: tickSpacing
        });
        LGEManager.DeploymentConfig memory deploymentConfig = LGEManager
            .DeploymentConfig({
                tokenConfig: tokenConfig,
                poolConfig: poolConfig
            });

        vm.prank(tokenCreator);
        vm.roll(10);
        (tokenAddress, hookAddress, poolId) = lgeManager.deployToken(
            deploymentConfig
        );
        startingBlock = block.number;
    }

    function test_addLiquidity() public {
        vm.roll(11);
        vm.deal(user, 180 ether);
        vm.prank(user);
        int24 baseTick = TickMath.getTickAtSqrtPrice(
            792281625142643375935439503360
        );
        (, int24 currentTick, , ) = StateLibrary.getSlot0(manager, poolId);
        (uint256 halfEth, ) = LGECalculationsLibrary.getETHPriceFromRange(
            LGEHook(hookAddress).tokensAvailable(),
            baseTick,
            currentTick,
            tickSpacing
        );
        console.log("Half ETH:", halfEth);
        console.log(
            "Tokens Available:",
            LGEHook(hookAddress).tokensAvailable()
        );
        LGEHook(hookAddress).addLiquidity{value: halfEth * 2}();
        console.log("Balance:", address(hookAddress).balance);

        console.log("Liquidity:", StateLibrary.getLiquidity(manager, poolId));
    }
}
