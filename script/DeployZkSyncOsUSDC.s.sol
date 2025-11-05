// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DeploymentUtils} from "lib/usdc-bridge/utils/DeploymentUtils.sol";
import {L2USDCBridge} from "lib/usdc-bridge/src/L2USDCBridge.sol";

/// @dev Minimal interface for the FiatToken proxy administration contract (AdminUpgradeabilityProxy).
interface IFiatTokenProxyAdmin {
    function changeAdmin(address newAdmin) external;
    function admin() external view returns (address);
}

/// @dev Minimal interface for interacting with FiatToken through the proxy.
interface IFiatTokenV2_2 {
    function initialize(
        string calldata tokenName,
        string calldata tokenSymbol,
        string calldata tokenCurrency,
        uint8 tokenDecimals,
        address newMasterMinter,
        address newPauser,
        address newBlacklister,
        address newOwner
    ) external;

    function initializeV2(string calldata newName) external;
    function initializeV2_1(address lostAndFound) external;
    function initializeV2_2(address[] calldata accountsToBlacklist, string calldata newSymbol) external;

    function masterMinter() external view returns (address);
    function pauser() external view returns (address);
    function blacklister() external view returns (address);
    function rescuer() external view returns (address);
    function owner() external view returns (address);

    function updatePauser(address newPauser) external;
    function updateBlacklister(address newBlacklister) external;
    function updateRescuer(address newRescuer) external;
    function transferOwnership(address newOwner) external;
}

/// @dev Minimal interface for MasterMinter interactions.
interface IMasterMinter {
    function owner() external view returns (address);
    function configureController(address controller, address worker) external;
    function configureMinter(uint256 newAllowance) external returns (bool);
    function removeController(address controller) external;
    function transferOwnership(address newOwner) external;
}

