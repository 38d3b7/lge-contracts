// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {LGEHook} from "./hooks/LGEHook.sol";

contract HookCreationCode {
    function creationCode() external pure returns (bytes memory) {
        return type(LGEHook).creationCode;
    }
}
