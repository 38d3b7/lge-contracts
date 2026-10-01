// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {LGEManager} from "../src/LGEManager.sol";
import {HookMinerWrapper} from "../src/utils/HookMinerWrapper.sol";

/// @title Deploy
/// @notice Env-driven deployment of the LGE infrastructure contracts.
///         One script for all chains — no per-chain forks.
///
/// Required env vars (loaded from .env):
///   PRIVATE_KEY       - deployer key (funded with the chain's native gas token)
///   POOL_MANAGER      - Uniswap v4 PoolManager address
///   POSITION_MANAGER  - Uniswap v4 PositionManager address
///   PERMIT2           - Permit2 address
///
/// Prerequisite: LGECalculationsLibrary must already be deployed on the target
/// chain and the build linked against it, e.g.:
///   FOUNDRY_LIBRARIES="src/libraries/LGECalculationsLibrary.sol:LGECalculationsLibrary:<addr>" forge build
/// LGEManager embeds LGEHook bytecode (which calls the library) at compile time,
/// so the library link must be in place before this script runs.
///
/// Arc Testnet usage (gas floor is 20 gwei — do not go below):
///   forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast \
///     --gas-price 20gwei --priority-gas-price 1gwei
/// (on EIP-1559 chains forge's --gas-price sets maxFeePerGas)
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");

        vm.startBroadcast(deployerKey);

        HookMinerWrapper hookMiner = new HookMinerWrapper();
        LGEManager manager = new LGEManager(poolManager, positionManager, permit2);

        vm.stopBroadcast();

        console.log("HookMinerWrapper:", address(hookMiner));
        console.log("LGEManager:", address(manager));
        console.log("  poolManager:", poolManager);
        console.log("  positionManager:", positionManager);
        console.log("  permit2:", permit2);
    }
}
