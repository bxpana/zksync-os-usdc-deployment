// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/// @notice Deploys an OpenZeppelin `ProxyAdmin` and optionally hands ownership to a target address.
contract DeployProxyAdmin is Script {
    function run() external returns (address deployed) {
        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address desiredOwner = vm.envOr("PROXY_ADMIN_OWNER", address(0));
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            // Use signer provided via --account / keystore
            vm.startBroadcast();
        }
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        deployed = address(proxyAdmin);

        if (desiredOwner != address(0) && desiredOwner != proxyAdmin.owner()) {
            proxyAdmin.transferOwnership(desiredOwner);
        }
        address finalOwner = proxyAdmin.owner();
        vm.stopBroadcast();

        console.log("ProxyAdmin deployed at", deployed);
        console.log("ProxyAdmin owner set to", finalOwner);
    }
}
