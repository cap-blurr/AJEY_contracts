# AJEY — Automated Multi‑Asset Yield → Public Goods (Octant v2 + Aave v3)

## NB:
This is an existing project that I started in the just concluded base batches hackathon, the main branch from AJEY_contracts was the previous code from the hackathon, the current code for octant is under the octant-branch in the same repo

> **Elevator pitch.** Deposit once (ETH or stablecoins). My **agent orchestrator** reallocates across Aave v3 markets (WETH/USDC/USDT/DAI) for best net yield. **All realized yield** is donated on‑chain to **multiple** public‑goods recipients via preset mixes (Crypto‑Maxi, Balanced, Humanitarian‑Maxi).

---

## Tracks I’m targeting

* **Best public goods projects**
* **Most creative use of Octant v2 for public goods**
* **Best use of Aave v3 (Aave Vaults)**
* **Best use of a Yield Donating Strategy (YDS)**

---

## What I built (current iteration — `octant-branch`)

### High‑level architecture

* **Single‑asset ERC‑4626 vaults** (per asset: WETH, USDC, USDT, DAI) that supply to **Aave v3** and track gains.
* **Agent orchestrator** (implemented in `AgentReallocator.sol`) that:

  * Realizes profits,
  * **Migrates** user share positions across vaults (e.g., DAI → USDT) with a whitelisted swap aggregator + slippage/deadline guards,
  * Triggers re‑deploy to the new Aave market.
* **Donation router (off‑chain policy, on‑chain payments):** splits realized yield across **three causes** per user‑selected preset:

  * *Crypto‑Maxi* → 60% crypto public goods / 20% humanitarian / 20% hygiene
  * *Balanced* → 40% / 30% / 30%
  * *Humanitarian‑Maxi* → 20% / 40% / 40%

# Internal Architecture

---

## System architecture at a glance

* **AjeyVault** — ERC‑4626 vault per asset (WETH/USDC/USDT/DAI) that supplies to **Aave v3**, mints performance fees in shares, and enforces deposit policy.
* **AaveYieldDonatingStrategy (Octant YDS)** — Single‑asset strategy that deploys to exactly one AjeyVault and donates profit on `report()`.
* **AgentOrchestrator** — Main agent entrypoint. Maintains profile→asset→strategy mappings; executes deposits, withdrawals, reallocations (Uniswap V3 swaps), and harvesting.
* **AgentReallocator** — Migration helper using whitelisted aggregators (e.g., 1inch/0x) for cross‑strategy asset swaps.
* **PaymentSplitters** — Donation recipients for *Balanced / MaxHumanitarian / MaxCrypto*.

### Profiles

* `Balanced = 0`, `MaxHumanitarian = 1`, `MaxCrypto = 2`

---

## Roles and permissions (code‑cited)

**AjeyVault**

```solidity
// src/core/AjeyVault.sol
bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");
```

**AaveYieldDonatingStrategy**

* Uses Octant TokenizedStrategy roles: `management`, `keeper` (often the Orchestrator), `emergencyAdmin`.

**AgentOrchestrator**

```solidity
// src/octant/AgentOrchestrator.sol
constructor(address _admin, address _agent, address _uniswapRouter, uint24 _defaultPoolFee) {
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(AGENT_ROLE, _agent);
}
```

**AgentReallocator**

```solidity
// src/core/AgentReallocator.sol
constructor(address admin, address agent) {
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(AGENT_ROLE, agent);
}
```

**PaymentSplitter (Octant)**

```solidity
// src/interfaces/octant/IPaymentSplitter.sol
interface IPaymentSplitter {
    function initialize(address[] calldata payees, uint256[] calldata shares_) external;
    function release(address token, address account) external;
    function totalShares() external view returns (uint256);
    function shares(address account) external view returns (uint256);
}
```

---

## Accounting model & safeguards (code‑cited)

### AjeyVault

**Total assets = idle underlying + aToken balance**

