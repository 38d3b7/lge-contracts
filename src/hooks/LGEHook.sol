// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";

import {LGEToken} from "../LGEToken.sol";
import {LGECalculationsLibrary} from "../libraries/LGECalculationsLibrary.sol";

contract LGEHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    error CannotDirectlyInitialize();
    error CannotWithdrawETH();
    error CannotClaimLiquidity();
    error NoETHDeposited();
    error WithdrawTooEarly();
    error SwapForbidden();
    error LGEFinished();
    error WrongPool();
    error InvalidPrice();
    error InvalidAmount();

    event LGEFailed();

    struct UserState {
        uint256 ethToLiquidityDeposited;
        uint256 remainingEthDeposited;
        uint256 tokensToLiquidity;
    }

    uint256 public constant STREAM_BLOCKS = 5000;
    uint256 public constant TOTAL_BLOCKS = 6000;
    int24 public constant TICK_SPACING = 1;
    uint24 public constant FEE = 10000;

    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    LGEToken public immutable token;

    uint256 public immutable startBlock;
    uint256 public immutable minTokenPrice;
    uint256 public immutable maxTokenPrice;

    PoolKey public poolKey;

    mapping(address => UserState) public userStates;

    uint256 public totalEthToLiquidity;
    uint256 public totalLiquidity;
    uint256 public totalTokensClaimed;
    uint256 public totalDeposits;
    uint160 initialSqrtPriceX96;

    uint256 public positionTokenId;

    bool public isLgeFinished;
    bool public isLgeSuccessful;

    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        address token_,
        uint256 startBlock_,
        uint256 minTokenPrice_,
        uint256 maxTokenPrice_
    ) BaseHook(poolManager_) {
        token = LGEToken(token_);
        positionManager = positionManager_;
        permit2 = permit2_;
        startBlock = startBlock_;
        minTokenPrice = minTokenPrice_;
        maxTokenPrice = maxTokenPrice_;
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
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
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

    function getPoolId() external view returns (PoolId) {
        return poolKey.toId();
    }

    function deposit(uint256 amountOfTokens) external payable {
        if (isLgeFinished) revert LGEFinished();

        uint256 cap = token.cap();
        uint256 ethPortion = msg.value / 2;
        uint256 ethPerToken = LGECalculationsLibrary.calculateCurrentTokenPrice(
            minTokenPrice,
            maxTokenPrice,
            block.number,
            startBlock
        );
        uint256 ethExpected = amountOfTokens / ethPerToken;

        if (msg.value != ethExpected * 2) revert InvalidPrice();

        totalTokensClaimed += amountOfTokens;
        totalDeposits += 1;

        userStates[msg.sender].ethToLiquidityDeposited += ethPortion;
        userStates[msg.sender].remainingEthDeposited += ethPortion;
        userStates[msg.sender].tokensToLiquidity += amountOfTokens;

        if (block.number == (startBlock + STREAM_BLOCKS)) {
            isLgeFinished = true;
            if (totalTokensClaimed == cap) {
                isLgeSuccessful = true;

                poolKey = PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(address(token)),
                    fee: FEE,
                    tickSpacing: TICK_SPACING,
                    hooks: IHooks(address(this))
                });
                uint256 averagePrice = FullMath.mulDiv(
                    cap,
                    2,
                    address(this).balance
                );
                initialSqrtPriceX96 = LGECalculationsLibrary.getSqrtPrice(
                    averagePrice
                );

                token.mint(address(this), cap);

                totalEthToLiquidity = address(this).balance / 2;

                uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                    initialSqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
                    TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
                    totalEthToLiquidity,
                    cap
                );

                positionTokenId = positionManager.nextTokenId();

                bytes[] memory params = new bytes[](2);
                bytes[] memory mintParams = new bytes[](2);

                params[0] = abi.encodeWithSelector(
                    IPoolInitializer_v4.initializePool.selector,
                    poolKey,
                    initialSqrtPriceX96
                );

                bytes memory actions = abi.encodePacked(
                    uint8(Actions.MINT_POSITION),
                    uint8(Actions.SETTLE_PAIR)
                );
                mintParams[0] = abi.encode(
                    poolKey,
                    TickMath.MIN_TICK,
                    TickMath.MAX_TICK,
                    liquidity,
                    totalEthToLiquidity,
                    cap,
                    address(this),
                    new bytes(0)
                );
                mintParams[1] = abi.encode(
                    poolKey.currency0,
                    poolKey.currency1
                );

                params[1] = abi.encodeWithSelector(
                    positionManager.modifyLiquidities.selector,
                    abi.encode(actions, mintParams),
                    block.timestamp + 60
                );

                _approveTokensForLiquidity();

                positionManager.multicall{value: totalEthToLiquidity}(params);

                totalLiquidity = liquidity;
            } else {
                emit LGEFailed();
            }
        }
    }

    function withdraw() external {
        if (isLgeSuccessful) revert CannotWithdrawETH();
        if (userStates[msg.sender].ethToLiquidityDeposited == 0)
            revert NoETHDeposited();
        if (block.number < startBlock + STREAM_BLOCKS) {
            revert WithdrawTooEarly();
        }

        uint256 ethToWithdraw = userStates[msg.sender].ethToLiquidityDeposited +
            userStates[msg.sender].remainingEthDeposited;

        payable(msg.sender).transfer(ethToWithdraw);
    }

    function claimLiquidity() external returns (uint256 userPositionId) {
        if (!isLgeSuccessful) revert CannotClaimLiquidity();

        if (block.number < startBlock + STREAM_BLOCKS) {
            revert CannotClaimLiquidity();
        }

        uint256 liquidityToClaim = (userStates[msg.sender]
            .ethToLiquidityDeposited * totalLiquidity) / totalEthToLiquidity;

        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));

        _approveTokensForLiquidity();

        bytes[] memory params = new bytes[](1);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory actionParams = new bytes[](2);

        actionParams[0] = abi.encode(
            positionTokenId,
            liquidityToClaim,
            0,
            0,
            bytes32(0)
        );

        actionParams[1] = abi.encode(
            poolKey.currency0,
            poolKey.currency1,
            address(this)
        );

        params[0] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(actions, actionParams),
            block.timestamp + 60
        );

        positionManager.multicall(params);

        uint256 ethAmount = address(this).balance - ethBefore;
        uint256 tokenAmount = token.balanceOf(address(this)) - tokenBefore;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            ethAmount,
            tokenAmount
        );

        userPositionId = positionManager.nextTokenId();

        bytes[] memory userParams = new bytes[](1);
        bytes[] memory mintParams = new bytes[](2);

        bytes memory userActions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        mintParams[0] = abi.encode(
            poolKey,
            TickMath.MIN_TICK,
            TickMath.MAX_TICK,
            liquidity,
            ethAmount,
            tokenAmount,
            msg.sender,
            new bytes(0)
        );
        mintParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        userParams[0] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(userActions, mintParams),
            block.timestamp + 60
        );

        _approveTokensForLiquidity();
        positionManager.multicall{value: ethAmount}(userParams);
    }

    function _approveTokensForLiquidity() internal {
        token.approve(address(permit2), type(uint256).max);
        IAllowanceTransfer(address(permit2)).approve(
            address(token),
            address(positionManager),
            type(uint160).max,
            type(uint48).max
        );
    }

    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160
    ) internal override returns (bytes4) {
        if (sender == address(positionManager) && isLgeSuccessful) {
            require(
                key.currency0 == Currency.wrap(address(0)) &&
                    key.currency1 == Currency.wrap(address(token)) &&
                    key.hooks == IHooks(address(this)),
                "Wrong pool configuration"
            );
            return this.beforeInitialize.selector;
        }
        revert CannotDirectlyInitialize();
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (PoolId.unwrap(poolKey.toId()) != PoolId.unwrap(key.toId())) {
            revert WrongPool();
        }

        if (startBlock + TOTAL_BLOCKS < block.number) revert SwapForbidden();

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    receive() external payable {}

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
