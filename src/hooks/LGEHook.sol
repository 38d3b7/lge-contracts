// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {LGEToken} from "../LGEToken.sol";
import {LGECalculationsLibrary} from "../libraries/LGECalculationsLibrary.sol";
import {CurrencySettler} from "./utils/CurrencySettler.sol";

contract LGEHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;

    error AlreadyInitialized();
    error PoolNotInitialized();
    error SwapForbidden();
    error LGEFinished();
    error WrongPool();
    error InvalidPrice();

    event HookModifyLiquidity(
        bytes32 indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1
    );

    struct CallbackData {
        address sender;
        ModifyLiquidityParams params;
    }

    struct UserState {
        uint256 ethToLiquidityDeposited;
        uint256 remainingEthDeposited;
        uint256 tokensToLiquidity;
        uint256 liquidityEscrowed;
    }

    uint256 public constant STREAM_BLOCKS = 5000;
    uint256 public constant TOTAL_BLOCKS = 6000;
    uint256 public constant TOTAL_TOKENS_TO_STREAM = 17_745_440_000e18;

    LGEToken public immutable token;
    uint256 public immutable startBlock;
    int24 public immutable baseTick;

    PoolKey public poolKey;

    mapping(address => UserState) public userStates;

    uint256 public totalEthDeposited;
    uint256 public totalLiquidityEscrowed;

    bool public isLgeFinished;
    bool public isLgeSuccessful;

    constructor(
        IPoolManager poolManager_,
        address token_,
        uint256 startBlock_,
        uint160 initialSqrtPriceX96_
    ) BaseHook(poolManager_) {
        token = LGEToken(token_);
        startBlock = startBlock_;
        baseTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96_);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function addLiquidity() external payable {
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            poolKey.toId()
        );

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        if (isLgeFinished) revert LGEFinished();

        uint256 ethPortion = msg.value / 2;
        uint256 batchSize = tokensAvailable();

        require(batchSize > 0, "No tokens available");

        (uint256 ethExpected, ) = LGECalculationsLibrary.getETHPriceFromRange(
            batchSize,
            baseTick,
            currentTick,
            poolKey.tickSpacing
        );
        require((ethPortion == ethExpected), "ETH portion mismatch");

        (int24 tickLower, int24 tickUpper, ) = LGECalculationsLibrary
            .ticksForClaim(
                batchSize,
                baseTick,
                currentTick,
                poolKey.tickSpacing
            );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethPortion,
            batchSize
        );

        token.mint(address(this), batchSize);
        token.approve(address(poolManager), batchSize);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(
            abi.encode(params)
        );

        BalanceDelta principalDelta = callerDelta - feesAccrued;
        uint256 ethUsed = principalDelta.amount0() < 0
            ? uint256(uint128(-principalDelta.amount0()))
            : 0;
        uint256 tokensUsed = principalDelta.amount1() < 0
            ? uint256(uint128(-principalDelta.amount1()))
            : 0;

        userStates[msg.sender].ethToLiquidityDeposited += ethUsed;
        userStates[msg.sender].remainingEthDeposited += (msg.value - ethUsed);
        userStates[msg.sender].tokensToLiquidity = tokensUsed;
        userStates[msg.sender].liquidityEscrowed += uint256(liquidity);

        totalEthDeposited += msg.value;
        totalLiquidityEscrowed += tokensUsed;
    }

    function _modifyLiquidity(
        bytes memory params
    )
        internal
        virtual
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        (callerDelta, feesAccrued) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        msg.sender,
                        abi.decode(params, (ModifyLiquidityParams))
                    )
                )
            ),
            (BalanceDelta, BalanceDelta)
        );
    }

    function unlockCallback(
        bytes calldata rawData
    )
        public
        virtual
        override
        onlyPoolManager
        returns (bytes memory returnData)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        data.params.salt = keccak256(abi.encode(data.sender, data.params.salt));

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager
            .modifyLiquidity(poolKey, data.params, "");

        BalanceDelta principalDelta = callerDelta - feesAccrued;

        if (principalDelta.amount0() < 0) {
            // If amount0 is negative, send tokens from the sender to the pool
            poolKey.currency0.settle(
                poolManager,
                address(this),
                uint256(int256(-principalDelta.amount0())),
                false
            );
        } else {
            // If amount0 is positive, send tokens from the pool to the sender
            poolKey.currency0.take(
                poolManager,
                address(this), // should be data.sender?
                uint256(int256(principalDelta.amount0())),
                false
            );
        }

        if (principalDelta.amount1() < 0) {
            // If amount1 is negative, send tokens from the sender to the pool
            poolKey.currency1.settle(
                poolManager,
                address(this),
                uint256(int256(-principalDelta.amount1())),
                false
            );
        } else {
            // If amount1 is positive, send tokens from the pool to the sender
            poolKey.currency1.take(
                poolManager,
                address(this), // should be data.sender?
                uint256(int256(principalDelta.amount1())),
                false
            );
        }

        _handleAccruedFees(data, callerDelta, feesAccrued);

        emit HookModifyLiquidity(
            PoolId.unwrap(poolKey.toId()),
            data.sender,
            principalDelta.amount0(),
            principalDelta.amount1()
        );

        // Return both deltas so that slippage checks can be done on the principal delta
        return abi.encode(callerDelta, feesAccrued);
    }

    function _handleAccruedFees(
        CallbackData memory data,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued
    ) internal virtual {
        // Send any accrued fees to the sender
        poolKey.currency0.take(
            poolManager,
            data.sender,
            uint256(int256(feesAccrued.amount0())),
            false
        );
        poolKey.currency1.take(
            poolManager,
            data.sender,
            uint256(int256(feesAccrued.amount1())),
            false
        );
    }

    function tokensAvailable() public view returns (uint256 batchSize) {
        if (block.number < startBlock) {
            return 0;
        }

        uint256 blocksPassed = block.number - startBlock;

        uint256 totalTokensStreamed;
        if (blocksPassed >= STREAM_BLOCKS) {
            totalTokensStreamed = TOTAL_TOKENS_TO_STREAM;
        } else {
            totalTokensStreamed =
                (TOTAL_TOKENS_TO_STREAM * blocksPassed) /
                STREAM_BLOCKS;
        }

        batchSize = totalTokensStreamed - totalLiquidityEscrowed;
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal override returns (bytes4) {
        // Check if the pool key is already initialized
        if (address(poolKey.hooks) != address(0)) revert AlreadyInitialized();

        // Store the pool key to be used in other functions
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (PoolId.unwrap(poolKey.toId()) != PoolId.unwrap(key.toId()))
            revert WrongPool();

        if (startBlock + TOTAL_BLOCKS < block.number) revert SwapForbidden();

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    // function _beforeAddLiquidity(
    //     address sender,
    //     PoolKey calldata key,
    //     ModifyLiquidityParams calldata params,
    //     bytes calldata
    // ) internal override returns (bytes4) {
    //     require(block.number >= startBlock, "LGE not started");
    //     require(!isLgeFinished, "LGE finished");

    //     uint256 tokensAvailable = tokensAvailable();

    //     // TODO: tick enforcement and pricing logic

    //     return BaseHook.beforeAddLiquidity.selector;
    // }

    // function _afterAddLiquidity(
    //     address sender,
    //     PoolKey calldata key,
    //     ModifyLiquidityParams calldata params,
    //     BalanceDelta delta,
    //     BalanceDelta feesAccrued,
    //     bytes calldata hookData
    // ) internal override returns (bytes4, BalanceDelta) {
    //     // TODO: track ETH deposits if needed

    //     return (this.afterAddLiquidity.selector, toBalanceDelta(0, 0));
    // }
}
