// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {LGEHook} from "./hooks/LGEHook.sol";
import {LGEToken} from "./LGEToken.sol";

contract LGEManager {
    address public immutable _poolManager;
    address public immutable _positionManager;
    address public immutable _permit2;
    uint160 public immutable FLAGS =
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
        bytes32 tokenSalt;
    }

    struct HookConfig {
        uint256 minTokenPrice;
        uint256 maxTokenPrice;
        bytes32 hookSalt;
        uint256 startBlock;
    }

    struct DeploymentConfig {
        TokenConfig tokenConfig;
        HookConfig hookConfig;
    }

    event TokenCreated(
        address indexed msgSender,
        address indexed tokenAddress,
        address indexed hookAddress
    );

    constructor(
        address poolManager_,
        address positionManager_,
        address permit2_
    ) {
        _poolManager = poolManager_;
        _positionManager = positionManager_;
        _permit2 = permit2_;
    }

    function deployToken(
        DeploymentConfig calldata config
    ) external returns (address tokenAddress, address hookAddress) {
        tokenAddress = address(
            new LGEToken{salt: config.tokenConfig.tokenSalt}(
                config.tokenConfig.name,
                config.tokenConfig.symbol,
                config.tokenConfig.tokenAdmin,
                config.tokenConfig.image,
                config.tokenConfig.metadata,
                address(this)
            )
        );

        hookAddress = address(
            new LGEHook{salt: config.hookConfig.hookSalt}(
                _poolManager,
                _positionManager,
                _permit2,
                tokenAddress,
                config.hookConfig.startBlock,
                config.hookConfig.minTokenPrice,
                config.hookConfig.maxTokenPrice
            )
        );

        LGEToken(tokenAddress).setMinter(hookAddress);

        emit TokenCreated(msg.sender, tokenAddress, hookAddress);
    }
}
