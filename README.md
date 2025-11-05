# ZKsync OS USDC Deployment Scripts

This repository contains Forge scripts that automate the zkSync OS L2 USDC deployment flow outlined below. They cover three phases:

1. Deploy the Circle `SignatureChecker` library.
2. Deploy the L2 USDC token stack and L2 bridge, wire all roles, and persist addresses.
3. Register the L2 bridge with the existing L1 shared bridge.

The scripts deploy the full stack and submit verification requests when executed through the provided npm tasks, but they do **not** deploy the L1 bridge itself. If you skip the npm wrappers and run Forge manually, remember to perform verification separately.

## Prerequisites

- Foundry installed (`forge`, `cast`, `anvil`).
- Node.js (>= 16) for installing JavaScript dependencies.
- Access to both the target L2 RPC endpoint and the corresponding L1 RPC endpoint (Sepolia / Mainnet).
- Private keys for:
  - The deployer (responsible for deploying contracts and the initial MasterMinter wiring).
  - The proxy admin (used to administer the L2 bridge proxy and to register the L2 bridge on L1).
  - Optional: a distinct account that will act as the L2 ProxyAdmin if different from the deployer.
- The L1 USDC bridge and L1 USDC token already deployed.

## Repository Setup

Install dependencies and build the external libraries so that the deployment scripts can load bytecode artifacts:

```bash
git submodule update --init --recursive
npm install

# Circle stablecoin contracts
(cd lib/stablecoin-evm && yarn install --ignore-engines --ignore-scripts && FOUNDRY_NO_LINT=1 forge build)

# Matter Labs bridge contracts
(cd lib/usdc-bridge && yarn install --ignore-scripts && forge build)
```

Return to the repository root before running any Forge scripts.

## Source Layout

We vendor minimal copies of the Circle FiatToken stack (`src/circle`) and the Matter Labs bridge contracts (`src/usdc-bridge`). Foundry compiles these sources to emit the artifacts the deployment scripts consume (for example `out/FiatTokenV2_2.sol/FiatTokenV2_2.json`). If you delete the directories, `forge build` will no longer produce the expected artifacts and the scripts will fail unless you also update the artifact paths and remappings to point at the upstream submodules.

## Environment Variables

The scripts are driven entirely through environment variables. A starter `.env.example` file is available in the repository root—copy it to `.env`, fill in the values, and run `source .env` before executing the scripts. **Private keys must be supplied without a `0x` prefix.**

### Required keys

| Variable | Description |
| --- | --- |
| `DEPLOYER_PRIVATE_KEY` | Hex private key for the deployer (supply without the `0x` prefix). Required for all deployment transactions. |
| `L1_USDC_BRIDGE_OWNER_PRIVATE_KEY` | Hex private key (without the `0x` prefix) that owns the L1 USDC bridge proxy and can register new chains. |

### SignatureChecker Deployment (`DeploySignatureChecker.s.sol`)

| Variable | Description |
| --- | --- |
| `DEPLOYER_PRIVATE_KEY` | Used to broadcast the deployment transaction. |

The deployed address must be captured and used in the next step (`SIGNATURE_CHECKER_ADDRESS`).

### L2 Stack Deployment (`DeployZkSyncOsUSDC.s.sol`)

| Variable | Description |
| --- | --- |
| `SIGNATURE_CHECKER_ADDRESS` | Address of the previously deployed `SignatureChecker` library. |
| `L1_USDC_ADDRESS` | Canonical USDC token on L1. |
| `L1_USDC_BRIDGE_PROXY` | L1 shared bridge proxy address (already deployed). |
| `PROXY_ADMIN_ADDRESS` | Address that should own the L2 proxy contracts after deployment. |
| `GOVERNANCE_ADDRESS` | Address that should receive token ownership and MasterMinter ownership. |
| `PROXY_ADMIN_OWNER` | (Optional) Owner assigned when deploying a new ProxyAdmin via the helper script. |
| `PROXY_ADMIN_ADDRESS_CHECK` | (Optional) Safety latch: the script reverts if this differs from `PROXY_ADMIN_ADDRESS`. |

#### Optional overrides

These variables allow you to reuse existing deployments and skip re-deployment of specific components:

| Variable | Description |
| --- | --- |
| `EXISTING_FIAT_TOKEN_IMPL` | Use an already deployed FiatToken implementation. |
| `EXISTING_FIAT_TOKEN_PROXY` | Use an existing FiatToken proxy. |
| `EXISTING_MASTER_MINTER` | Use an existing MasterMinter contract. |
| `EXISTING_L2_BRIDGE_IMPL` | Use an existing L2 bridge implementation. |
| `EXISTING_L2_BRIDGE_PROXY` | Use an existing L2 bridge proxy. |

#### Token metadata and behaviour

