// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";

contract LGEManagerTest is Test, Deployers {
    LGEManager lgeManager;

    address owner = address(0xABCD);
    address tokenAdmin = address(0x1234);
    address tokenCreator = address(0x5678);

    function setUp() public {
        deployFreshManagerAndRouters();

        lgeManager = new LGEManager(manager, address(this));
    }

    function test_deployToken() public {
        vm.startPrank(tokenCreator);
        LGEManager.TokenConfig memory tokenConfig = LGEManager.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "Test Token",
            symbol: "TEST",
            image: "https://example.com/image.png",
            metadata: "https://example.com/metadata.json"
        });
        LGEManager.PoolConfig memory poolConfig = LGEManager.PoolConfig({
            initialSqrtPriceX96: SQRT_PRICE_1_1,
            fee: 3000,
            tickSpacing: 1
        });
        LGEManager.DeploymentConfig memory deploymentConfig = LGEManager
            .DeploymentConfig({
                tokenConfig: tokenConfig,
                poolConfig: poolConfig
            });

        lgeManager.deployToken(deploymentConfig);
    }
}
