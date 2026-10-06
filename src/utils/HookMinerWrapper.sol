// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

contract HookMinerWrapper {
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) external view returns (address hookAddress, bytes32 salt) {
        return HookMiner.find(deployer, flags, creationCode, constructorArgs);
    }
}
