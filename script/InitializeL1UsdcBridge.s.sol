// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IL1USDCBridgeGovernance {
    function initializeChainGovernance(uint256 chainId, address l2Bridge) external;
}

/// @notice Registers the freshly deployed L2 USDC bridge on the L1 shared bridge.
/// @dev Run this script against the L1 RPC endpoint once the L2 stack has been deployed.
contract InitializeL1UsdcBridge is Script {
    function run() external {
        uint256 proxyAdminKey = vm.envOr("L1_USDC_BRIDGE_OWNER_PRIVATE_KEY", uint256(0));
        address l1Bridge = vm.envAddress("L1_USDC_BRIDGE_PROXY");
        uint256 l2ChainId = vm.envUint("L2_CHAIN_ID");
        address l2BridgeProxy = vm.envAddress("L2_USDC_BRIDGE_PROXY");

        if (proxyAdminKey != 0) {
            vm.startBroadcast(proxyAdminKey);
        } else {
            vm.startBroadcast();
        }
        IL1USDCBridgeGovernance(l1Bridge).initializeChainGovernance(l2ChainId, l2BridgeProxy);
        vm.stopBroadcast();

        console.log("Registered L2 bridge");
        console.log("  L2 bridge proxy:", l2BridgeProxy);
        console.log("  L1 chain id (target):", l2ChainId);
        console.log("  L1 bridge proxy:", l1Bridge);
    }
}