| Variable | Default | Description |
| --- | --- | --- |
| `TOKEN_NAME` | `USD Coin` | Initial name used during `initialize`. |
| `TOKEN_SYMBOL` | `USDC` | Initial symbol used during `initialize`. |
| `TOKEN_CURRENCY` | `USD` | Fiat currency string passed to `initialize`. |
| `TOKEN_DECIMALS` | `6` | ERC20 decimals. |
| `TOKEN_NAME_V2` | `TOKEN_NAME` | Name applied during `initializeV2`. |
| `TOKEN_SYMBOL_V2` | `TOKEN_SYMBOL` | Symbol applied during `initializeV2_2`. |
| `MASTER_MINTER_ALLOWANCE` | `uint256.max` | Allowance granted to the L2 bridge minter. |
| `LOST_AND_FOUND_ADDRESS` | `GOVERNANCE_ADDRESS` | Destination for stranded funds when running `initializeV2_1`. |
| `RESCUER_ADDRESS` | unset | Optional rescuer role for the token. (Script does not assign roles; leave empty or fill for reference.) |
| `INITIAL_BLACKLIST` | empty | Comma-separated list of addresses to migrate when running `initializeV2_2`. |

#### Safety checks

| Variable | Description |
| --- | --- |
| `DEPLOYER_ADDRESS` | (Optional) Expected address for the deployer key. The script reverts if it does not match. |

#### Manual role transfers

If you plan to execute the post-deployment governance transfers manually, you may still want to define:

| Variable | Description |
| --- | --- |
| `PAUSER_ADDRESS` | Target pauser role used when running the manual `updatePauser` transaction. |
| `BLACKLISTER_ADDRESS` | Target blacklister role used when running the manual `updateBlacklister` transaction. |

#### Verification settings (optional)

These values are consumed by the npm scripts when you run deployments with `--verify`.

| Variable | Description |
| --- | --- |
| `CHAIN_VERIFICATION_URL` | Explorer verifier endpoint (e.g., ZKsync custom verifier URL). |
| `VERIFIER` | Verifier type passed to Forge (defaults to `custom` when unset). |
| `ETHERSCAN_API_KEY` | Optional API key if the verifier requires one. |

### L1 Bridge Registration (`InitializeL1UsdcBridge.s.sol`)

| Variable | Description |
| --- | --- |
| `L1_USDC_BRIDGE_OWNER_PRIVATE_KEY` | Broadcast key (must own the L1 bridge admin rights). |
| `L1_USDC_BRIDGE_PROXY` | L1 bridge proxy (same as above). |
| `L2_USDC_BRIDGE_PROXY` | Resulting L2 bridge proxy address from the previous step. |
| `L2_CHAIN_ID` | Numeric chain ID of the target ZKsync OS chain. |

## Execution Flow

Run `npm install` once to register the helper scripts below, then execute each step from the project root after sourcing your `.env`.

0. **(Optional) Deploy a ProxyAdmin**

   ```bash
   npm run deploy:proxyadmin
   ```

   This deploys an OpenZeppelin `ProxyAdmin`, leaving ownership with the deployer by default. If `PROXY_ADMIN_OWNER` is set and differs from the deployer address, the script transfers ownership accordingly. The npm script runs Forge with `--verify`, so verification is submitted automatically.

1. **Deploy SignatureChecker**

   ```bash
   npm run deploy:signature-checker
   ```

   Record the printed address and set it as `SIGNATURE_CHECKER_ADDRESS`. Verification is handled as part of the npm script.

2. **Deploy the L2 USDC stack**

   ```bash
   npm run deploy:l2-stack
   ```

   The script:

   - Deploys (or reuses) the FiatToken implementation, proxy, MasterMinter, and L2 bridge implementation.
   - Initializes the FiatToken across all upgrade phases (v1 → v2 → v2.1 → v2.2) when initialization is still pending.
   - Configures the MasterMinter controller so the L2 bridge proxy receives the specified mint allowance, then transfers MasterMinter ownership to governance.
   - Transfers token ownership to governance (pauser/blacklister roles remain untouched; follow the original checklist if they must change).
   - Ensures the FiatToken proxy admin is set to `PROXY_ADMIN_ADDRESS`, eliminating the need for a manual `changeAdmin` transaction.
   - Deploys the TransparentUpgradeableProxy for the L2 bridge (if required) with the correct initializer.
   - Writes the resulting addresses to `deployments/<chainId>/addresses.json`.
   - Submits verification requests for all deployed contracts as part of the npm script (the command passes the SignatureChecker library address via `--libraries`).

3. **Register the L2 bridge on L1**

   ```bash
   npm run register:l1
   ```

This calls `initializeChainGovernance` on the existing L1 bridge, associating the new L2 bridge proxy address with the chain ID. It is the only step that needs `L1_USDC_BRIDGE_OWNER_PRIVATE_KEY`.

## Post-Deployment Tasks