```solidity
// src/core/AjeyVault.sol
function totalAssets() public view override returns (uint256) {
    uint256 idle = UNDERLYING.balanceOf(address(this));
    uint256 aBal = A_TOKEN.balanceOf(address(this));
    return idle + aBal;
}
```

**Deposit/mint gating**

```solidity
// src/core/AjeyVault.sol
require(publicDepositsEnabled || hasRole(STRATEGY_ROLE, msg.sender), "strategy only");
```

**Auto‑supply to Aave after deposit (optional)**

```solidity
// src/core/AjeyVault.sol
if (autoSupply) {
    uint256 idle = UNDERLYING.balanceOf(address(this));
    if (idle > 0) {
        aavePool.supply(address(UNDERLYING), idle, address(this), 0);
    }
}
```

**Withdraw / redeem pulls from Aave if needed**

```solidity
// src/core/AjeyVault.sol
uint256 idle = UNDERLYING.balanceOf(address(this));
if (idle < assets) {
    uint256 toPull = assets - idle;
    uint256 received = aavePool.withdraw(address(UNDERLYING), toPull, address(this));
    require(received >= toPull, "Insufficient Aave withdrawal");
}
```

**Performance fee minted in shares at checkpoint**

```solidity
// src/core/AjeyVault.sol
uint256 currentAssets = totalAssets();
uint256 prevCheckpointAssets = lastCheckpointAssets;
if (currentAssets > prevCheckpointAssets && feeBps > 0) {
    uint256 grossGain = currentAssets - prevCheckpointAssets;
    uint256 feeAssets = (grossGain * feeBps) / 10_000;
    uint256 sharesForFee = convertToShares(feeAssets);
    _mint(treasury, sharesForFee);
}
```

**ETH convenience for WETH vaults**

```solidity
// src/core/AjeyVault.sol
require(ethMode, "ETH disabled");
require(publicDepositsEnabled || hasRole(STRATEGY_ROLE, msg.sender), "strategy only");
// optional WETHGateway integration
```

### AaveYieldDonatingStrategy (Octant YDS)

**Single‑asset, single‑vault invariant**

```solidity
// src/octant/AaveYieldDonatingStrategy.sol
require(_vault != address(0), "vault=0");
require(AjeyVault(_vault).asset() == _asset, "asset mismatch");
vault = AjeyVault(_vault);
IERC20(_asset).forceApprove(_vault, type(uint256).max);
```

**Deploy & free funds defer to the vault**

```solidity
// src/octant/AaveYieldDonatingStrategy.sol
function _deployFunds(uint256 amount) internal override { if (amount == 0) return; vault.deposit(amount, address(this)); }
function _freeFunds(uint256 amount)   internal override { if (amount == 0) return; vault.withdraw(amount, address(this), address(this)); }
```

**Valuation for report()**

```solidity
// src/octant/AaveYieldDonatingStrategy.sol
uint256 idle = IERC20(address(asset)).balanceOf(address(this));
uint256 shares = vault.balanceOf(address(this));
uint256 vaultValue = vault.convertToAssets(shares);
return idle + vaultValue;
```

### Orchestrator (selected flows)

**Set strategy mapping (profile, asset) → strategy**

```solidity
// src/octant/AgentOrchestrator.sol
function setStrategy(Profile profile, address asset, address strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(asset != address(0) && strategy != address(0), "bad addr");
    require(IBaseStrategy(strategy).asset() == asset, "mismatch");
    strategyOf[profile][asset] = strategy;
}
```

**Deposit with optional swap, then deposit into strategy**

```solidity
// src/octant/AgentOrchestrator.sol
IERC20(inputAsset).safeTransferFrom(from, address(this), amountIn);
if (inputAsset != targetAsset) { /* Uniswap V3 exactInputSingle */ }
IERC20(targetAsset).forceApprove(strategy, amountToDeposit);
sharesOut = IBaseStrategy(strategy).deposit(amountToDeposit, receiver);
```

