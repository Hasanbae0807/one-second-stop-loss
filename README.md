# One-Second Stop-Loss

**A stop-loss that watches the market for you — no bot, no server, no keys online.**

Built for the **Reactive Omni Buildathon** (track: **Every Second Counts**; the same
design also fits **Set It and Forget It**).

## The problem

Every stop-loss today needs something awake and trusted: an exchange holding your
funds, a keeper bot with your keys on a server, or you, watching charts at 3 a.m.
Bots die, servers get hacked, people sleep.

## The fix

Reactive contracts invert the flow: instead of polling the chain, the chain calls
the contract. One-Second Stop-Loss registers your stop **on-chain**, and Reactive
Network watches every price event for you — the moment the price crosses your
trigger, the network itself closes your position. On Reactive Omni the full loop
(origin event → reaction → destination callback) completes in about a second,
and the demo below shows both legs landing in ~12 seconds on public testnets.

## How it works

```
Base Sepolia (origin + destination)              Reactive Lasna
┌──────────────────────────────┐                 ┌────────────────────────┐
│ GuardianVault                │  StopRegistered │ StopLossReactive       │
│  deposit(token, amt, stop) ──┼────────────────►│  records the stop      │
│                              │   PriceUpdated  │  (from events only)    │
│ PriceOracle                  │                 │                        │
│  setPrice(token, price) ─────┼────────────────►│  price ≤ trigger?      │
│                              │                 │        │               │
│  callback(sender, posId) ◄───┼── requestCallback (system contract)      │
│  position closed, funds out  │                 └────────────────────────┘
└──────────────────────────────┘
```

Contracts:

- **`GuardianVault`** (Base Sepolia) — custodies positions. `deposit()` announces
  the stop by emitting `StopRegistered`; `callback()` closes a position, but only
  accepts calls from the chain's Callback Proxy carrying the reactive contract's
  injected sender address (`AbstractCallback.onlyCallbackSender` + proxy check).
  `withdraw()` is an always-available manual escape hatch and emits
  `StopCancelled`.
- **`StopLossReactive`** (Reactive Lasna) — built on **reactive-lib-omni**. It
  subscribes (via the system contract `0x8888…8888`) to `StopRegistered`,
  `StopCancelled`, and `PriceUpdated`, builds its stop registry purely from
  those events, and on a breach calls `requestCallbackV_1_0()` to instruct the
  vault to close. Stops are one-shot: a triggered stop deactivates itself.
- **`PriceOracle`** + **`MockERC20`** (Base Sepolia) — demo stand-ins for a real
  price feed and asset, so anyone can drive the loop end-to-end.

Why stops travel as **events**: the executing reactive contract builds its state
from the events it processes, so configuration written by direct calls never
reaches it. Announcing stops as origin-chain events is the canonical Reactive
pattern — and it makes every stop publicly auditable.

Funding model (Omni): each contract pays its own way from its own balance via
`AbstractPayer` — seed the reactive contract with lREACT at deployment and top
the vault up with a little destination-chain ETH (plus a `depositTo()` reserve
at the Callback Proxy). No debt accrues silently: both contracts expose
`coverDebt()`.

## Live demo (testnet, verified 2026-11-18)

Deployment (v3, Reactive Omni):

| Contract | Chain | Address |
|---|---|---|
| StopLossReactive | Reactive Lasna (5318007) | `0x867258360f883b57832469ad5dd6cf12e64be92e` |
| GuardianVault | Base Sepolia (84532) | `0x3c8dd39331bd49cfc7582fca55bd4fc66150553e` |
| PriceOracle | Base Sepolia (84532) | `0xb3b85ab3b03f2b9746b9351e4e3967f206acadde` |
| MockERC20 (MOCK) | Base Sepolia (84532) | `0xf66660fb868a7183728801826bbf02d58cecc331` |

Demo run: deposit 100 MOCK with a $90 stop at price $100 → stop recorded on
Lasna in ~12 s → price $95: nothing happens → price $89: position closed by
callback in ~12 s, 100 MOCK returned. Closing tx (Base Sepolia):
`0x9abe32b2b9f85c367765c9fc0117d8af4005558d114da357760305327c67d7c9`.

To reproduce: `setPrice(MOCK, 100e18)` → `approve` + `deposit(MOCK, 100e18, 90e18)`
→ watch `StopLossReactive.getStop(0)` on Lasna → `setPrice(MOCK, 89e18)` → watch
`GuardianVault.getPosition(0)` close on Base Sepolia.

## Run the tests

```bash
forge test   # 14 tests: full loop, cancel path, multi-stop, callback auth…
```

The suite etches a mock system contract at the real system address
(`0x8888…8888`) and drives `react()` exactly the way the network does.

## Deploy (from scratch)

```bash
# 1. Origin contracts on Base Sepolia (token + oracle)
forge script script/DeployBaseSepolia.s.sol --broadcast \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_KEY

# 2. Reactive contract on Lasna (seeded with 0.1 lREACT)
ORACLE_ADDR=0x... forge script script/DeployLasna.s.sol --broadcast \
  --rpc-url https://lasna-rpc.rnk.dev/ --private-key $DEPLOYER_KEY

# 3. Vault on Base Sepolia (needs the reactive address from step 2)
DEPLOY_VAULT=1 REACTIVE_ADDR=0x... forge script script/DeployBaseSepolia.s.sol \
  --broadcast --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_KEY

# 4. Wire + fund: initialize(vault) on Lasna; top up the reactive contract's
#    lREACT balance by plain transfer; depositTo(vault) at the Base Sepolia
#    Callback Proxy (0x476F44b11F5C942c58f4c8E3d0300E5710743585) and send the
#    vault a little ETH.
```

Faucets: Lasna — https://lasna.faucet.reactive.xyz/ · Base Sepolia — any public
Base Sepolia ETH faucet.

## Production path

Swap `PriceOracle` for a real feed (e.g. a DEX pair's `Sync` events or a
Chainlink aggregator), and make `GuardianVault.callback()` exit through a DEX
into a stablecoin instead of releasing the custodied asset. The reactive core —
subscriptions, event-built state, one-shot triggers, authenticated callbacks —
stays exactly as it is.

## License

MIT (demo contracts). reactive-lib-omni is vendored under `lib/` per its upstream
terms.
