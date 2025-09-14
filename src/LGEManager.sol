// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {LGEHook} from "./hooks/LGEHook.sol";
import {LGEToken} from "./LGEToken.sol";

contract LGEManager {
    IPoolManager private immutable _poolManager;
    IPositionManager private immutable _positionManager;
    IAllowanceTransfer private immutable _permit2;
    address private immutable _create2Deployer;
    uint160 private immutable FLAGS =
        uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG
        );

    struct TokenConfig {
        address tokenAdmin;
        string name;
        string symbol;
        string image;
        string metadata;
    }

    struct HookConfig {
        uint256 minTokenPrice;
        uint256 maxTokenPrice;
    }

    struct DeploymentConfig {
        TokenConfig tokenConfig;
        HookConfig hookConfig;
    }

    event TokenCreated(
        address msgSender,
        address indexed tokenAddress,
        address indexed hookAddress
    );

    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        address create2Deployer_
    ) {
        _poolManager = poolManager_;
        _positionManager = positionManager_;
        _permit2 = permit2_;
        _create2Deployer = create2Deployer_;
    }

    function deployToken(
        DeploymentConfig calldata config
    ) external returns (address tokenAddress, address hookAddress) {
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

        bytes memory constructorArgs = abi.encode(
            _poolManager,
            _positionManager,
            _permit2,
            tokenAddress,
            block.number,
            config.hookConfig.minTokenPrice,
            config.hookConfig.maxTokenPrice
        );

        (, bytes32 salt) = HookMiner.find(
            // TODO: should we remove this and set as a _create2Deployer on the mainnet?
            address(this),
            FLAGS,
            type(LGEHook).creationCode,
            constructorArgs
        );

        hookAddress = address(
            new LGEHook{salt: salt}(
                _poolManager,
                _positionManager,
                _permit2,
                tokenAddress,
                block.number,
                config.hookConfig.minTokenPrice,
                config.hookConfig.maxTokenPrice
            )
        );

        LGEToken(tokenAddress).setMinter(hookAddress);

        emit TokenCreated(msg.sender, tokenAddress, hookAddress);
    }
}
