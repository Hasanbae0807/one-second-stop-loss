// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GuardianVault} from "../src/GuardianVault.sol";
import {StopLossReactive} from "../src/StopLossReactive.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {MockSystemContract} from "./MockSystemContract.sol";

/// @notice Local end-to-end tests for the One-Second Stop-Loss loop:
///         deposit + StopRegistered event -> react() records the stop ->
///         PriceUpdated event -> react() requests a callback ->
///         Callback Proxy delivers callback() -> position closed.
///         The Reactive Omni system contract is replaced by a mock etched at
///         its real address (0x8888...8888), and react() is invoked with the
///         system contract pranked as caller, exactly as the network does.
///
///         NOTE on test mechanics: log records are always built into a local
///         variable BEFORE vm.prank(SYSTEM), because building them calls
///         getter functions on the reactive contract, which would otherwise
///         consume the prank.
contract GuardianStopLossTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant PROXY = 0x000000000000000000000000000000000000cA11;

    MockERC20 internal token;
    PriceOracle internal oracle;
    GuardianVault internal vault;
    StopLossReactive internal reactive;
    MockSystemContract internal systemMock;

    uint256 internal priceTopic;
    uint256 internal registeredTopic;
    uint256 internal cancelledTopic;

    address internal alice = address(0xA11CE);
    uint256 internal constant STOP = 90 ether; // trigger: $90 (18-dec oracle units)
    uint256 internal constant AMOUNT = 100 ether;

    function setUp() public {
        // Etch the mock system contract at the real system address.
        MockSystemContract impl = new MockSystemContract();
        vm.etch(SYSTEM, address(impl).code);
        systemMock = MockSystemContract(payable(SYSTEM));

        token = new MockERC20("Mock Token", "MOCK");
        oracle = new PriceOracle();
        // Deployment order mirrors production: reactive first (it only needs
        // the oracle), then the vault (it needs the reactive address), then
        // initialize() wires the vault into the reactive contract.
        reactive = new StopLossReactive{value: 0.1 ether}(address(oracle));
        vault = new GuardianVault(PROXY, address(reactive));
        reactive.initialize(address(vault));

        priceTopic = uint256(reactive.PRICE_UPDATED_TOPIC());
        registeredTopic = uint256(reactive.STOP_REGISTERED_TOPIC());
        cancelledTopic = uint256(reactive.STOP_CANCELLED_TOPIC());

        token.mint(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
    }

    // ---------- helpers ----------

    function _log(address source, uint256 topic0, uint256 topic1, uint256 topic2, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: 84532,
            contractAddress: source,
            topic0: topic0,
            topic1: topic1,
            topic2: topic2,
            topic3: 0,
            data: data,
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _stopRegisteredLog(uint256 positionId, uint256 triggerPrice) internal view returns (IReactive.LogRecord memory) {
        return _log(address(vault), registeredTopic, positionId, uint256(uint160(address(token))), abi.encode(triggerPrice));
    }

    function _stopCancelledLog(uint256 positionId) internal view returns (IReactive.LogRecord memory) {
        return _log(address(vault), cancelledTopic, positionId, 0, bytes(""));
    }

    function _priceLog(uint256 price) internal view returns (IReactive.LogRecord memory) {
        return _log(address(oracle), priceTopic, uint256(uint160(address(token))), 0, abi.encode(price, uint256(1_700_000_000)));
    }

    /// @dev The log argument is fully evaluated (including any getter calls)
    ///      before this function pranks the system contract and calls react().
    function _react(IReactive.LogRecord memory log) internal {
        vm.prank(SYSTEM);
        reactive.react(log);
    }

    function _depositWithStop() internal returns (uint256 positionId) {
        vm.prank(alice);
        positionId = vault.deposit(address(token), AMOUNT, STOP);
        _react(_stopRegisteredLog(positionId, STOP));
    }

    function _deliverCallback(uint256 positionId) internal {
        // What the Callback Proxy does on the destination chain.
        vm.prank(PROXY);
        vault.callback(address(reactive), positionId);
    }

    function _stripSelector(bytes memory payload) internal pure returns (bytes memory args) {
        args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
    }

    // ---------- wiring ----------

    function testInitializeSubscribesToAllThreeEvents() public view {
        assertEq(systemMock.subscribeCalls(), 3);
        assertEq(reactive.vault(), address(vault));
        assertEq(reactive.oracle(), address(oracle));
    }

    function testInitializeTwiceReverts() public {
        vm.expectRevert(bytes("already initialized"));
        reactive.initialize(address(vault));
    }

    function testInitializeByStrangerReverts() public {
        StopLossReactive fresh = new StopLossReactive(address(oracle));
        vm.prank(alice);
        vm.expectRevert(bytes("owner only"));
        fresh.initialize(address(vault));
    }

    function testReactByNonSystemReverts() public {
        IReactive.LogRecord memory log = _priceLog(1 ether);
        vm.expectRevert();
        reactive.react(log);
    }

    // ---------- core loop ----------

    function testStopLossFullLoop() public {
        uint256 positionId = _depositWithStop();
        assertEq(token.balanceOf(address(vault)), AMOUNT);

        (address stopToken, uint256 trigger, bool active) = reactive.getStop(positionId);
        assertEq(stopToken, address(token));
        assertEq(trigger, STOP);
        assertTrue(active);

        // Price still above the stop: no callback requested.
        _react(_priceLog(95 ether));
        assertEq(systemMock.callbackRequests(), 0);

        // Price falls through the stop: exactly one callback requested,
        // addressed to the vault, carrying the position id.
        _react(_priceLog(89 ether));
        assertEq(systemMock.callbackRequests(), 1);
        assertEq(systemMock.lastRecipient(), address(vault));
        assertEq(systemMock.lastChainId(), 84532);
        (address senderSlot, uint256 payloadPositionId) =
            abi.decode(_stripSelector(systemMock.lastPayload()), (address, uint256));
        assertEq(senderSlot, address(0)); // network injects the reactive address here
        assertEq(payloadPositionId, positionId);

        // Stop deactivated itself: a second crash event requests nothing.
        (, , bool activeAfter) = reactive.getStop(positionId);
        assertFalse(activeAfter);
        _react(_priceLog(50 ether));
        assertEq(systemMock.callbackRequests(), 1);

        // The proxy delivers the callback: position closed, funds returned.
        _deliverCallback(positionId);
        (address owner_, , uint256 amount_, bool open_) = vault.getPosition(positionId);
        assertEq(owner_, alice);
        assertEq(amount_, AMOUNT);
        assertFalse(open_);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testPriceEqualToStopTriggers() public {
        uint256 positionId = _depositWithStop();
        _react(_priceLog(STOP));
        assertEq(systemMock.callbackRequests(), 1);
        _deliverCallback(positionId);
        (, , , bool open_) = vault.getPosition(positionId);
        assertFalse(open_);
    }

    function testCancelledStopNeverTriggers() public {
        uint256 positionId = _depositWithStop();

        // Alice withdraws manually -> vault emits StopCancelled -> the
        // reactive contract deactivates the stop.
        vm.prank(alice);
        vault.withdraw(positionId);
        _react(_stopCancelledLog(positionId));

        _react(_priceLog(10 ether));
        assertEq(systemMock.callbackRequests(), 0);
    }

    function testMultipleStopsOnlyBreachedOneFires() public {
        uint256 p0 = _depositWithStop(); // stop $90

        vm.prank(alice);
        uint256 p1 = vault.deposit(address(token), AMOUNT, 50 ether); // stop $50
        _react(_stopRegisteredLog(p1, 50 ether));
        assertEq(reactive.stopsCount(), 2);

        // Price $70: breaches $90 stop only.
        _react(_priceLog(70 ether));
        assertEq(systemMock.callbackRequests(), 1);
        (, uint256 firedId) = abi.decode(_stripSelector(systemMock.lastPayload()), (address, uint256));
        assertEq(firedId, p0);

        _deliverCallback(p0);
        (, , , bool open0) = vault.getPosition(p0);
        (, , , bool open1) = vault.getPosition(p1);
        assertFalse(open0);
        assertTrue(open1);
    }

    function testDepositWithoutStopRegistersNothing() public {
        vm.prank(alice);
        uint256 positionId = vault.deposit(address(token), AMOUNT, 0);
        assertEq(reactive.stopsCount(), 0);
        (, , , bool open_) = vault.getPosition(positionId);
        assertTrue(open_);
    }

    // ---------- callback authentication ----------

    function testCallbackFromNonProxyReverts() public {
        uint256 positionId = _depositWithStop();
        vm.prank(alice);
        vm.expectRevert(bytes("proxy only"));
        vault.callback(address(reactive), positionId);
    }

    function testCallbackWithWrongSenderReverts() public {
        uint256 positionId = _depositWithStop();
        vm.prank(PROXY);
        vm.expectRevert();
        vault.callback(address(0xBAD), positionId);
    }

    function testDoubleCloseReverts() public {
        uint256 positionId = _depositWithStop();
        _deliverCallback(positionId);
        vm.prank(PROXY);
        vm.expectRevert(bytes("position closed"));
        vault.callback(address(reactive), positionId);
    }

    function testWithdrawByOwnerReturnsFunds() public {
        uint256 positionId = _depositWithStop();
        vm.prank(alice);
        vault.withdraw(positionId);
        assertEq(token.balanceOf(alice), 1_000 ether);
        (, , , bool open_) = vault.getPosition(positionId);
        assertFalse(open_);
    }

    function testWithdrawByStrangerReverts() public {
        uint256 positionId = _depositWithStop();
        vm.expectRevert(bytes("not owner"));
        vault.withdraw(positionId);
    }
}
