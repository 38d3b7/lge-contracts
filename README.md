
# LGE Contracts
This repository contains smart contracts for the LGE (Liquidity Generation Event) mechanism for new tokens on Uniswap v4. It enables projects to bootstrap liquidity through a time-based token sale where the price gradually decreases over time, ensuring fair distribution and liquidity provision.
**We have not used EigenLayer or Fhenix in this hook.**

## Architecture
### Core Components
1. **LGEManager.sol** - Factory Contract.
The main entry point for deploying new LGE campaigns.
*Key Features:*
	- Deploys an ERC20 token;
	- Deploys a hook along with the token;
2. **LGEToken.sol** - ERC20 Token.
A capped ERC20 token with administrative functions.
*Key Features:*
	- Fixed total supply - 17,745,440,000 tokens, 18 decimals;
	- Burnable tokens;
	- Capped total supply;
	- Admin-controlled metadata and image updates;
	- Minting restricted to the LGE hook only;
3. **LGEHook.sol** - Uniswap v4 Hook.
The core LGE mechanism that handles deposits, liquidity provision, and pool creation.
*Key Features:*
	- LGE duration: stream period: 5,000 blocks, total restricted period: 6,000 blocks (swaps forbidden for first 1,000 blocks after LGE);
	- deposit() function: users deposit ETH to purchase tokens at the calculated price;
	- withdraw() function: retrieve ETH if LGE fails;
	- claimLiquidity() function: claim LP position after successful LGE;
4. **LGECalculationsLibrary.sol** - Price Calculations.
Helper library for price and liquidity calculations.
*Key Features:*
	- Calculates token price based on min/max values, current block, and a start block;
	- Calculates sqrt for the pool initialisation;
### LGE Mechanism
#### Phase 1: Token Sale (Blocks 0-5,000)
1.  **Dynamic Pricing**: Token price decreases linearly from `maxTokenPrice` to `minTokenPrice` over the stream period
2.  **Deposit Structure**: Users deposit ETH where:
    -   50% goes toward liquidity provision
    -   50% remains for the future purposes
3.  **Fair Distribution**: Price decline ensures early buyers don't have unfair advantage
#### Phase 2: LGE Conclusion (Block 5,000)
**Success Criteria**: All tokens (cap amount) must be sold.

If successful:
-   Uniswap v4 pool is automatically created
-   Initial liquidity is added (50% of ETH + all tokens)
-   Pool parameters:
    -   Fee: 1% (10,000 basis points)
    -   Tick spacing: 1
    -   Full range liquidity (MIN_TICK to MAX_TICK)

If failed:
-   Users can withdraw their deposited ETH

## Open Issues
The current open issue is the precision loss that happens during minting a position. It uses exact half of the ETH needed to mint a liquidity, however it also uses smaller amount of tokens. Ideally, what we want to achieve is using exact amount of ETH + exact amount of tokens to create a liquidity position. We're currently investigating the best way to achieve this with minimal precision loss.
## Contract Deployments
**Ethereum Sepolia Testnet (not verified)**
| Contract Name | Contract Address |
|--|--|
| LGEManager | 0x80b151Bd4Ed017692F395E2F0395f0c84071A56B |
| LGECalculationsLibrary | 0x74C6B2321BeD36FB92E9c88fc33D2A77ED7bBe57 |