/// @notice Deploys the L2 USDC stack (FiatToken proxy + implementation, MasterMinter, L2 bridge)
///         and performs the post-deployment wiring described in `zksync_os_usdc.md`.
contract DeployZkSyncOsUSDC is Script, DeploymentUtils {
    using stdJson for string;
    string internal constant FIAT_TOKEN_IMPL_ARTIFACT = "out/FiatTokenV2_2.sol/FiatTokenV2_2.json";
    string internal constant FIAT_TOKEN_PROXY_ARTIFACT = "out/FiatTokenProxy.sol/FiatTokenProxy.json";
    string internal constant MASTER_MINTER_ARTIFACT = "out/MasterMinter.sol/MasterMinter.json";
    string internal constant L2_BRIDGE_IMPL_ARTIFACT = "out/L2USDCBridge.sol/L2USDCBridge.json";

    struct Config {
        address signatureChecker;
        address existingFiatTokenImpl;
        address existingFiatTokenProxy;
        address existingMasterMinter;
        address existingL2BridgeImpl;
        address existingL2BridgeProxy;
        address l1UsdcToken;
        address l1UsdcBridgeProxy;
        address proxyAdmin;
        address governance;
        address pauser;
        address blacklister;
        address rescuer;
        address lostAndFound;
        string tokenName;
        string tokenNameV2;
        string tokenSymbol;
        string tokenSymbolV2;
        string tokenCurrency;
        uint8 tokenDecimals;
        uint256 masterMinterAllowance;
        address[] initialBlacklist;
    }

    struct DeploymentArtifacts {
        address signatureChecker;
        address fiatTokenImpl;
        address fiatTokenProxy;
        address masterMinter;
        address l2BridgeImpl;
        address l2BridgeProxy;
    }

    function run() external returns (DeploymentArtifacts memory deployed) {
        uint256 deployerKey = _loadDeployerKey();
        Config memory cfg = _loadConfig();

        vm.label(cfg.proxyAdmin, "ProxyAdmin");
        vm.label(cfg.governance, "Governance");
        if (cfg.pauser != address(0)) vm.label(cfg.pauser, "Pauser");
        if (cfg.blacklister != address(0)) vm.label(cfg.blacklister, "Blacklister");
        if (cfg.rescuer != address(0)) vm.label(cfg.rescuer, "Rescuer");

        require(cfg.signatureChecker != address(0), "SIGNATURE_CHECKER_ADDRESS not set");
        require(cfg.l1UsdcToken != address(0), "L1_USDC_ADDRESS not set");
        require(cfg.l1UsdcBridgeProxy != address(0), "L1_USDC_BRIDGE_PROXY not set");
        require(cfg.proxyAdmin != address(0), "PROXY_ADMIN_ADDRESS not set");
        require(cfg.governance != address(0), "GOVERNANCE_ADDRESS not set");
        require(bytes(cfg.tokenName).length != 0, "TOKEN_NAME not set");
        require(bytes(cfg.tokenSymbol).length != 0, "TOKEN_SYMBOL not set");
        require(bytes(cfg.tokenCurrency).length != 0, "TOKEN_CURRENCY not set");

        deployed.signatureChecker = cfg.signatureChecker;

        vm.startBroadcast(deployerKey);

        deployed.fiatTokenImpl = cfg.existingFiatTokenImpl != address(0)
            ? cfg.existingFiatTokenImpl
            : _deployFiatTokenImplementation(cfg.signatureChecker);

        deployed.fiatTokenProxy = cfg.existingFiatTokenProxy != address(0)
            ? cfg.existingFiatTokenProxy
            : deployCode(FIAT_TOKEN_PROXY_ARTIFACT, abi.encode(deployed.fiatTokenImpl));

        if (cfg.existingFiatTokenProxy == address(0)) {
            _ensureFiatTokenProxyAdmin(deployed.fiatTokenProxy, cfg.proxyAdmin);
        }

        deployed.masterMinter = cfg.existingMasterMinter != address(0)
            ? cfg.existingMasterMinter
            : deployCode(MASTER_MINTER_ARTIFACT, abi.encode(deployed.fiatTokenProxy));

        deployed.l2BridgeImpl = cfg.existingL2BridgeImpl != address(0)
            ? cfg.existingL2BridgeImpl
            : deployCode(L2_BRIDGE_IMPL_ARTIFACT, abi.encode(cfg.l1UsdcToken, deployed.fiatTokenProxy));

        if (cfg.existingL2BridgeProxy != address(0)) {
            deployed.l2BridgeProxy = cfg.existingL2BridgeProxy;
        } else {
            bytes memory initData = abi.encodeWithSelector(L2USDCBridge.initialize.selector, cfg.l1UsdcBridgeProxy);
            deployed.l2BridgeProxy =
                address(new TransparentUpgradeableProxy(deployed.l2BridgeImpl, cfg.proxyAdmin, initData));
        }

        _initialiseFiatToken(deployed, cfg);
        _wireMasterMinter(deployed, cfg);
        _assignTokenRoles(deployed, cfg);
        _finaliseAdmins(deployed, cfg);

        saveDeployedContract("USDC", deployed.fiatTokenProxy);
        saveDeployedContract("L2USDCBridge", deployed.l2BridgeProxy);
        saveDeployedContract("L2USDCBridge-impl", deployed.l2BridgeImpl);

        vm.stopBroadcast();

        _logSummary(deployed, cfg);
    }

    function _loadDeployerKey() private returns (uint256 deployerKey) {
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddr = vm.addr(deployerKey);

        vm.label(deployerAddr, "Deployer");

        address expectedDeployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        if (expectedDeployer != address(0) && expectedDeployer != deployerAddr) {
            revert("DEPLOYER_ADDRESS does not match provided key");
        }
    }

    function _loadConfig() private returns (Config memory cfg) {
        cfg.signatureChecker = vm.envOr("SIGNATURE_CHECKER_ADDRESS", address(0));
        cfg.existingFiatTokenImpl = vm.envOr("EXISTING_FIAT_TOKEN_IMPL", address(0));
        cfg.existingFiatTokenProxy = vm.envOr("EXISTING_FIAT_TOKEN_PROXY", address(0));
        cfg.existingMasterMinter = vm.envOr("EXISTING_MASTER_MINTER", address(0));
        cfg.existingL2BridgeImpl = vm.envOr("EXISTING_L2_BRIDGE_IMPL", address(0));
        cfg.existingL2BridgeProxy = vm.envOr("EXISTING_L2_BRIDGE_PROXY", address(0));
        cfg.l1UsdcToken = vm.envOr("L1_USDC_ADDRESS", address(0));
        cfg.l1UsdcBridgeProxy = vm.envOr("L1_USDC_BRIDGE_PROXY", address(0));
        cfg.proxyAdmin = vm.envAddress("PROXY_ADMIN_ADDRESS");
        address expectedProxyAdmin = vm.envOr("PROXY_ADMIN_ADDRESS_CHECK", address(0));
        if (expectedProxyAdmin != address(0) && expectedProxyAdmin != cfg.proxyAdmin) {
            revert("PROXY_ADMIN_ADDRESS does not match provided check value");
        }
        cfg.governance = vm.envAddress("GOVERNANCE_ADDRESS");
        cfg.pauser = vm.envOr("PAUSER_ADDRESS", address(0));
        cfg.blacklister = vm.envOr("BLACKLISTER_ADDRESS", address(0));
        cfg.rescuer = vm.envOr("RESCUER_ADDRESS", address(0));
        cfg.lostAndFound = vm.envOr("LOST_AND_FOUND_ADDRESS", cfg.governance);
        cfg.tokenName = vm.envOr("TOKEN_NAME", string("USD Coin"));
        cfg.tokenNameV2 = vm.envOr("TOKEN_NAME_V2", cfg.tokenName);
        cfg.tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("USDC"));
        cfg.tokenSymbolV2 = vm.envOr("TOKEN_SYMBOL_V2", cfg.tokenSymbol);
        cfg.tokenCurrency = vm.envOr("TOKEN_CURRENCY", string("USD"));
        cfg.tokenDecimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(6)));
        cfg.masterMinterAllowance = vm.envOr("MASTER_MINTER_ALLOWANCE", type(uint256).max);
        cfg.initialBlacklist = vm.envOr("INITIAL_BLACKLIST", ",", new address[](0));
    }

    function _initialiseFiatToken(DeploymentArtifacts memory deployed, Config memory cfg) private {
        IFiatTokenV2_2 fiatToken = IFiatTokenV2_2(deployed.fiatTokenProxy);

        if (fiatToken.masterMinter() == address(0)) {
            fiatToken.initialize(
                cfg.tokenName,
                cfg.tokenSymbol,
                cfg.tokenCurrency,
                cfg.tokenDecimals,
                deployed.masterMinter,
                cfg.pauser,
                cfg.blacklister,
                vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"))
            );
        }

        _tryCallInitializeV2(fiatToken, cfg.tokenNameV2);
        _tryCallInitializeV2_1(fiatToken, cfg.lostAndFound);
        _tryCallInitializeV2_2(fiatToken, cfg.initialBlacklist, cfg.tokenSymbolV2);
    }

    function _tryCallInitializeV2(IFiatTokenV2_2 fiatToken, string memory newName) private {
        if (bytes(newName).length == 0) return;
        (bool success,) = address(fiatToken).call(abi.encodeWithSelector(fiatToken.initializeV2.selector, newName));
        if (!success) {
            console.log("initializeV2 already executed or reverted");
        }
    }

    function _tryCallInitializeV2_1(IFiatTokenV2_2 fiatToken, address lostAndFound) private {
        if (lostAndFound == address(0)) return;
        (bool success,) =
            address(fiatToken).call(abi.encodeWithSelector(fiatToken.initializeV2_1.selector, lostAndFound));
        if (!success) {
            console.log("initializeV2_1 already executed or reverted");
        }
    }

    function _tryCallInitializeV2_2(
        IFiatTokenV2_2 fiatToken,
        address[] memory accountsToBlacklist,
        string memory newSymbol
    ) private {
        (bool success,) = address(fiatToken)
            .call(abi.encodeWithSelector(fiatToken.initializeV2_2.selector, accountsToBlacklist, newSymbol));
        if (!success) {
            console.log("initializeV2_2 already executed or reverted");
        }
    }

    function _wireMasterMinter(DeploymentArtifacts memory deployed, Config memory cfg) private {
        IMasterMinter masterMinter = IMasterMinter(deployed.masterMinter);
        address deployerAddr = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        if (masterMinter.owner() == cfg.governance) {
            console.log("MasterMinter already owned by governance, skipping wiring");
            return;
        }

        masterMinter.configureController(deployerAddr, deployed.l2BridgeProxy);
        masterMinter.configureMinter(cfg.masterMinterAllowance);
        masterMinter.removeController(deployerAddr);
        masterMinter.transferOwnership(cfg.governance);
    }

    function _assignTokenRoles(DeploymentArtifacts memory deployed, Config memory cfg) private {
        IFiatTokenV2_2 fiatToken = IFiatTokenV2_2(deployed.fiatTokenProxy);

        if (fiatToken.owner() != cfg.governance) {
            fiatToken.transferOwnership(cfg.governance);
        }
    }

    function _finaliseAdmins(DeploymentArtifacts memory deployed, Config memory cfg) private {
        IFiatTokenProxyAdmin proxyAdmin = IFiatTokenProxyAdmin(deployed.fiatTokenProxy);
        (bool ok, bytes memory data) = address(proxyAdmin).staticcall(abi.encodeWithSelector(proxyAdmin.admin.selector));
        if (ok) {
            address currentAdmin = abi.decode(data, (address));
            if (currentAdmin != cfg.proxyAdmin) {
                proxyAdmin.changeAdmin(cfg.proxyAdmin);
            }
        } else {
            proxyAdmin.changeAdmin(cfg.proxyAdmin);
        }
    }

    struct LinkReference {
        uint256 start;
        uint256 length;
    }

    function _ensureFiatTokenProxyAdmin(address proxy, address desiredAdmin) private {
        IFiatTokenProxyAdmin proxyAdmin = IFiatTokenProxyAdmin(proxy);
        address currentAdmin = proxyAdmin.admin();
        if (currentAdmin != desiredAdmin) {
            proxyAdmin.changeAdmin(desiredAdmin);
        }
    }

    function _deployFiatTokenImplementation(address signatureChecker) private returns (address deployed) {
        require(signatureChecker != address(0), "SIGNATURE_CHECKER_ADDRESS not set");
        bytes memory bytecode = _loadLinkedFiatTokenBytecode(signatureChecker);
        deployed = _create(bytecode);
        require(deployed != address(0), "FiatTokenV2_2 deployment failed");
    }

    function _loadLinkedFiatTokenBytecode(address signatureChecker) private returns (bytes memory bytecode) {
        string memory json = vm.readFile(FIAT_TOKEN_IMPL_ARTIFACT);
        string memory hexCode = json.readString(".bytecode.object");
        string memory pointer = ".bytecode.linkReferences[\"src/circle/util/SignatureChecker.sol\"].SignatureChecker";
        if (!json.keyExists(pointer)) {
            return vm.parseBytes(hexCode);
        }

        uint256 refCount = 0;
        while (true) {
            string memory elementPointer = string.concat(pointer, "[", vm.toString(refCount), "]");
            if (!json.keyExists(elementPointer)) {
                break;
            }
            unchecked {
                ++refCount;
            }
        }

        LinkReference[] memory refs = new LinkReference[](refCount);
        for (uint256 idx = 0; idx < refCount; ++idx) {
            string memory base = string.concat(pointer, "[", vm.toString(idx), "]");
            refs[idx] = LinkReference({
                start: json.readUint(string.concat(base, ".start")),
                length: json.readUint(string.concat(base, ".length"))
            });
        }
        bytes memory codeChars = bytes(hexCode);
        bytes memory symbols = "0123456789abcdef";
        bytes20 addr = bytes20(signatureChecker);

        for (uint256 i = 0; i < refs.length; ++i) {
            LinkReference memory ref = refs[i];
            uint256 offset = 2 + ref.start * 2;
            uint256 segmentLength = ref.length * 2;
            require(offset + segmentLength <= codeChars.length, "link ref overflow");
            for (uint256 j = 0; j < ref.length; ++j) {
                uint8 byteValue = uint8(addr[j]);
                codeChars[offset + j * 2] = symbols[byteValue >> 4];
                codeChars[offset + j * 2 + 1] = symbols[byteValue & 0x0f];
            }
        }

        return vm.parseBytes(string(codeChars));
    }

    function _create(bytes memory bytecode) private returns (address deployed) {
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }

    function _logSummary(DeploymentArtifacts memory deployed, Config memory cfg) private {
        console.log("=== Deployment Results (L2 chain %s) ===", block.chainid);
        console.log("SignatureChecker:", deployed.signatureChecker);
        console.log("FiatToken implementation:", deployed.fiatTokenImpl);
        console.log("FiatToken proxy:", deployed.fiatTokenProxy);
        console.log("MasterMinter:", deployed.masterMinter);
        console.log("L2 USDC bridge implementation:", deployed.l2BridgeImpl);
        console.log("L2 USDC bridge proxy:", deployed.l2BridgeProxy);
        console.log("Proxy admin:", cfg.proxyAdmin);
        console.log("Governance:", cfg.governance);
    }
}
