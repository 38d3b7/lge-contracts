// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @title HookMinerWrapper
/// @notice Deployable wrapper exposing HookMiner.find for off-chain callers.
/// @dev HookMiner is an internal library (inlined at compile time); the frontend
///      mines hook salts by eth_call-ing `find` on a deployed instance of this wrapper.
contract HookMinerWrapper {
    /// @notice Find a salt that produces a hook address with the desired `flags`
    /// @param deployer The address that will deploy the hook (the LGEManager)
    /// @param flags The desired hook address flags (see LGEManager.FLAGS)
    /// @param creationCode The creation code of the hook contract
    /// @param constructorArgs The encoded constructor arguments of the hook contract
    /// @return hookAddress The address the hook deploys to with `salt`
    /// @return salt The salt to use with `new LGEHook{salt: salt}(...)`
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) external view returns (address hookAddress, bytes32 salt) {
        return HookMiner.find(deployer, flags, creationCode, constructorArgs);
    }
}
