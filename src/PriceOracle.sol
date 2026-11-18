// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PriceOracle
/// @notice Demo price source living on the ORIGIN chain (Base Sepolia).
///         Every price push emits `PriceUpdated`, which is the event the reactive
///         contract on Lasna subscribes to. In production this role is played by a
///         real oracle / DEX pool; the reactive side does not care who emits the
///         event, only that it matches the subscription criteria.
contract PriceOracle {
    /// @notice topic_0 of this event is what StopLossReactive subscribes to.
    /// @param token The asset whose price moved (indexed -> becomes topic_1).
    /// @param price New price, 18-decimal fixed point (e.g. 100e18 == $100).
    /// @param updatedAt Timestamp of the update (Base Sepolia blocks arrive every
    ///        ~200ms, so timers must be timestamp-based, never block-based).
    event PriceUpdated(address indexed token, uint256 price, uint256 updatedAt);

    mapping(address => uint256) public priceOf;
    mapping(address => uint256) public updatedAtOf;

    /// @notice Push a new price for `token` and emit the reactive trigger event.
    function setPrice(address token, uint256 price) external {
        priceOf[token] = price;
        updatedAtOf[token] = block.timestamp;
        emit PriceUpdated(token, price, block.timestamp);
    }
}
