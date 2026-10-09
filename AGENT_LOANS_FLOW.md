# Agent Loans Flow

Design for combining the LGE with agent loans. Not implemented yet.

The agent's vesting grant in `VestingVault` is the collateral, and loans are in native USDC. The mechanism is adapted from the Solana program at [fraserbrownirl/agent-loans](https://github.com/fraserbrownirl/agent-loans), with the fixes from its Soken security review (v0.9, 4 October 2026) built in.

## Who is involved

- **Agent**: launched the token, owns the vesting grant, borrows.
- **Lender**: any wallet that funds an offer.
- **Operator**: can rotate the agent's address, as today.
- **Contracts**: `LGEManager`, the token's `LGEHook`, `VestingVault`, and the new `AgentLoans`.

## Loan states

```
Idle ⇄ Offered → Active → Idle (repaid)
                        ↘ Defaulted (final)
```

An offer that passes its expiry counts as Idle with no transaction needed.

## 1. Launch

1. The agent calls `deployToken` as today, with extra settings:
   - the project reserve: the percentage of tokens reserved for the project, which goes to `VestingVault` (today this is hardcoded at 5%);
   - whether loans are enabled, the minimum and maximum principal, the minimum loan term and the maximum fee.
2. `LGEManager` deploys the token and hook and records the token as a genuine LGE token.
3. These settings are fixed forever for that token, so sale participants can see them before depositing.

## 2. LGE succeeds and the grant is created

The token supply is split in two by the project reserve the agent set at launch:

- **Sale supply** = cap minus the reserve. This is what the auction sells.
- **Project reserve** = the reserved percentage of the cap. It is never sold.

1. The auction sells the whole sale supply. That is the success condition (today it is the whole cap).
2. In the same transaction the hook mints the full cap and then:
   - puts the sale supply and half the USDC raised into the Uniswap v4 pool, as one full-range position the hook holds;
   - sends the project reserve straight to `VestingVault` as the agent's grant, with a cliff of at least 365 days;
   - sends the whole treasury (the other half of the USDC raised) to `InferenceEscrow`.
3. The hook buys nothing from the pool, so the pool opens at the average auction price and stays there until people trade.
4. The grant is the loan collateral, and the only collateral. The loan state for the token is **Idle**.

If the sale does not sell out, nothing is minted and every buyer can withdraw 100% of their USDC, as today.

### What changes in `LGEHook`

- New constructor parameter: the project reserve, as a percentage of the cap. It replaces the hardcoded 5%.
- The sale stops and succeeds at the sale supply instead of the cap.
- The pool receives the sale supply instead of the cap.
- The reserve goes directly to the vault; the whole treasury goes to `InferenceEscrow`.
- The treasury buy is removed entirely: `treasuryBuy`, the pending-buy retry and the swap callback it used.

A reserve of 0 means no grant and nothing to borrow against.

## 3. The agent publishes an offer

1. The agent calls `publishOffer` with principal, repay amount, term and offer expiry.
2. `AgentLoans` checks:
   - the caller is the token's current agent;
   - the terms are inside the bounds set at launch;
   - the expiry is at most 7 days away;
   - expiry plus term ends before the grant finishes vesting;
   - there is collateral left in the grant.
3. The offer gets a new nonce and the state becomes **Offered**.
4. While the offer is live, the agent cannot claim from the vault.
5. The agent can call `withdrawOffer` to go back to **Idle**.

## 4. A lender fills it

1. The lender calls `fill` with the nonce they saw and sends exactly the principal.
2. `AgentLoans` checks that the offer has not expired and the nonce matches, so the lender cannot be given different terms than they read.
3. The lender is recorded, maturity is set to now plus the term, and the state becomes **Active**.
4. The principal is credited to the agent, who collects it with `withdraw`.
5. The grant stays in the vault. Claims remain blocked.

## 5a. The loan is repaid

1. Anyone calls `repay` for the token and sends USDC; it can be in parts.
2. Each payment is credited to the lender, up to what is owed. Anything over is credited back to the payer.
3. When the full repay amount is reached, the loan terms are cleared and the state returns to **Idle**.
4. The lender collects with `withdraw`.
5. The agent can claim vested tokens again and can publish a new offer.
6. Late payment is accepted after maturity, as long as the lender has not yet declared default.

## 5b. The loan defaults

1. Maturity passes and the loan is not fully repaid.
2. The lender calls `claimDefault`.
3. `AgentLoans` works out the unpaid share. For example, with 1,050 USDC owed and 420 repaid, 60% is unpaid.
4. The vault moves that share of the agent's remaining grant to the lender, as a grant on the same cliff and duration. In the example the lender gets 60% and the agent keeps 40%.
5. The state becomes **Defaulted**, which is final: no further loans on this grant.
6. The lender still collects the 420 USDC already repaid, and claims the seized tokens from the vault as they vest.
7. The agent claims what is left of its grant on the normal schedule.

## Things that can happen along the way

- **Agent rotation:** the operator rotates the agent as today. The grant moves to the new address and the loan moves with it; the new agent owes the repayment and controls future offers.
- **Compromised agent key:** because anyone can repay, the operator or the new agent can clear a loan a bad key took out before it matures.
- **Uncooperative counterparty:** neither side can block the other. Every step only updates balances, and each party withdraws for itself.
- **Loans not enabled:** if the agent did not enable loans at launch, the vault behaves exactly as it does now.

## Design rules

- **Seizure is a vesting slice, not liquid tokens.** Otherwise an agent could fill its own offer, default, and receive its grant before the 365-day cliff.
- **Pull payments only.** `fill`, `repay` and `claimDefault` never pay a counterparty directly, so a reverting or blocked address cannot stall the loan.
- **Term runs from the fill**, not from when the offer was published, so the borrower always gets the agreed time to repay.
- **Only LGE tokens are collateral.** `LGEManager` keeps a registry of the tokens it deployed.
- **No admin.** `AgentLoans` has no owner and is not upgradeable.
- **No protocol fee** on loans.
