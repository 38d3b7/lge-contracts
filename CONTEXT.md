# LGE Project Context for Development

## Quick Reference
This is a Token Generation Event (TGE) system using a Uniswap v4 hook. It is a liquidity-first idea (Uniswap LP) and therefore called LGE (Liquidity Generation Event). If the LGE fails, users get 100% refund. If it succeeds, a liquidity pool is created automatically and participants can claim their LP tokens.

## Core Business Logic

### The Dutch Auction Flow
1. Price starts HIGH (maxTokenPrice) 
2. Decreases linearly to LOW (minTokenPrice) over 5,000 blocks
3. Users deposit ETH at any point during auction which is mapped to their wallet and later defines their LP allocation. The system means there is no incentive for gas wars or bot sniping.
4. Their token amount = ETH / current_price_at_block

### Capital Split (Critical)
When users deposit ETH:
- **50% → Liquidity Pool**: Paired with tokens for Uniswap v4
- **50% → Project Treasury**: For operations/development

### Success/Failure Logic
- **SUCCESS**: All 17,745,440,000 tokens sold → Create pool → Users get LP tokens
- **FAILURE**: Not all tokens sold → Users withdraw ETH (100% refund)

## Critical Integration Points

### LGEHook.sol ↔ PoolManager
- Hook must implement IHooks interface
- Called during: initialize, beforeSwap, afterSwap
- Must return specific deltas for accounting

### LGEToken.sol ↔ LGEHook.sol
- ONLY hook can mint tokens (security critical)
- Minting happens during deposit()
- Total supply capped at creation

### Price Calculation
```solidity
// This is THE formula - don't change without understanding impact
price = maxPrice - ((maxPrice - minPrice) * (block.number - startBlock) / 5000)
```

## State Machine

```
DEPLOYED → ACTIVE (5000 blocks) → SUCCESS → LIQUIDITY_ADDED
                                ↘ FAILED → WITHDRAWABLE
```

## Security Assumptions

1. **No admin mint** after LGE (hard guarantee)
2. **Liquidity locked** forever in pool
3. **Refunds always available** if failed
4. **No price manipulation** possible during auction
5. **MEV resistant** through auction design

## Key Invariants (NEVER BREAK THESE)

1. `totalTokensSold <= TOKEN_CAP`
2. `if (!success) then withdrawableETH[user] == depositedETH[user]`
3. `poolLiquidity == 0.5 * totalETHRaised` (minus precision loss)
4. `priceAtBlockN >= priceAtBlockN+1` (price only decreases)

## Common Pitfalls

- **Don't** assume block.number increments by 1 (can skip blocks)
- **Don't** use floating point math (everything in uint256)
- **Don't** forget to check hook permissions flags
- **Don't** modify core auction logic without updating tests
- **Don't** assume gas prices (v4 is cheaper but still significant)

## External Dependencies

- Uniswap v4 Core (PoolManager, Hooks interface)
- OpenZeppelin (ERC20, Ownable, ReentrancyGuard)
- Foundry for testing framework

## Notes for Frontend Integration

- Users need 2 transactions: approve() then deposit()
- Show real-time price updates (block-based)
- Clear success/failure state indication
- LP claim might be separate transaction
- Handle wallet disconnections during LGE

## Performance Considerations

- Deposit gas: ~150k-200k
- Withdraw gas: ~80k-100k  
- Pool creation: ~500k+ (one-time)
- Use multicall for batch reads
- Cache price calculations client-side