**Reallocate (report → compute assets → withdraw → swap → deposit)**

```solidity
// src/octant/AgentOrchestrator.sol
try IBaseStrategy(sourceStrategy).report() {} catch {}
uint256 totalAssets = IBaseStrategy(sourceStrategy).totalAssets();
uint256 totalSupply = IERC20(sourceStrategy).totalSupply();
uint256 assetsFrom = (shares * totalAssets) / totalSupply;
IBaseStrategy(sourceStrategy).withdraw(assetsFrom, address(this), owner);
// swap if needed → deposit to target
```

**Harvest helpers**

```solidity
// src/octant/AgentOrchestrator.sol
function harvestAll() external onlyRole(AGENT_ROLE) { /* iterate */ }
function _harvestStrategy(address strategy) internal { (uint256 profit, uint256 loss) = IBaseStrategy(strategy).report(); }
```

### Reallocator (selected flows)

**Migrate via whitelisted aggregator**

```solidity
// src/core/AgentReallocator.sol
require(isAggregator[aggregator], "agg not allowed");
// approve → low‑level call → balance‑delta check → minAmountOut guard
```

---

## External interfaces & exact signatures (abridged)

* **Orchestrator (agent‑only)** — `depositERC20`, `withdrawERC20`, `reallocate`, `permitShares`, `harvestAll/harvestProfile/harvestStrategy`, `strategyOf`.
* **Reallocator** — `migrateStrategyShares`, `permitShares`, `setAggregator`.
* **Strategy** — `vault()`, `TOKENIZED_STRATEGY_ADDRESS()` + Octant TokenizedStrategy surface.
* **Vault** — ERC‑4626 + maintenance: `setParams`, `setAutoSupply`, `setPublicDepositsEnabled`, `setEthGateway`, `depositEth/withdrawEth`, `supplyToAave`, `withdrawFromAave`, `takeFees`, `checkpoint`, `addStrategy/removeStrategy`, `addAgent/removeAgent`.

---

## Invariants & safety checks (summary)

* **Single‑source strategy:** Strategy asset must equal vault asset; cross‑asset moves live in Orchestrator/Reallocator.
* **Deposit access control:** Strategy‑only deposits when `publicDepositsEnabled=false`.
* **Liquidity fulfillment:** Vault withdraw path pulls from Aave when idle is insufficient.
* **Slippage controls:** `minAmountOut` required; Reallocator validates via balance‑delta.
* **P/L realization before moves:** `report()` invoked before computing `assetsFrom`.
* **Approval hygiene:** `forceApprove` usage; aggregator approvals cleared.

---

## Deployment & wiring (reviewer view)

1. **PaymentSplitters** — Deploy three splitters with share weights for *(Balanced / MaxHumanitarian / MaxCrypto)*.
2. **AjeyVaults** — Deploy per asset; optionally set `publicDepositsEnabled=false`, `autoSupply=true`; grant `AGENT_ROLE` to the agent wallet.
3. **AgentOrchestrator** — Deploy with `(admin, agent, uniswapRouter, defaultPoolFee)`; set strategies via `setStrategy`.
4. **AaveYieldDonatingStrategy** — Deploy per *(asset × profile)*; `keeper` points to Orchestrator; donation address = splitter.
5. **AgentReallocator (optional)** — Deploy and `setAggregator(...)` allowlist.

---

## Why this is a creative YDS implementation

* **Strict YDS purity on‑chain** (single‑source strategies, donation at `report()`), combined with **off‑chain, agent‑driven cross‑asset allocation** yields a *multi‑asset* YDS experience without bloating on‑chain complexity.
* **Auditable minimal surface area** (small vaults, thin strategies, periphery orchestration) preserves clarity and reduces risk while achieving multi‑cause, multi‑asset funding.

### Donation recipients (mainnet EVM)

