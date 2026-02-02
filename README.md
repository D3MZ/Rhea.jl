# Rhea [BETA - NOT STABLE NOT COMPLETE]

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://D3MZ.github.io/Rhea.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://D3MZ.github.io/Rhea.jl/dev/)
[![Build Status](https://github.com/D3MZ/Rhea.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/D3MZ/Rhea.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/D3MZ/Rhea.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/D3MZ/Rhea.jl)
[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![PkgEval](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/P/Rhea.svg)](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/P/Rhea.html)


Online RL Trading system that's broker, agent, and reward agnostic.

> "When Cronus learnt that he was destined to be overthrown by one of his children like his father before him, he swallowed all the children Rhea bore as soon as they were born. When Rhea had her sixth and final child, Zeus, she spirited him away and hid him in Crete, giving Cronus a rock to swallow instead."

...Sometimes she'll give you rocks.

## GOTCHAS
OANDA Broker's hedge position will be collapsed into a single direction. So if it's 3 longs and 2 shorts, it'll be collapsed to 1 long. Therefore, to "close" this position, it'll only short 1 unit, but this will register as 3 longs and 3 shorts in OANDA. This may impact margin calculations.

## Features
- Fast/Low-footprint: Optimized core loop using Multiple Dispatch and `StaticArrays` to minimize allocations and maximize throughput.
- Mostly native Julia.
- Multi-Instrument Support: Native handling of multiple assets with independent base currencies, margins, fees, tick sizes and minimum order sizing.
- Data download helper from Polygon providers.
- Broker, Reward, and Agent agnostic.

## Testing
## test/oanda_live.jl
- [x] cash is correctly tracked by the state vs Oanda's getcash()
- [x] Weights -> Accepted positions:
 - [x] [1,0] -> [-1,0] (100% in a single instrument then to -100%; 0% in avaiable margin / cash.)
 - [x] [-0.5,0.5,0] -> [0.5,-0.5,0] (100% used on 2 instruments, then flip those signs)

## test/core.jl
- [x] Create and add this file to runtests.jl
- [x] Deterministic setup (fixed price, zero spread, zero commission)
- [x] Single-instrument cash invariants
  - [x] Cash on `State(broker)` init
  - [x] Cash after opening long (+10 units)
  - [x] Cash after reducing long (+10 → +7)
  - [x] Cash after crossing zero (+7 → −1)
  - [x] Cash after closing position (−1 → 0)
- [x] Flat position restores initial cash (constant price)
- [x] Test impact on cash when introducing spread, commission, price change.
- [x] Move "Position math" testset here from runtests.jl
- [x] Test nlv
- [x] Test usedmargin
- [x] Test availablemargin

## Performance
- [x] Reduce allocations maybe refactoring into a Matrixes, or SVector State maybe? test if foldl allocs 

# Project Structure

- [ ] **main.jl**
  - [x] Define core type interfaces
  - [x] Main reinforcement learning loop
  - [ ] Standard reporting like Profit, Drawdown, Sharpe graphs.

- [ ] **brokers/**
  - [ ] AbstractBroker.jl: Define broker interface for streaming market data
  - [ ] Data.jl: Stream historical market data
  - [x] RandomWalk.jl: Stream synthetic random-walk price data
  - [ ] RandomPatterns.jl: Stream synthetic data with learnable patterns
  - [ ] Adversarial.jl: Stream data designed to induce losing trades
  - [ ] Agents.jl: Stream agents (via `agents/` folder) to trade against each other
  - [x] OANDA.jl: Live broker implementation using OANDA REST + streaming APIs

- [ ] **agents/**
  - [ ] AbstractAgent.jl: Define agent interface
  - [x] NoTradeAgent.jl: Agent that emits no trades for benchmarking.
  - [x] Random.jl: Emits random valid portfolio weights
  - [x] RuleBased.jl: Deterministic strategies for baselines
  - [x] PatternMatching.jl: Basic pattern matching agent
  - [x] Momentum.jl: Uses rolling returns / trend signals
  - [ ] MeanReversion.jl: Trades against short-term deviations
  - [ ] ContextualBandit.jl: Context-based allocation without transition modeling
  - [ ] LinearTD.jl
    - [ ] Linear value function approximation
    - [ ] Feature-based learning
  - [ ] TDLambda.jl
    - [ ] Value learning with eligibility traces
    - [ ] Suitable for continuing tasks
  - [ ] SARSALambda.jl: On-policy TD control with traces
  - [ ] PolicyGradient.jl: Stochastic policy optimization, Baseline for variance reduction
  - [ ] ActorCritic.jl
    - [ ] Continuous-action actor
    - [ ] Critic with advantage estimation
    - [ ] Optional eligibility traces
  - [ ] DeterministicActorCritic.jl: Deterministic policy, Critic-guided updates
  - [ ] NaturalPolicyGradient.jl: Fisher-preconditioned policy updates
  - [ ] RiskSensitive.jl: CVaR / drawdown-aware objectives
  - [ ] ExpertMixing.jl: Hedge / regret-minimization over strategies
  - [ ] PredictThenOptimize.jl: Forecast returns and risks, Convex portfolio optimization

- [ ] **rewards/**
  - [ ] AbstractReward.jl: Define reward interface
  - [x] LogReturn.jl: Log portfolio returns (scaled by Δt)
  - [ ] DifferentialSharpe.jl: Online Differential Sharpe Ratio (DSR)
  - [ ] RiskAdjustedReturn.jl: Return with volatility penalty
  - [ ] DrawdownPenalty.jl: Penalize running drawdown

- [ ] **tests/runtests.jl**
  - [ ] Run full deterministic test suite
  - [ ] Verify all invariant behaviors pass

- [ ] **tests/agents.jl**: Integration tests applied uniformly to all implementations in `agents/`
  - [ ] Verify each agent stops trading on random walk
  - [ ] Verify each agent learns profitable strategies on patterned data
  - [ ] Verify each agent performance against adversarial streams
  - [ ] Compare all agents head-to-head and rank performance

- [x] **test/brokers.jl**: Integration tests applied uniformly to all implementations in `agents/`
  - [x] DataBroker testset
   - [x] Verify data ordering emited by broker.

# WIP everything below
## How it works
Brokers
- State(Broker) will emit the initial state or current state if Online (ie Oanda).
- State(Broker, Previous State) will emit the state after previous state if the broker is deterministic, otherwise it'll emit the current state.

### DataBroker
Reads a config file like `configs/DataBroker.json` which has the following features:
1. Each instrument is it's own CSV.
2. Every row is turned into a "quote" (Currently a Book type)
3. Uses the dates in the CSV to know which order the quotes should be emitted
4. NOTE: Initial state starts at the latest common timestamp across all instruments (i.e., when every instrument has its first available quote).

Each CSV must be in format of Date,O,H,LC like below:
```csv
timestamp,open,high,low,close,volume,transactions,vwap
2023-10-25T00:00:00.000,0.63601,0.63604,0.6356,0.63586,82,82,0.6359
2023-10-25T00:01:00.000,0.63587,0.63601,0.63585,0.63601,76,76,0.6359
2023-10-25T00:02:00.000,0.63598,0.63608,0.63598,0.63601,77,77,0.636
```
For each row in a CSV it creates a Book with the following features:
1. Price of depth 1
2. Bid = low price
3. Ask = high price
4. Note: Both Bid and Ask prices have zero units for those prices.
- [ ] Estimate Bid and Ask liquidity based on OHLCV structure.


Agents
- Batch learn from rewards
- Generate desired portfolio weight changes given a State

The Core loop:
Pull price from the channel
create a new state from price
get weights from the agent on that state
convert weights to market orders
calculate reward from (state₁, state₂) tuple
learn from the 

Broker state is mutable and updated async
Fast Agents may get identical states in the loop
Slow Agents will slip and lose state summeries.
Offline brokers can 
