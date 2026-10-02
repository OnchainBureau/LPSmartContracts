# OnchainBureauMMv4

## Current review revision: permissionless fixed-price initialization (V2)

[`OnchainBureauPublicMMV4V2.sol`](src/OnchainBureauPublicMMV4V2.sol) removes only
the requirement that the initializer be the fee operator. Anyone may initialize
the one canonical pool at its immutable starting price. Wrong prices, different
pool configurations and repeat initialization remain rejected. Initializing does
not grant fee authority or access to Safe assets. Owner/operator powers remain
unchanged. An outsider can trigger launch timing; integrations must handle an
already-initialized pool using regular LP minting, not initialize-and-mint.

Earlier source files below are preserved for historical deployments. Do not
confuse their deployment addresses with this revision.

## Undeployed public-routing candidate

This branch additionally publishes [`OnchainBureauPublicMMV4`](src/OnchainBureauPublicMMV4.sol).
It is **not deployed, explorer-verified, audited or approved by Uniswap Labs**.
The addresses below identify the original contract, NOT this candidate. Publishing
this file does not change the existing pool or its deployed hook.

The candidate removes discretionary swap halts, external risk-oracle gating and
all liquidity-entry policy callbacks. Its permission bitmap is `0x30c0`:
before/after initialize and before/after swap. Return-delta flags remain disabled;
no custom hook data is required, and native protocol-fee accounting is preserved.
Dynamic LP fees remain hard-bounded to 0.05%–2.50%. Owner/operator fee powers,
directional fee bias and optional swap telemetry remain. Initialization is still
operator-authorized for one immutable pool and initial price. There are no
range-crossing events in this candidate. No guarantee of routing approval is made.

The original rejection did not identify a specific reason. These changes are a
reduced-capability design, not proof that the removed features caused rejection.
Dynamic fees still require review. A new deployment, verified source and funded
pool are needed before resubmission; the old pool cannot change its hook.

Validation on 2026-10-02: 13 candidate tests passed (including 1,000 fee-bound
fuzz cases). A local Robinhood-mainnet fork at block 78252813 passed fresh
Safe/Zodiac grants, bootstrap/revocation, unrelated-call denials and the actual
Rust MM's buys/sells against external liquidity, mint/reposition/close lifecycle.
An initial integration failure was fixed by retaining constant open/unpaused
LP-policy status getters; they cannot restrict liquidity or be configured.
This evidence does not constitute an audit or a public-chain candidate deployment.

The candidate uses the same compiler settings and dependency revisions documented
below. Only hook source and documentation are published here, not operational
configuration, signing material or the liquidity manager.

Hook-only source publication for the EMRL.X / USDG Uniswap v4 pool on Robinhood
Chain. This repository contains the hook and its required custom risk-oracle
interface; it does not contain the liquidity manager, market-making bot, deployment
scripts, wallet material, or operational configuration.

## Deployment

| Item | Value |
| --- | --- |
| Network | Robinhood Chain mainnet (4663) |
| Hook | `0x43742B20b18d7C5A5ceB57CCa24cF679896Af8C0` |
| Pool ID | `0x6e94e438c0a13a39632f4b9586c8565d215142bd388913c8576f51a8ed274730` |
| EMRL.X | `0x2ed26Dd7BEfE020B39916E9CeAf1D6a96a52CDD6` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Tick spacing | 60 |
| Pool fee type | Dynamic |

[Hook on the explorer](https://robinhoodchain.blockscout.com/address/0x43742B20b18d7C5A5ceB57CCa24cF679896Af8C0?tab=contract)

## Source

- [`src/OnchainBureauMMv4.sol`](src/OnchainBureauMMv4.sol)
- [`src/interfaces/IEMRLRiskOracle.sol`](src/interfaces/IEMRLRiskOracle.sol)

The source implements a non-proxy, single-pool policy hook with canonical pool
validation, initialization checks, bounded directional LP fees, optional
liquidity-entry policies, optional risk-oracle checks, and swap/range telemetry.

Enabled callbacks: `beforeInitialize`, `afterInitialize`, `beforeAddLiquidity`,
`beforeSwap`, and `afterSwap`. Permission bitmap: `0x38c0`.

No return-delta flags or remove-liquidity callbacks are enabled. The hook does
not take custody or replace normal swap settlement. Swap callers do not need
custom hook calldata. Deployment fee bounds are 0.05%–2.50%.

## Administrative capabilities and risks

Immutable code does not mean immutable policy. The owner can configure permitted
fees, trading halt/buy-block modes, optional oracle/reserve/NAV checks, and
liquidity-entry restrictions. Consult the source and current onchain state before
interacting; the presence of a capability does not establish whether it is enabled.
The absence of withdrawal callbacks does not remove other protocol or market risks.

No independent third-party audit is claimed by this publication. Testing is not
a guarantee of security, profitability, or uninterrupted trading.

## Build requirements

This is a source-only publication, not a complete Foundry project. To compile,
use Solidity **0.8.26**, EVM **Cancun**, optimizer enabled with **200 runs**,
`viaIR=false`, and metadata `bytecodeHash="none"`.

The deployment workspace used these dependency revisions:

| Import prefix | Upstream repository | Revision |
| --- | --- | --- |
| `@openzeppelin/contracts/` | `OpenZeppelin/openzeppelin-contracts` | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| `@uniswap/v4-core/` | `Uniswap/v4-core` | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` |
| `@uniswap/v4-periphery/` | `Uniswap/v4-periphery` | `dce236d4e2057422d0791d9a973a58765eb46f65` |
| `@uniswap/v4-hooks-public/` | `Uniswap/v4-hooks-public` | `0f731d5de0f4fd60b506b55754d5e6ff086eab7d` |

Install those dependencies with their required submodules and configure remappings
to the corresponding local paths. Dependencies and build outputs are deliberately
not vendored in this hook-only repository.

## Verification and interface routing

At publication, both source files were matched against the deployment build
artifact, and its creation bytecode was matched against the hook deployment
transaction. This local check is **not explorer verification**.

Explorer verification and Uniswap Labs routing approval were not confirmed at
publication. Dynamic-fee hooks require routing review under the Labs interface's
[hook routing criteria](https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools).
A deployed pool and successful direct quotes do not guarantee availability in
Uniswap's interface, MetaMask, or third-party indexers.

## License

The two published source files carry SPDX `MIT` identifiers. External dependencies
retain their respective licenses.
