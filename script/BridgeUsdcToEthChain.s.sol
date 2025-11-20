// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {
    IBridgehub,
    L2TransactionRequestTwoBridgesOuter
} from "@era-contracts/l1-contracts/contracts/bridgehub/IBridgehub.sol";

interface FiatToken {
    function approve(address spender, uint256 amount) external;
}

/// @notice Bridges USDC to an ETH-based zkSync hyperchain using the shared bridge.
/// @dev The script requires the following env vars:
///        - DEPLOYER_PRIVATE_KEY (or DEPLOYER_ADDRESS when using --account): signer that holds USDC and pays the ETH cost
///        - USDC_BRIDGE_AMOUNT (optional, default 1e6 = 1 USDC)
///        - L2_CHAIN_ID: hyperchain id to target
///        - ETH_BRIDGE_L2_GAS_LIMIT (optional, default 450_000)
///        - ETH_BRIDGE_L2_GAS_PER_PUBDATA (optional, default 800)
///        - ETH_BRIDGE_L2_GAS_PRICE (optional, default 1 gwei) in wei
///        - ETH_BRIDGE_MINT_VALUE (optional, default is l2TransactionBaseCost result)
///        - ETH_BRIDGE_SECOND_BRIDGE_VALUE (optional, default 0)
///        - ETH_BRIDGE_RECIPIENT (optional, default msg.sender)
contract BridgeUsdcToEthChain is Script {
    struct Config {
        uint256 chainId;
        uint256 usdcAmount;
        uint256 l2GasLimit;
        uint256 l2GasPerPubdata;
        uint256 gasPrice;
        uint256 mintValue;
        uint256 secondBridgeValue;
        address bridgehub;
        address l1UsdcBridge;
        address usdc;
        address recipient;
        address broadcaster;
        uint256 deployerKey;
    }

    function run() external {
        Config memory cfg = _loadConfig();
        console.log("USDC amount:", cfg.usdcAmount);
        console.log("Sender:", cfg.broadcaster);
        console.log("Target hyperchain:", cfg.chainId);

        if (cfg.deployerKey != 0) {
            vm.startBroadcast(cfg.deployerKey);
        } else {
            vm.startBroadcast();
        }

        _ensureUsdcAllowance(cfg, cfg.broadcaster);

        address recipient = cfg.recipient == address(0) ? cfg.broadcaster : cfg.recipient;
        _bridge(cfg, recipient);

        vm.stopBroadcast();
    }

    function _bridge(Config memory cfg, address recipient) private {
        bytes memory depositData = abi.encode(cfg.usdc, cfg.usdcAmount, recipient);
        uint256 totalValue = cfg.mintValue + cfg.secondBridgeValue;

        console.log("Sending value (wei):", totalValue);

        IBridgehub(cfg.bridgehub).requestL2TransactionTwoBridges{value: totalValue}(
            L2TransactionRequestTwoBridgesOuter({
                chainId: cfg.chainId,
                mintValue: cfg.mintValue,
                l2Value: 0,
                l2GasLimit: cfg.l2GasLimit,
                l2GasPerPubdataByteLimit: cfg.l2GasPerPubdata,
                refundRecipient: recipient,
                secondBridgeAddress: cfg.l1UsdcBridge,
                secondBridgeValue: cfg.secondBridgeValue,
                secondBridgeCalldata: depositData
            })
        );

        console.log("Bridge request submitted");
    }

    function _ensureUsdcAllowance(Config memory cfg, address owner) private {
        IERC20 usdcToken = IERC20(cfg.usdc);
        uint256 allowance = usdcToken.allowance(owner, cfg.l1UsdcBridge);
        if (allowance < cfg.usdcAmount) {
            console.log("Updating USDC allowance for L1 bridge");
            if (allowance != 0) {
                FiatToken(cfg.usdc).approve(cfg.l1UsdcBridge, 0);
            }
            FiatToken(cfg.usdc).approve(cfg.l1UsdcBridge, cfg.usdcAmount);
            console.log("New allowance:", usdcToken.allowance(owner, cfg.l1UsdcBridge));
        } else {
            console.log("Existing USDC allowance is sufficient");
        }
    }

    function _loadConfig() private returns (Config memory cfg) {
        cfg.deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        cfg.chainId = vm.envUint("L2_CHAIN_ID");
        cfg.usdcAmount = vm.envOr("USDC_BRIDGE_AMOUNT", uint256(1_000_000)); // 1 USDC
        cfg.l2GasLimit = vm.envOr("ETH_BRIDGE_L2_GAS_LIMIT", uint256(450_000));
        cfg.l2GasPerPubdata = vm.envOr("ETH_BRIDGE_L2_GAS_PER_PUBDATA", uint256(800));
        cfg.gasPrice = vm.envOr("ETH_BRIDGE_L2_GAS_PRICE", uint256(1 gwei));

        cfg.bridgehub = vm.envAddress("BRIDGEHUB_ADDRESS");
        require(cfg.bridgehub != address(0), "Bridgehub address missing");

        cfg.l1UsdcBridge = vm.envAddress("L1_USDC_BRIDGE_PROXY");
        require(cfg.l1UsdcBridge != address(0), "L1USDCBridge address missing");

        cfg.usdc = vm.envAddress("L1_USDC_ADDRESS");
        require(cfg.usdc != address(0), "USDC address missing");

        cfg.broadcaster = cfg.deployerKey != 0
            ? vm.addr(cfg.deployerKey)
            : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(cfg.broadcaster != address(0), "Set DEPLOYER_PRIVATE_KEY or DEPLOYER_ADDRESS");

        uint256 baseCost = IBridgehub(cfg.bridgehub)
            .l2TransactionBaseCost(cfg.chainId, cfg.gasPrice, cfg.l2GasLimit, cfg.l2GasPerPubdata);
        console.log("Estimated base cost (wei):", baseCost);

        cfg.mintValue = vm.envOr("ETH_BRIDGE_MINT_VALUE", baseCost);
        require(cfg.mintValue >= baseCost, "mintValue below base cost");

        cfg.secondBridgeValue = vm.envOr("ETH_BRIDGE_SECOND_BRIDGE_VALUE", uint256(0));
        cfg.recipient = vm.envOr("ETH_BRIDGE_RECIPIENT", address(0));
    }
}
