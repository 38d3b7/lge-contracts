// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";

contract LGEManagerTest is Test, Deployers {
    LGEManager lgeManager;

    address owner = address(0xABCD);
    address tokenAdmin = address(0x1234);
    address tokenCreator = address(0x5678);

    function setUp() public {
        deployFreshManagerAndRouters();

        lgeManager = new LGEManager(
            manager,
            address(this),
            address(this),
            address(this)
        );
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
        LGEManager.HookConfig memory hookConfig = LGEManager.HookConfig({
            minTokenPrice: 100000000000000,
            maxTokenPrice: 200000000000000
        });
        LGEManager.DeploymentConfig memory deploymentConfig = LGEManager
            .DeploymentConfig({
                tokenConfig: tokenConfig,
                hookConfig: hookConfig
            });

        lgeManager.deployToken(deploymentConfig);
    }
}
