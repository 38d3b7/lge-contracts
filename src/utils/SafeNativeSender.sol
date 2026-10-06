// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

abstract contract SafeNativeSender {
    mapping(address => uint256) public pendingNative;

    event NativeSendParked(address indexed to, uint256 amount);
    event PendingNativeClaimed(address indexed to, uint256 amount);

    error NothingPending();

    function _sendNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) {
            pendingNative[to] += amount;
            emit NativeSendParked(to, amount);
        }
    }

    function claimPendingNative() external {
        uint256 amount = pendingNative[msg.sender];
        if (amount == 0) revert NothingPending();
        pendingNative[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert();
        emit PendingNativeClaimed(msg.sender, amount);
    }
}