* **Crypto public goods:** Web3Afrika — `0x4BaF3334dF86FB791A6DF6Cf4210C685ab6A1766`
* **Humanitarian:** Save the Children UK — `0x82657beC713AbA72A68D3cD903BE5930CC45dec3`
* **Hygiene/WASH (Kenya):** The Water Project — `0xA0B0Bf2D837E87d2f4338bFa579bFACd1133cFBd`

> **Why YDS + single‑asset vaults (not MSV)?** YDS favors **single‑source** strategies that donate profit via minted shares. I keep each vault small and auditable, and I perform **cross‑asset reallocation off‑chain** via the orchestrator. This avoids the heavier debt/queue accounting of a multi‑strategy vault while preserving modularity and clarity.

---

## What changed since the previous iteration (main → `octant-branch`)

**Main branch (previous iteration)**

* Early **multi‑asset vault** experiments (heavier accounting/debt queues).
* Direct vault‑centric flows, less separation between allocation and donation logic.
* Initial Aave interactions and fee hooks without donation presets nor cross‑asset orchestration.

**Current branch (`octant-branch`)**

* **Split into 4 single‑asset ERC‑4626 vaults** (WETH, USDC, USDT, DAI) for clean, per‑asset accounting and simpler audits.
* Introduced **agent orchestrator** (in `AgentReallocator.sol`) to **migrate shares cross‑asset**:

  * calls `report()`/profit realization on source,
  * withdraws → optional swap via **whitelisted aggregator** → deposit to target,
  * enforces **role‑gated execution**, **slippage guards**, **deadline**.
* **Aave v3 supply/withdraw helpers** in each vault (e.g., `supplyToAave`, `withdrawFromAave`) triggered by the agent.
* **Donation policy** upgraded from single sink → **multi‑recipient preset mixes** (Crypto‑Maxi / Balanced / Humanitarian‑Maxi) with **fixed on‑chain addresses**.
* **Deployment** stabilized for **mainnet fork/Tenderly** by using `--skip-simulation` to avoid wrong addresses from pre‑deploy simulation.
* Restructured source into clearer folders (e.g., `src/core/…`, `src/interfaces/…`) and added `AccessControl` roles.

> **Result:** Same user UX (deposit/redeem via ERC‑4626), but the system now **automates cross‑asset optimization** within Aave and **splits every profit to multiple public goods**, matching Octant’s YDS ethos while keeping code surface minimal.

---

## How it fits the tracks (quick rationale)

* **Public goods:** default outcome is **donations**, not depositor yield; multi‑recipient routing broadens impact.
* **Octant v2 creativity:** standard YDS semantics + **multi‑cause splits** with off‑chain orchestration for cross‑asset moves.
* **Aave v3 vaults:** each vault is an **ERC‑4626 Aave v3** integrator; orchestrator reallocates across **WETH/USDC/USDT/DAI** markets.
* **YDS:** profits → donation shares (conceptually) / realized → on‑chain recipients; losses first offset donation exposure.

---

## Repo structure (current)

```
AJEY/
  ├─ src/
  │  ├─ core/
  │  │  ├─ AgentReallocator.sol
  │  │  └─ AjeyVault.sol
  │  ├─ interfaces/
  │  │  ├─ IAaveV3Pool.sol
  │  │  ├─ IBaseStrategy.sol
  │  │  ├─ IStrategyPermit.sol
  │  │  ├─ IUniswapV3Router.sol
  │  │  ├─ IWETH.sol
  │  │  ├─ IWETHGateway.sol
  │  │  └─ octant/
  │  │     └─ IPaymentSplitter.sol
  │  └─ octant/
  │     ├─ AaveYieldDonatingStrategy.sol
  │     └─ AgentOrchestrator.sol
  ├─ script/
  │  ├─ DeployAjey.s.sol
  │  ├─ DeployAaveYDS.s.sol
  │  ├─ DeployOrchestrator.s.sol
  │  ├─ DeployReallocator.s.sol
  │  ├─ DeployPaymentSplitters.s.sol
  │  └─ GrantStrategyRoles.s.sol
  └─ test/
     ├─ AgentReallocator.t.sol
     ├─ AjeyVault.t.sol
     ├─ mocks/
     │  ├─ MockAave.sol
     │  ├─ MockAggregator.sol
     │  ├─ MockPermitToken.sol
     │  ├─ MockRevertingAggregator.sol
     │  ├─ MockSimpleStrategy.sol
     │  ├─ MockTokens.sol
     │  └─ MockUniswapV3Router.sol
     └─ octant/
        ├─ AaveYieldDonatingStrategy.t.sol
        └─ AgentOrchestrator.t.sol
```

