// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title GuardianVault
/// @notice Destination-chain contract (Base Sepolia). Custodies user positions,
///         announces stop-losses as events, and closes positions when Reactive
///         Network delivers the stop-loss callback.
///
///         Why stops are announced as EVENTS: a reactive contract builds the
///         state it acts on from the events it processes. Configuration
///         written by direct calls is not part of that flow. The canonical
///         Reactive pattern is therefore used here: the vault emits
///         `StopRegistered`, the reactive contract reacts to it and records
///         the stop in its own state.
///
///         Security model (Reactive Omni standard):
///         - `callback()` can only be invoked by the chain's Callback Proxy
///           (checked against msg.sender AND the proxy is the contract's
///           fee service provider in AbstractCallback/AbstractPayer).
///         - The first callback argument is the sender slot that Reactive
///           Network injects with the requesting reactive contract's address;
///           it must equal the StopLossReactive address (`onlyCallbackSender`).
///         Anyone else calling `callback()` reverts.
///
///         In production, closing a position would swap through a DEX into a
///         stablecoin. For this demo the custodied tokens are released back to
///         the position owner, which keeps the full event -> react -> callback
///         loop verifiable on-chain without depending on a testnet DEX.
contract GuardianVault is AbstractCallback {
    struct Position {
        address owner;
        address token;
        uint256 amount;
        uint256 stopTriggerPrice;
        bool open;
    }

    Position[] public positions;

    event PositionOpened(uint256 indexed positionId, address indexed owner, address indexed token, uint256 amount);
    event PositionClosed(uint256 indexed positionId, address indexed owner, uint256 amount, uint256 closedAt);
    event PositionWithdrawn(uint256 indexed positionId, address indexed owner, uint256 amount);

    /// @notice Consumed by StopLossReactive: a stop now guards `positionId`.
    ///         topic_1 = positionId, topic_2 = token, data = triggerPrice.
    event StopRegistered(uint256 indexed positionId, address indexed token, uint256 triggerPrice);

    /// @notice Consumed by StopLossReactive: the stop for `positionId` is gone
    ///         (position withdrawn manually before the stop could fire).
    event StopCancelled(uint256 indexed positionId);

    /// @param callbackProxy The Callback Proxy address of the destination chain
    ///        (Base Sepolia: 0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param reactiveContract The StopLossReactive address on Reactive Lasna —
    ///        the only sender whose callbacks this vault accepts.
    constructor(address callbackProxy, address reactiveContract)
        AbstractCallback(IPayable(payable(callbackProxy)), reactiveContract)
    {}

    /// @notice Settles any outstanding callback-proxy debt from this
    ///         contract's own balance (see Reactive economy docs).
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Open a custodied position by depositing `amount` of `token`.
    /// @param stopTriggerPrice If > 0, a stop-loss is registered (via the
    ///        `StopRegistered` event) at this price, same units as the oracle.
    /// @dev Caller must approve this contract first. Returns the position id.
    function deposit(address token, uint256 amount, uint256 stopTriggerPrice)
        external
        returns (uint256 positionId)
    {
        require(amount > 0, "amount=0");
        require(IERC20Minimal(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        positionId = positions.length;
        positions.push(
            Position({owner: msg.sender, token: token, amount: amount, stopTriggerPrice: stopTriggerPrice, open: true})
        );
        emit PositionOpened(positionId, msg.sender, token, amount);
        if (stopTriggerPrice > 0) {
            emit StopRegistered(positionId, token, stopTriggerPrice);
        }
    }

    /// @notice Escape hatch: the owner can always withdraw an open position
    ///         manually; the guardian is an automation layer, never a lock.
    ///         Also cancels the stop (via the `StopCancelled` event).
    function withdraw(uint256 positionId) external {
        Position storage p = positions[positionId];
        require(p.open, "position closed");
        require(p.owner == msg.sender, "not owner");
        p.open = false;
        if (p.stopTriggerPrice > 0) {
            emit StopCancelled(positionId);
        }
        require(IERC20Minimal(p.token).transfer(p.owner, p.amount), "transfer failed");
        emit PositionWithdrawn(positionId, p.owner, p.amount);
    }

    /// @notice Reactive Network callback entry point. Invoked by the Callback
    ///         Proxy when StopLossReactive requests a callback to this vault.
    /// @param sender_ Sender slot injected by Reactive Network: the address of
    ///        the requesting reactive contract.
    /// @param positionId The position to close.
    function callback(address sender_, uint256 positionId) external onlyCallbackSender(sender_) {
        require(msg.sender == address(_SERVICE_PROVIDER), "proxy only");
        Position storage p = positions[positionId];
        require(p.open, "position closed");
        p.open = false;
        require(IERC20Minimal(p.token).transfer(p.owner, p.amount), "transfer failed");
        emit PositionClosed(positionId, p.owner, p.amount, block.timestamp);
    }

    function positionsCount() external view returns (uint256) {
        return positions.length;
    }

    function getPosition(uint256 positionId)
        external
        view
        returns (address owner, address token, uint256 amount, bool open)
    {
        Position storage p = positions[positionId];
        return (p.owner, p.token, p.amount, p.open);
    }
}
