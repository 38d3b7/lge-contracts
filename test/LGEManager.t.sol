// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";
import {LGEToken} from "../src/LGEToken.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {InferenceEscrow} from "../src/InferenceEscrow.sol";
import {HookCreationCode} from "../src/HookCreationCode.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {Deploy} from "./utils/Deploy.sol";

contract LGEManagerTest is Test, Deployers {
    uint160 private immutable FLAGS =
        uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
                Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

    LGEManager lgeManager;
    VestingVault vestingVault;
    InferenceEscrow inferenceEscrow;
    HookCreationCode hookCreationCode;

    address owner = address(0xABCD);
    address protocol = address(0xBEEF);
    address tokenAdmin = address(0x1234);
    address tokenCreator = address(0x5678);

    uint256 startBlock = 31160653;
    uint256 constant CAP = 1_000_000e18;

    function setUp() public {
        deployFreshManagerAndRouters();
        Deploy.lgeCalculationsLibrary();

        vestingVault = new VestingVault();
        inferenceEscrow = new InferenceEscrow(owner);
        hookCreationCode = new HookCreationCode();

        lgeManager = new LGEManager(
            address(manager),
            address(this),
            address(this),
            address(vestingVault),
            address(inferenceEscrow),
            protocol,
            address(hookCreationCode)
        );
    }

    function test_deployToken() public {
        vm.roll(startBlock);
        vm.startPrank(tokenAdmin); // the agent launches for itself

        LGEManager.TokenConfig memory tokenConfig = LGEManager.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "Test Token",
            symbol: "TEST",
            image: "https://example.com/image.png",
            metadata: "https://example.com/metadata.json",
            cap: CAP,
            tokenSalt: keccak256(abi.encodePacked(tokenAdmin, block.timestamp))
        });

        bytes memory tokenConstructorArgs = abi.encode(
            tokenConfig.name,
            tokenConfig.symbol,
            tokenConfig.tokenAdmin,
            tokenConfig.image,
            tokenConfig.metadata,
            address(lgeManager),
            CAP
        );

        address tokenAddress = vm.computeCreate2Address(
            tokenConfig.tokenSalt,
            hashInitCode(type(LGEToken).creationCode, tokenConstructorArgs),
            address(lgeManager)
        );

        LGEHook.HookParams memory params = LGEHook.HookParams({
            poolManager: address(manager),
            positionManager: address(this),
            permit2: address(this),
            token: tokenAddress,
            agent: tokenAdmin,
            operator: address(0x0909),
            protocol: protocol,
            vestingVault: address(vestingVault),
            inferenceEscrow: address(inferenceEscrow),
            startBlock: startBlock,
            streamBlocks: 172_800,
            minTokenPrice: 0.001e18,
            maxTokenPrice: 0.01e18,
            exitThreshold: 0,
            feeBps: 100,
            vestingCliff: 365 days, // launch minimum
            vestingDuration: 365 days
        });

        bytes memory constructorArgs = abi.encode(params);

        (, bytes32 salt) = HookMiner.find(
            address(lgeManager),
            FLAGS,
            type(LGEHook).creationCode,
            constructorArgs
        );

        LGEManager.HookConfig memory hookConfig = LGEManager.HookConfig({
            hookSalt: salt,
            startBlock: startBlock,
            streamBlocks: params.streamBlocks,
            minTokenPrice: params.minTokenPrice,
            maxTokenPrice: params.maxTokenPrice,
            exitThreshold: params.exitThreshold,
            feeBps: params.feeBps,
            vestingCliff: params.vestingCliff,
            vestingDuration: params.vestingDuration,
            operator: params.operator
        });

        LGEManager.DeploymentConfig memory deploymentConfig;
        deploymentConfig.tokenConfig = tokenConfig;
        deploymentConfig.hookConfig = hookConfig;

        (address deployedToken, address deployedHook) = lgeManager.deployToken(
            deploymentConfig
        );

        assertEq(deployedToken, tokenAddress);
        assertTrue(uint160(deployedHook) & FLAGS == FLAGS);
        assertEq(LGEToken(deployedToken).hook(), deployedHook);
        assertEq(LGEHook(payable(deployedHook)).agent(), tokenAdmin);
        vm.stopPrank();
    }
}
