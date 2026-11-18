// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {StopLossReactive} from "../src/StopLossReactive.sol";

/// @notice Step 2 — deploy StopLossReactive on Reactive Lasna (chain 5318007),
///         seeded with 0.1 lREACT from the deployer:
///           ORACLE_ADDR=0x... forge script script/DeployLasna.s.sol \
///             --broadcast --rpc-url https://lasna-rpc.rnk.dev/ \
///             --private-key $DEPLOYER_KEY
///         Afterwards (step 4): fund it via the system contract's depositTo()
///         and call initialize(<GuardianVault address>) once the vault exists
///         (step 3 in DeployBaseSepolia.s.sol).
contract DeployLasna is Script {
    function run() external {
        address oracle = vm.envAddress("ORACLE_ADDR");
        vm.startBroadcast();
        StopLossReactive reactive = new StopLossReactive{value: 0.1 ether}(oracle);
        console.log("stop_loss_reactive:", address(reactive));
        vm.stopBroadcast();
    }
}