- If you skipped the `--verify` flow (for example by running Forge manually), execute the appropriate `forge verify-contract` commands for each contract (FiatToken implementation, proxy, MasterMinter, L2 bridge implementation/proxy) using your verifier settings.
- Run the allowance / governance sanity checks you require (e.g. `cast call` to confirm roles, minter allowance, token owner).
- Update internal deployment tracking systems with the addresses emitted by the scripts.

## Troubleshooting

- **`forge` complains about lint violations in upstream dependencies:** pass `FOUNDRY_NO_LINT=1` when compiling those libraries. The top-level project scripts still compile through normal Forge runs.
- **Missing artifacts for external libraries:** verify you ran `forge build` inside each dependency directory (`lib/stablecoin-evm` and `lib/usdc-bridge`). The scripts reference the JSON artifacts inside `out/`.
- **`initialize` calls revert as “already initialized”:** the script treats that as expected and logs the skip; double-check the addresses provided via `EXISTING_*` variables if you intended to redeploy.
- **Broadcast account mismatches:** set `DEPLOYER_ADDRESS` and/or `PROXY_ADMIN_ADDRESS_CHECK` to force the script to halt when a wrong key is used.

## Artifact Outputs

Deployment results are echoed to the console and persisted to `deployments/<chainId>/addresses.json`. Example structure:

```json
{
  "USDC": "0x...",
  "L2USDCBridge": "0x...",
  "L2USDCBridge-impl": "0x..."
}
```

These files are used by the scripts to pick up existing deployments on subsequent runs. If you operate against a different ecosystem or deploy new instances manually, ensure that the relevant `deployments/<chainId>/addresses.json` file is updated with the contract addresses your environment should use (e.g., Bridgehub, L1/L2 bridges, USDC).

## Bridge Testing Scripts

To validate the L1 → L2 transfer flows we now ship two helper scripts that bridge a small USDC amount through the shared bridge:

- `npm run bridge:eth` – targets hyperchains whose base token is ETH. The script estimates the L2 base cost and sends the required ETH along with the deposit. USDC approvals are granted to the `L1USDCBridge` proxy for the exact transfer amount so the ERC20 leg routes through the dedicated bridge.
- `npm run bridge:cbt` – targets hyperchains whose base token is *not* ETH (for example CBT-style deployments). It approves the base token (with an unlimited allowance) for the shared bridge contract and USDC (exact transfer amount) for the `L1USDCBridge` proxy, then mints the requested amount during the deposit.

Both commands expect the usual `.env` values (`DEPLOYER_PRIVATE_KEY`, `L1_RPC_URL`) and rely on explicit address variables so you can target any ecosystem without editing the deployment manifests. Ensure the following environment variables are set before running either script:

| Script | Required env vars | Optional env vars |
| --- | --- | --- |
| `bridge:eth` | `BRIDGEHUB_ADDRESS`, `L1_USDC_BRIDGE_PROXY`, `L1_USDC_ADDRESS`, `L2_CHAIN_ID` | `USDC_BRIDGE_AMOUNT` (defaults to 1e6), `ETH_BRIDGE_L2_GAS_LIMIT` (450_000), `ETH_BRIDGE_L2_GAS_PER_PUBDATA` (800), `ETH_BRIDGE_L2_GAS_PRICE` (1 gwei), `ETH_BRIDGE_MINT_VALUE` (defaults to the estimated base cost), `ETH_BRIDGE_SECOND_BRIDGE_VALUE` (0), `ETH_BRIDGE_RECIPIENT` (sender) |
| `bridge:cbt` | `BRIDGEHUB_ADDRESS`, `L1_USDC_BRIDGE_PROXY`, `L1_USDC_ADDRESS`, `L2_CHAIN_ID`, `CBT_BASE_TOKEN_ADDRESS` | `USDC_BRIDGE_AMOUNT` (1e6), `CBT_BRIDGE_MINT_VALUE` (10 ether), `CBT_BRIDGE_L2_GAS_LIMIT` (450_000), `CBT_BRIDGE_L2_GAS_PER_PUBDATA` (800), `CBT_BRIDGE_RECIPIENT` (sender) |

The scripts emit console logs for allowances and the transaction parameters so you can confirm the configuration before broadcasting.

### Withdrawal Scripts (TODO)

End-to-end withdrawal automation is still under development. Follow the [official zkOS withdrawal guide](https://github.com/mm-zk/zkos-docs/blob/main/step-by-step/02_withdrawals.md) manually for now. Once the tooling stabilises we will ship dedicated helpers for:

- Initiating withdrawals via the L2 USDC bridge.
- Fetching proofs / finalizing on L1.

Pull requests or suggestions are welcome if you have a reliable workflow in the meantime.

## Related Documentation

- Legacy manual checklist – see repository history if you need the original step-by-step runbook these scripts replace.
- Circle stablecoin repository: <https://github.com/circlefin/stablecoin-evm>
- Matter Labs USDC bridge repository: <https://github.com/matter-labs/usdc-bridge>
