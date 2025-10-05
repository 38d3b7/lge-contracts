// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";
import {LGEToken} from "../src/LGEToken.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

contract LGEManagerTest is Test, Deployers {
    uint160 private immutable FLAGS =
        uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG
        );

    LGEManager lgeManager;

    address owner = address(0xABCD);
    address tokenAdmin = address(0x1234);
    address tokenCreator = address(0x5678);

    uint256 startBlock = 31160653;

    function setUp() public {
        deployFreshManagerAndRouters();

        lgeManager = new LGEManager(
            address(manager),
            address(this),
            address(this)
        );
    }

    function test_deployToken() public {
        vm.roll(startBlock);
        vm.startPrank(tokenCreator);

        LGEManager.TokenConfig memory tokenConfig = LGEManager.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "Test Token",
            symbol: "TEST",
            image: "https://example.com/image.png",
            metadata: "https://example.com/metadata.json",
            tokenSalt: keccak256(abi.encodePacked(tokenAdmin, block.timestamp))
        });

        bytes memory tokenConstructorArgs = abi.encode(
            tokenConfig.name,
            tokenConfig.symbol,
            tokenConfig.tokenAdmin,
            tokenConfig.image,
            tokenConfig.metadata,
            address(lgeManager)
        );

        address tokenAddress = vm.computeCreate2Address(
            tokenConfig.tokenSalt,
            hashInitCode(type(LGEToken).creationCode, tokenConstructorArgs),
            address(lgeManager)
        );
        console.log("address from the tests: ", tokenAddress);

        bytes memory constructorArgs = abi.encode(
            address(manager),
            address(this),
            address(this),
            tokenAddress,
            startBlock,
            100000000000000,
            200000000000000
        );

        (, bytes32 salt) = HookMiner.find(
            address(lgeManager),
            FLAGS,
            type(LGEHook).creationCode,
            constructorArgs
        );

        LGEManager.HookConfig memory hookConfig = LGEManager.HookConfig({
            minTokenPrice: 100000000000000,
            maxTokenPrice: 200000000000000,
            hookSalt: salt,
            startBlock: startBlock
        });

        LGEManager.DeploymentConfig memory deploymentConfig = LGEManager
            .DeploymentConfig({
                tokenConfig: tokenConfig,
                hookConfig: hookConfig
            });

        lgeManager.deployToken(deploymentConfig);
    }
}
