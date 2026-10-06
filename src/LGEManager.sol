// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {LGEHook} from "./hooks/LGEHook.sol";
import {LGEToken} from "./LGEToken.sol";

interface IHookCreationCode {
    function creationCode() external view returns (bytes memory);
}

contract LGEManager {
    address public immutable _poolManager;
    address public immutable _positionManager;
    address public immutable _permit2;
    address public immutable _vestingVault;
    address public immutable _inferenceEscrow;
    address public immutable _protocol;
    address public immutable _hookCreationCode;

    uint160 public immutable FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    struct TokenConfig {
        address tokenAdmin;
        string name;
        string symbol;
        string image;
        string metadata;
        uint256 cap;
        bytes32 tokenSalt;
    }

    struct HookConfig {
        bytes32 hookSalt;
        uint256 startBlock;
        uint256 streamBlocks;
        uint256 minTokenPrice;
        uint256 maxTokenPrice;
        uint256 exitThreshold;
        uint24 feeBps;
        uint64 vestingCliff;
        uint64 vestingDuration;
        address operator;
    }

    struct DeploymentConfig {
        TokenConfig tokenConfig;
        HookConfig hookConfig;
    }

    enum LaunchStatus {
        None,
        Active,
        Failed,
        Successful
    }

    mapping(address => address) public launchOf;

    event TokenCreated(address indexed msgSender, address indexed tokenAddress, address indexed hookAddress);

    error HookDeployFailed();
    error NotTokenAdmin();
    error AlreadyLaunched();
    error LaunchActive();
    error CliffTooShort();

    uint64 public constant MIN_VESTING_CLIFF = 365 days;

    constructor(
        address poolManager_,
        address positionManager_,
        address permit2_,
        address vestingVault_,
        address inferenceEscrow_,
        address protocol_,
        address hookCreationCode_
    ) {
        _poolManager = poolManager_;
        _positionManager = positionManager_;
        _permit2 = permit2_;
        _vestingVault = vestingVault_;
        _inferenceEscrow = inferenceEscrow_;
        _protocol = protocol_;
        _hookCreationCode = hookCreationCode_;
    }

    function deployToken(
        DeploymentConfig calldata config
    ) external returns (address tokenAddress, address hookAddress) {
        address agent = config.tokenConfig.tokenAdmin;
        if (msg.sender != agent) revert NotTokenAdmin();
        if (config.hookConfig.vestingCliff < MIN_VESTING_CLIFF) revert CliffTooShort();

        LaunchStatus status = statusOf(agent);
        if (status == LaunchStatus.Successful) revert AlreadyLaunched();
        if (status == LaunchStatus.Active) revert LaunchActive();

        tokenAddress = _deployToken(config.tokenConfig);
        hookAddress = _deployHook(config.hookConfig, agent, tokenAddress);
        launchOf[agent] = hookAddress;

        LGEToken(tokenAddress).setMinter(hookAddress);

        emit TokenCreated(msg.sender, tokenAddress, hookAddress);
    }

    function statusOf(address agent) public view returns (LaunchStatus) {
        address hook = launchOf[agent];
        if (hook == address(0)) return LaunchStatus.None;
        LGEHook h = LGEHook(payable(hook));
        if (h.isLgeSuccessful()) return LaunchStatus.Successful;
        if (block.number <= h.startBlock() + h.streamBlocks()) {
            return LaunchStatus.Active;
        }
        return LaunchStatus.Failed;
    }

    function _deployToken(
        TokenConfig calldata config
    ) internal returns (address tokenAddress) {
        tokenAddress = address(
            new LGEToken{salt: config.tokenSalt}(
                config.name,
                config.symbol,
                config.tokenAdmin,
                config.image,
                config.metadata,
                address(this),
                config.cap
            )
        );
    }

    function _deployHook(
        HookConfig calldata config,
        address agent,
        address token
    ) internal returns (address hookAddress) {
        bytes memory initCode = abi.encodePacked(
            IHookCreationCode(_hookCreationCode).creationCode(),
            abi.encode(
                LGEHook.HookParams({
                    poolManager: _poolManager,
                    positionManager: _positionManager,
                    permit2: _permit2,
                    token: token,
                    agent: agent,
                    operator: config.operator,
                    protocol: _protocol,
                    vestingVault: _vestingVault,
                    inferenceEscrow: _inferenceEscrow,
                    startBlock: config.startBlock,
                    streamBlocks: config.streamBlocks,
                    minTokenPrice: config.minTokenPrice,
                    maxTokenPrice: config.maxTokenPrice,
                    exitThreshold: config.exitThreshold,
                    feeBps: config.feeBps,
                    vestingCliff: config.vestingCliff,
                    vestingDuration: config.vestingDuration
                })
            )
        );
        bytes32 salt = config.hookSalt;
        assembly {
            hookAddress := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (hookAddress == address(0)) revert HookDeployFailed();
    }
}