---

## Build, test, and deploy

### Prereqs

* Foundry (`forge`, `cast`), Node 18+
* RPC URL(s): mainnet/Tenderly fork
* `.env` sample:

```
RPC_URL="<your fork/mainnet rpc>"
ETHERSCAN_API_KEY="<optional>"
```

### Build

```bash
forge build -vvv -via-ir
```

### Test (local)

```bash
forge test -vvv -via-ir
```

### Deploy (Tenderly fork / mainnet‑fork)

> **Note:** I avoided pre‑deploy chain simulation to prevent wrong addresses.

```bash
source .env
forge script script/DeployAjey.s.sol:DeployAjey \
  --rpc-url $RPC_URL \
  --broadcast \
  --skip-simulation \
  -vvv
```

### Minimal demo flow (what judges should see)

1. **Deposit** USDC (or ETH) into the corresponding vault (ERC‑4626).
2. Agent executes **supplyToAave** on that vault.
3. After a short interval, agent **realizes profit** and disburses donations per preset (Crypto‑Maxi/Balanced/Humanitarian‑Maxi).
4. Agent detects a better market (e.g., DAI → USDT) → calls **orchestrator** to migrate shares with whitelisted swap & slippage guard.
5. Repeat; **withdraw** principal to show user PPS remains stable until donation buffer is exhausted.

---

## Security & assumptions

* **AccessControl**: admin + `AGENT_ROLE` for orchestrated actions.
* **Whitelisted aggregator only** for swaps; **minAmountOut** + **deadline** required.
* **No custody concentration**: the orchestrator only *moves* funds between vaults; funds remain in vaults and Aave.
* **Audit status:** hackathon prototype; unaudited. Use on testnets/forks only for demos.

---

## Environment & ops checklist

* Works on **Ethereum mainnet fork** (Tenderly) for the hackathon demo.
* Uses only **public, open‑source** dependencies.
* **MIT** license (or similar OSI).
* Includes **video link** and **track selection** in the Devfolio submission.

---

## License

MIT — see `LICENSE`.

---

## Acknowledgments / attributions

* Octant v2 YDS architecture & docs
* Aave v3 ERC‑4626 vaults & documentation
* OpenZeppelin (ERC‑20, AccessControl, SafeERC20)

---

## Appendix — previous iteration vs current (detail)

| Area              | Main (previous)                 | `octant-branch` (current)                                      |
| ----------------- | ------------------------------- | -------------------------------------------------------------- |
| Vault topology    | Early multi‑asset vault concept | **Four single‑asset vaults** (WETH/USDC/USDT/DAI)              |
| Cross‑asset moves | **Agent Reallocator**           | **Agent orchestrator** migrates shares + whitelisted swap      |
| Donation          | NA                              | **Three‑recipient preset mixes** (crypto/humanitarian/hygiene) |
| Aave integration  | Basic supply/withdraw hooks     | **Explicit helper calls** gated to agent; per‑asset deployment |
| Deployment        | Standard script                 | **`--skip-simulation`** to fix wrong addresses on fork         |
| Code layout       | Flatter structure               | `src/core/*`, `src/interfaces/*` + roles/permits               |
| Risk model        | N/A                             | Slippage/deadline guards; role‑gated ops                       |

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
