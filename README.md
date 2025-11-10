# AJEY — Automated Multi‑Asset Yield → Public Goods (Octant v2 + Aave v3)

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
