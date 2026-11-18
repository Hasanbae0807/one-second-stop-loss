// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @title StopLossReactive — "One-Second Stop-Loss"
/// @notice Reactive contract deployed on Reactive Lasna (chain 5318007),
///         built on the Reactive Omni library (reactive-lib-omni).
///
///         It watches Base Sepolia (chain 84532) for three events:
///           - `StopRegistered`  from GuardianVault — a new stop to guard.
///           - `StopCancelled`   from GuardianVault — a stop withdrawn early.
///           - `PriceUpdated`    from PriceOracle  — a new price to evaluate.
///         When a price lands at or below a stop's trigger, it requests a
///         callback (via the system contract) instructing the GuardianVault
///         to close that position — the full loop (origin event -> reaction
///         -> destination callback) completes in about a second on Reactive
///         Omni, with no keeper bot, no off-chain server, and nobody's keys
///         online.
///
///         State note (the canonical Reactive pattern): the executing
///         instance of a reactive contract builds its state from the events
///         it processes, so stops MUST arrive as origin-chain events. They
///         can never be registered by calling this contract directly.
///
///         Track: "Every Second Counts" (Reactive Omni Buildathon).
///         The same code also fits "Set It and Forget It": register a stop
///         once and the network watches the market for you, forever.
contract StopLossReactive is AbstractReactive {
    /// @notice Origin AND destination chain for this demo: Base Sepolia.
    uint256 public constant BASE_SEPOLIA_ID = 84532;

    /// @notice Gas forwarded to the destination callback.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice keccak256("PriceUpdated(address,uint256,uint256)")
    bytes32 public constant PRICE_UPDATED_TOPIC = keccak256("PriceUpdated(address,uint256,uint256)");

    /// @notice keccak256("StopRegistered(uint256,address,uint256)")
    bytes32 public constant STOP_REGISTERED_TOPIC = keccak256("StopRegistered(uint256,address,uint256)");

    /// @notice keccak256("StopCancelled(uint256)")
    bytes32 public constant STOP_CANCELLED_TOPIC = keccak256("StopCancelled(uint256)");

    /// @notice The PriceOracle on Base Sepolia whose price events we react to.
    address public immutable oracle;

    /// @notice Deployer EOA; the only account allowed to initialize the vault.
    address public immutable owner;

    /// @notice The GuardianVault on Base Sepolia: source of stop events and
    ///         the destination of our callbacks. Set once by `initialize()`
    ///         after the vault is deployed (the vault needs this contract's
    ///         address at construction, so deployment order is: this contract,
    ///         then the vault, then initialize()).
    address public vault;

    struct Stop {
        address token;
        uint256 triggerPrice;
        bool active;
    }

    /// @notice Stops keyed by GuardianVault position id.
    mapping(uint256 => Stop) public stops;

    /// @notice Position ids of every stop ever registered (iteration index).
    uint256[] public stopIds;

    event StopRecorded(uint256 indexed positionId, address indexed token, uint256 triggerPrice);
    event StopTriggered(uint256 indexed positionId, uint256 price, uint256 triggeredAt);

    /// @param _oracle PriceOracle address on Base Sepolia.
    constructor(address _oracle) payable {
        oracle = _oracle;
        owner = msg.sender;
    }

    /// @notice One-time wiring: records the GuardianVault address and creates
    ///         all three event subscriptions with the system contract.
    /// @dev Afterwards, top this contract up via the system contract's
    ///      `depositTo()` so it holds reserves and subscriptions stay active.
    function initialize(address _vault) external {
        require(msg.sender == owner, "owner only");
        require(vault == address(0), "already initialized");
        require(_vault != address(0), "vault=0");
        vault = _vault;
        SYSTEM.subscribe(
            BASE_SEPOLIA_ID, oracle, uint256(PRICE_UPDATED_TOPIC), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_ID, _vault, uint256(STOP_REGISTERED_TOPIC), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_ID, _vault, uint256(STOP_CANCELLED_TOPIC), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Settles any outstanding system-contract debt from this
    ///         contract's own balance (see Reactive economy docs).
    function coverDebt() external {
        _coverDebt();
    }

    /// @inheritdoc IReactive
    /// @dev Callable only by the system contract (onlySystem). Maintains the
    ///      stop registry purely from origin-chain events:
    ///        - StopRegistered: topic1 = positionId, topic2 = token,
    ///          data = abi.encode(triggerPrice).
    ///        - StopCancelled: topic1 = positionId.
    ///        - PriceUpdated: topic1 = token, data = abi.encode(price, ts).
    ///      Stops are one-shot: a triggered stop deactivates itself, so a
    ///      position can never be closed twice.
    function react(LogRecord calldata log) external onlySystem {
        require(log.chainId == BASE_SEPOLIA_ID, "wrong chain");

        if (log.topic0 == uint256(STOP_REGISTERED_TOPIC)) {
            require(log.contractAddress == vault, "wrong vault");
            uint256 positionId = log.topic1;
            address token = address(uint160(log.topic2));
            uint256 triggerPrice = abi.decode(log.data, (uint256));
            if (!stops[positionId].active && stops[positionId].triggerPrice == 0) {
                stopIds.push(positionId);
            }
            stops[positionId] = Stop({token: token, triggerPrice: triggerPrice, active: true});
            emit StopRecorded(positionId, token, triggerPrice);
            return;
        }

        if (log.topic0 == uint256(STOP_CANCELLED_TOPIC)) {
            require(log.contractAddress == vault, "wrong vault");
            stops[log.topic1].active = false;
            return;
        }

        require(log.topic0 == uint256(PRICE_UPDATED_TOPIC), "wrong topic");
        require(log.contractAddress == oracle, "wrong oracle");

        address token = address(uint160(log.topic1));
        (uint256 price,) = abi.decode(log.data, (uint256, uint256));

        for (uint256 i = 0; i < stopIds.length; i++) {
            uint256 positionId = stopIds[i];
            Stop storage s = stops[positionId];
            if (s.active && s.token == token && price <= s.triggerPrice) {
                s.active = false;
                emit StopTriggered(positionId, price, block.timestamp);
                // The first payload argument is the sender slot: Reactive
                // Network injects this contract's address into it, and the
                // vault authenticates the callback against that value.
                bytes memory payload = abi.encodeWithSignature("callback(address,uint256)", address(0), positionId);
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: BASE_SEPOLIA_ID, recipient: vault, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
                    })
                );
            }
        }
    }

    function stopsCount() external view returns (uint256) {
        return stopIds.length;
    }

    function getStop(uint256 positionId) external view returns (address token, uint256 triggerPrice, bool active) {
        Stop storage s = stops[positionId];
        return (s.token, s.triggerPrice, s.active);
    }
}
