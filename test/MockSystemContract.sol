// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @notice Test double for the Reactive Omni system contract
///         (0x8888888888888888888888888888888888888888). Tests etch this
///         contract's code at the system address so subscriptions and
///         callback requests can be recorded and asserted locally.
contract MockSystemContract {
    uint256 public subscribeCalls;
    uint256 public callbackRequests;
    uint256 public lastChainId;
    address public lastRecipient;
    uint64 public lastGasLimit;
    bytes public lastPayload;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {
        callbackRequests++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackRequests++;
        lastChainId = config_.chainId;
        lastRecipient = config_.recipient;
        lastGasLimit = config_.gasLimit;
        lastPayload = config_.payload;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function reserves(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    receive() external payable {}
}
