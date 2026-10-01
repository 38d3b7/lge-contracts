// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";
import {LGEToken} from "../src/LGEToken.sol";
import {LGECalculationsLibrary} from "../src/libraries/LGECalculationsLibrary.sol";

/// @title SmokeLGE
/// @notice Arc testnet smoke driver for the LGE flow. One script, parameterized
///         by env vars; SMOKE_ACTION selects the step:
///           create   — LGE_MANAGER, POOL_MANAGER, POSITION_MANAGER, PERMIT2,
///                      DEPLOYER, TOKEN_NAME, TOKEN_SYMBOL [, START_BLOCK]
///           deposit  — HOOK, DEPLOYER, AMOUNT (wei of tokens) or FILL_CAP=1
///           claim    — HOOK, DEPLOYER
///           withdraw — HOOK, DEPLOYER
///           status   — HOOK (view only, no broadcast)
/// @dev Run with the Arc library link so type(LGEHook).creationCode matches the
///      frontend bytecode and the mined salt is valid:
///      FOUNDRY_LIBRARIES="src/libraries/LGECalculationsLibrary.sol:LGECalculationsLibrary:<libAddr>" \
///      forge script script/SmokeLGE.s.sol --rpc-url arc_testnet --broadcast \
///        --private-key $PRIVATE_KEY --gas-price 20000000000 --priority-gas-price 1000000000
contract SmokeLGE is Script {
    function run() external {
        string memory action = vm.envString("SMOKE_ACTION");
        bytes32 a = keccak256(bytes(action));
        if (a == keccak256("create")) {
            create();
        } else if (a == keccak256("deposit")) {
            deposit();
        } else if (a == keccak256("claim")) {
            claim();
        } else if (a == keccak256("withdraw")) {
            withdraw();
        } else if (a == keccak256("status")) {
            status();
        } else {
            revert("unknown SMOKE_ACTION");
        }
    }

    function create() internal {
        address deployer = vm.envAddress("DEPLOYER");
        LGEManager manager = LGEManager(vm.envAddress("LGE_MANAGER"));
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        uint256 startBlock = vm.envOr("START_BLOCK", block.number + 3);

        // Same derivation as the frontend (useCampaignAddresses/useCreateCampaign)
        bytes32 tokenSalt = keccak256(abi.encodePacked(deployer, block.timestamp));
        bytes memory tokenArgs = abi.encode(name, symbol, deployer, "", "", address(manager));
        bytes32 tokenInitHash = keccak256(abi.encodePacked(type(LGEToken).creationCode, tokenArgs));
        address tokenAddress = vm.computeCreate2Address(tokenSalt, tokenInitHash, address(manager));

        bytes memory hookArgs = abi.encode(poolManager, positionManager, permit2, tokenAddress, startBlock);
        (address hookAddress, bytes32 hookSalt) =
            HookMiner.find(address(manager), uint160(manager.FLAGS()), type(LGEHook).creationCode, hookArgs);

        vm.startBroadcast();
        (address deployedToken, address deployedHook) = manager.deployToken(
            LGEManager.DeploymentConfig({
                tokenConfig: LGEManager.TokenConfig({
                    tokenAdmin: deployer,
                    name: name,
                    symbol: symbol,
                    image: "",
                    metadata: "",
                    tokenSalt: tokenSalt
                }),
                hookConfig: LGEManager.HookConfig({hookSalt: hookSalt, startBlock: startBlock})
            })
        );
        vm.stopBroadcast();

        require(deployedToken == tokenAddress, "token address mismatch");
        require(deployedHook == hookAddress, "hook address mismatch");

        console.log("TOKEN_ADDRESS=%s", deployedToken);
        console.log("HOOK_ADDRESS=%s", deployedHook);
        console.log("START_BLOCK=%s", startBlock);
    }

    function deposit() internal {
        LGEHook hook = LGEHook(payable(vm.envAddress("HOOK")));
        uint256 amount;
        if (vm.envOr("FILL_CAP", false)) {
            amount = hook.token().cap() - hook.totalTokensClaimed();
        } else {
            amount = vm.envUint("AMOUNT");
        }
        uint256 startBlock = hook.startBlock();
        uint256 price = LGECalculationsLibrary.calculateCurrentTokenPrice(block.number, startBlock);
        uint256 nativeNeeded = LGECalculationsLibrary.calculateEthNeeded(block.number, startBlock, amount);
        uint256 value = (nativeNeeded * 105) / 100;

        console.log("PRICE=%s", price);
        console.log("AMOUNT=%s", amount);
        console.log("NATIVE_NEEDED=%s", nativeNeeded);

        vm.startBroadcast();
        hook.deposit{value: value}(amount);
        vm.stopBroadcast();

        console.log("IS_FINISHED=%s", hook.isLgeFinished());
        console.log("IS_SUCCESSFUL=%s", hook.isLgeSuccessful());
        console.log("TOTAL_CLAIMED=%s", hook.totalTokensClaimed());
        console.log("POSITION_TOKEN_ID=%s", hook.positionTokenId());
    }

    function claim() internal {
        LGEHook hook = LGEHook(payable(vm.envAddress("HOOK")));
        address deployer = vm.envAddress("DEPLOYER");
        IPositionManager pm = hook.positionManager();
        uint256 balBefore = IERC721(address(pm)).balanceOf(deployer);

        vm.startBroadcast();
        uint256 userPositionId = hook.claimLiquidity();
        vm.stopBroadcast();

        console.log("USER_POSITION_ID=%s", userPositionId);
        console.log("LP_BALANCE_BEFORE=%s", balBefore);
        console.log("LP_BALANCE_AFTER=%s", IERC721(address(pm)).balanceOf(deployer));
        console.log("POSITION_OWNER=%s", IERC721(address(pm)).ownerOf(userPositionId));
    }

    function withdraw() internal {
        LGEHook hook = LGEHook(payable(vm.envAddress("HOOK")));
        address deployer = vm.envAddress("DEPLOYER");
        (uint256 ethToLiquidity, uint256 remaining,,) = hook.userStates(deployer);
        uint256 expectedRefund = ethToLiquidity + remaining;
        uint256 hookBalBefore = address(hook).balance;

        vm.startBroadcast();
        hook.withdraw();
        vm.stopBroadcast();

        console.log("EXPECTED_REFUND=%s", expectedRefund);
        console.log("HOOK_BALANCE_BEFORE=%s", hookBalBefore);
        console.log("HOOK_BALANCE_AFTER=%s", address(hook).balance);
        require(expectedRefund > 0, "nothing deposited");
        require(address(hook).balance == hookBalBefore - expectedRefund, "refund mismatch");
    }

    function status() internal view {
        LGEHook hook = LGEHook(payable(vm.envAddress("HOOK")));
        uint256 startBlock = hook.startBlock();
        console.log("BLOCK=%s", block.number);
        console.log("START_BLOCK=%s", startBlock);
        console.log("STREAM_END=%s", startBlock + hook.STREAM_BLOCKS());
        console.log("PRICE=%s", LGECalculationsLibrary.calculateCurrentTokenPrice(block.number, startBlock));
        console.log("IS_FINISHED=%s", hook.isLgeFinished());
        console.log("IS_SUCCESSFUL=%s", hook.isLgeSuccessful());
        console.log("TOTAL_CLAIMED=%s", hook.totalTokensClaimed());
        console.log("CAP=%s", hook.token().cap());
        console.log("TOTAL_NATIVE_TO_LIQ=%s", hook.totalEthToLiquidity());
        console.log("TOTAL_LIQUIDITY=%s", hook.totalLiquidity());
        console.log("POSITION_TOKEN_ID=%s", hook.positionTokenId());
    }
}
