# LGE Project Context for Development

## Quick Reference
This is a Liquidity Generation Event (LGE) system using Uniswap v4 hooks to create fair token launches through Dutch auctions. If the LGE fails, users get 100% refund. If it succeeds, automatic liquidity pool creation.

## Core Business Logic

### The Dutch Auction Flow
1. Price starts HIGH (maxTokenPrice) 
2. Decreases linearly to LOW (minTokenPrice) over 5,000 blocks
3. Users deposit ETH at any point during auction
4. Their token amount = ETH / current_price_at_block

### Capital Split (Critical)
When users deposit ETH:
- **50% → Liquidity Pool**: Paired with tokens for Uniswap v4
- **50% → Project Treasury**: For operations/development

### Success/Failure Logic
- **SUCCESS**: All 17,745,440,000 tokens sold → Create pool → Users get LP tokens
- **FAILURE**: Not all tokens sold → Users withdraw ETH (100% refund)

## Architecture Decisions

### Why Uniswap v4 Hooks?
- Allows custom logic during pool lifecycle
- Single transaction for LGE → Pool creation
- Gas efficient through singleton architecture
- Native ETH support (no WETH wrapping)

### Why Dutch Auction?
- Prevents bot sniping (no advantage to being first)
- Natural price discovery
- Fair for all participants
- No gas wars

### Why 100% Token in LGE?
- Ensures maximum liquidity depth
- No team tokens to dump
- Aligned incentives
- Trust through transparency

## Current Technical Challenges

### Precision Loss Issue (ACTIVE PROBLEM)
When creating the liquidity position, we have a mismatch:
- We use exactly 50% of ETH ✓
- But slightly less tokens than optimal ✗
- Results in ~0.1-0.5% inefficiency

**Why it matters**: Leftover tokens = less liquidity than intended

**Investigating**: 
- Tick math rounding strategies
- Using sqrtPriceX96 adjustments
- Slippage tolerance implementation

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

## Testing Focus Areas

When testing changes, prioritize:
1. Edge cases at block boundaries (0, 5000)
2. Precision in token/ETH calculations
3. Reentrancy in deposit/withdraw
4. Pool initialization parameters
5. LP token distribution accuracy

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