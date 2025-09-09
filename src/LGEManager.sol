// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {LGEHook} from "./hooks/LGEHook.sol";
import {LGEToken} from "./LGEToken.sol";

contract LGEManager {
    IPoolManager private immutable _poolManager;
    address private immutable _create2Deployer;
    uint160 private immutable FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);

    struct TokenConfig {
        address tokenAdmin;
        string name;
        string symbol;
        string image;
        string metadata;
    }

    struct PoolConfig {
        uint24 fee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
    }

    struct DeploymentConfig {
        TokenConfig tokenConfig;
        PoolConfig poolConfig;
    }

    event TokenCreated(
        address msgSender, address indexed tokenAddress, address indexed hookAddress, PoolId indexed poolId
    );

    constructor(IPoolManager poolManager_, address create2Deployer_) {
        _poolManager = poolManager_;
        _create2Deployer = create2Deployer_;
    }

    function deployToken(DeploymentConfig calldata config)
        external
        returns (address tokenAddress, address hookAddress, PoolId poolId)
    {
        tokenAddress = address(
            new LGEToken(
                config.tokenConfig.name,
                config.tokenConfig.symbol,
                config.tokenConfig.tokenAdmin,
                config.tokenConfig.image,
                config.tokenConfig.metadata,
                address(this)
            )
        );

        bytes memory constructorArgs =
            abi.encode(_poolManager, tokenAddress, block.number, config.poolConfig.initialSqrtPriceX96);

        (, bytes32 salt) = HookMiner.find(
            // TODO: should we remove this and set as a _create2Deployer on the mainnet?
            address(this),
            FLAGS,
            type(LGEHook).creationCode,
            constructorArgs
        );

        hookAddress = address(
            new LGEHook{salt: salt}(_poolManager, tokenAddress, block.number, config.poolConfig.initialSqrtPriceX96)
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddress),
            fee: config.poolConfig.fee,
            tickSpacing: config.poolConfig.tickSpacing,
            hooks: IHooks(hookAddress)
        });

        _poolManager.initialize(poolKey, config.poolConfig.initialSqrtPriceX96);

        LGEToken(tokenAddress).setMinter(hookAddress);

        poolId = poolKey.toId();

        emit TokenCreated(msg.sender, tokenAddress, hookAddress, poolId);
    }
}
