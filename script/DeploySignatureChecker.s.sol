// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.23;

import {Script, console} from "forge-std/Script.sol";

/// @notice Deploys the Circle SignatureChecker library to the current chain.
/// @dev This is a thin wrapper around `vm.deployCode` so that we can broadcast
///      deployments without having to manually run `forge create`.
contract DeploySignatureChecker is Script {
    string internal constant SIGNATURE_CHECKER_ARTIFACT = "out/SignatureChecker.sol/SignatureChecker.json";

    function run() external returns (address deployed) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        deployed = vm.deployCode(SIGNATURE_CHECKER_ARTIFACT);
        vm.stopBroadcast();

        console.log("SignatureChecker deployed at", deployed);
    }
}
