// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {
    IBridgehub,
    L2TransactionRequestTwoBridgesOuter
} from "@era-contracts/l1-contracts/contracts/bridgehub/IBridgehub.sol";
import {IL1SharedBridge} from "@era-contracts/l1-contracts/contracts/bridge/interfaces/IL1SharedBridge.sol";

interface FiatToken {
    function approve(address spender, uint256 amount) external;
}

/// @notice Bridges USDC to a hyperchain whose base token is not ETH (e.g. CBT chains).
/// @dev Requires base token approvals prior to calling the bridgehub.
///      Environment variables:
///        - DEPLOYER_PRIVATE_KEY (or DEPLOYER_ADDRESS when using --account)
///        - USDC_BRIDGE_AMOUNT (optional, default 1e6)
///        - CBT_BASE_TOKEN_ADDRESS
///        - CBT_BRIDGE_MINT_VALUE (optional, default 10 ether)
///        - CBT_BRIDGE_L2_GAS_LIMIT (optional, default 450_000)
///        - CBT_BRIDGE_L2_GAS_PER_PUBDATA (optional, default 800)
///        - CBT_BRIDGE_RECIPIENT (optional, default msg.sender)
contract BridgeUsdcToCbtBaseChain is Script {
    struct Config {
        uint256 chainId;
        uint256 usdcAmount;
        uint256 mintValue;
        uint256 l2GasLimit;
        uint256 l2GasPerPubdata;
        address baseToken;
        address bridgehub;
        address sharedBridge;
        address l1UsdcBridge;
        address usdc;
        address recipient;
        uint256 deployerKey;
        address broadcaster;
    }

    function run() external {
        Config memory cfg = _loadConfig();
        console.log("USDC amount:", cfg.usdcAmount);
        console.log("Sender:", cfg.broadcaster);
        console.log("Base token:", cfg.baseToken);
        console.log("Target hyperchain:", cfg.chainId);

        if (cfg.deployerKey != 0) {
            vm.startBroadcast(cfg.deployerKey);
        } else {
            vm.startBroadcast();
        }

        _ensureAllowance(cfg.baseToken, cfg.mintValue, cfg.sharedBridge, cfg.broadcaster, false);
        _ensureAllowance(cfg.usdc, cfg.usdcAmount, cfg.l1UsdcBridge, cfg.broadcaster, true);

        address recipient = cfg.recipient == address(0) ? cfg.broadcaster : cfg.recipient;
        _bridge(cfg, recipient);

        vm.stopBroadcast();
    }

    function _bridge(Config memory cfg, address recipient) private {
        bytes memory depositData = abi.encode(cfg.usdc, cfg.usdcAmount, recipient);

        IBridgehub(cfg.bridgehub)
            .requestL2TransactionTwoBridges(
                L2TransactionRequestTwoBridgesOuter({
                    chainId: cfg.chainId,
                    mintValue: cfg.mintValue,
                    l2Value: 0,
                    l2GasLimit: cfg.l2GasLimit,
                    l2GasPerPubdataByteLimit: cfg.l2GasPerPubdata,
                    refundRecipient: recipient,
                    secondBridgeAddress: cfg.l1UsdcBridge,
                    secondBridgeValue: 0,
                    secondBridgeCalldata: depositData
                })
            );

        console.log("Bridge request submitted");
    }

    function _ensureAllowance(address tokenAddr, uint256 required, address spender, address owner, bool treatAsUsdc)
        private
    {
        IERC20 token = IERC20(tokenAddr);
        uint256 allowance = token.allowance(owner, spender);
        if (allowance < required) {
            console.log("Updating allowance for token:", tokenAddr);
            console.log("Token symbol:", token.symbol());
            if (treatAsUsdc) {
                if (allowance != 0) {
                    FiatToken(tokenAddr).approve(spender, 0);
                }
                FiatToken(tokenAddr).approve(spender, required);
            } else {
                token.approve(spender, type(uint256).max);
            }
            console.log("New allowance:", token.allowance(owner, spender));
        } else {
            console.log("Allowance already sufficient for token:", token.symbol());
        }
    }

    function _loadConfig() private returns (Config memory cfg) {
        cfg.deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        cfg.chainId = vm.envUint("L2_CHAIN_ID");
        cfg.usdcAmount = vm.envOr("USDC_BRIDGE_AMOUNT", uint256(1_000_000));
        cfg.mintValue = vm.envOr("CBT_BRIDGE_MINT_VALUE", uint256(10 ether));
        cfg.l2GasLimit = vm.envOr("CBT_BRIDGE_L2_GAS_LIMIT", uint256(450_000));
        cfg.l2GasPerPubdata = vm.envOr("CBT_BRIDGE_L2_GAS_PER_PUBDATA", uint256(800));

        cfg.bridgehub = vm.envAddress("BRIDGEHUB_ADDRESS");
        require(cfg.bridgehub != address(0), "Bridgehub address missing");
        cfg.sharedBridge = address(IBridgehub(cfg.bridgehub).sharedBridge());
        require(cfg.sharedBridge != address(0), "Shared bridge address missing");

        cfg.usdc = vm.envAddress("L1_USDC_ADDRESS");
        require(cfg.usdc != address(0), "USDC address missing");

        cfg.l1UsdcBridge = vm.envAddress("L1_USDC_BRIDGE_PROXY");
        require(cfg.l1UsdcBridge != address(0), "L1USDCBridge address missing");

        cfg.baseToken = vm.envAddress("CBT_BASE_TOKEN_ADDRESS");
        require(cfg.baseToken != address(0), "Base token address missing");

        cfg.recipient = vm.envOr("CBT_BRIDGE_RECIPIENT", address(0));

        cfg.broadcaster = cfg.deployerKey != 0
            ? vm.addr(cfg.deployerKey)
            : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(cfg.broadcaster != address(0), "Set DEPLOYER_PRIVATE_KEY or DEPLOYER_ADDRESS");
    }
}
