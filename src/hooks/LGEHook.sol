// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {LGEToken} from "../LGEToken.sol";
import {LGECalculationsLibrary} from "../libraries/LGECalculationsLibrary.sol";
import {VestingVault} from "../VestingVault.sol";
import {InferenceEscrow} from "../InferenceEscrow.sol";
import {SafeNativeSender} from "../utils/SafeNativeSender.sol";

contract LGEHook is BaseHook, SafeNativeSender {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;

    error CannotDirectlyInitialize();
    error CannotWithdrawUSDC();
    error CannotClaimLiquidity();
    error NoUSDCDeposited();
    error WithdrawTooEarly();
    error LGEFinished();
    error LGEActive();
    error WrongPool();
    error InvalidPrice();
    error InvalidAmount();
    error AlreadyClaimed();
    error TooManyTokens();
    error SwapsNotOpen();
    error ExactOutputSellUnsupported();
    error PartialFill();
    error NothingToClaim();
    error LpLockedForever();
    error ExitDisabled();
    error ExitThresholdNotMet();
    error NoLpShare();
    error NotOperator();
    error InvalidAgent();
    error NotProtocol();
    error BelowMinSweep();
    error TimelockNotElapsed();
    error NoPendingSplits();
    error SplitsMismatch();
    error InvalidSplits();
    error FeeTooHigh();
    error Unauthorized();
    error NoPendingBuy();
    error LGENotSuccessful();

    event Deposited(
        address indexed user,
        uint256 amountOfTokens,
        uint256 amountOfUSDC,
        uint256 usdcContractBalance
    );
    event LGESuccessful(
        PoolKey poolKey,
        uint256 usdcContractBalance,
        uint256 initialSqrtPriceX96,
        uint256 totalUsdcToLiquidity,
        uint128 liquidity
    );
    event LGEFailed();
    event Withdrawn(address indexed user, uint256 amountOfUsdc);
    event FeeCharged(
        uint256 fee,
        uint256 participantShare,
        uint256 agentShare,
        uint256 protocolShare
    );
    event LpShareClaimed(address indexed user, uint256 share);
    event LpLocked(uint256 participantFeesBooked);
    event Exited(
        address indexed user,
        uint256 lpShare,
        uint256 usdcOut,
        uint256 tokensOut,
        uint256 feesPaid
    );
    event ParticipantFeesClaimed(address indexed user, uint256 amount);
    event AgentFeesClaimed(address indexed agent, uint256 amount);
    event ProtocolFeesSwept(uint256 amount);
    event AgentRotated(address indexed oldAgent, address indexed newAgent);
    event TreasuryBuyExecuted(uint256 tokensBought, uint256 usdcSpent, uint256 remaining);
    event TreasuryEscrowed(uint256 amount);
    event SplitsProposed(bytes32 indexed splitsHash, uint64 effectiveAt);
    event SplitsApplied();

    struct UserState {
        uint256 usdcToLiquidityDeposited;
        uint256 remainingUsdcDeposited;
        uint256 tokensToLiquidity;
        uint256 accruedFees;
        uint256 userIndexPaid;
        bool hasClaimedLp;
        bool exited;
    }

    struct HookParams {
        address poolManager;
        address positionManager;
        address permit2;
        address token;
        address agent;
        address operator;
        address protocol;
        address vestingVault;
        address inferenceEscrow;
        uint256 startBlock;
        uint256 streamBlocks;
        uint256 minTokenPrice;
        uint256 maxTokenPrice;
        uint256 exitThreshold;
        uint24 feeBps;
        uint64 vestingCliff;
        uint64 vestingDuration;
    }

    struct Split {
        address to;
        uint16 bps;
    }

    uint24 public constant FEE = 0;
    uint24 public constant MAX_TOTAL_FEE_BPS = 300;
    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_BPS = 500;
    uint256 public constant MIN_SWEEP = 25e18;
    uint256 public constant SCALE = 1e18;
    uint64 public constant SPLITS_TIMELOCK = 48 hours;

    int24 public constant TICK_SPACING = 1;
    int24 public constant MIN_TICK = TickMath.MIN_TICK;
    int24 public constant MAX_TICK = TickMath.MAX_TICK;

    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    LGEToken public immutable token;
    VestingVault public immutable vestingVault;
    InferenceEscrow public immutable inferenceEscrow;

    address public immutable protocol;
    address public immutable operator;
    uint256 public immutable startBlock;
    uint256 public immutable streamBlocks;
    uint256 public immutable minTokenPrice;
    uint256 public immutable maxTokenPrice;
    uint256 public immutable exitThreshold;
    uint256 public immutable cap;
    uint24 public immutable feeBps;
    uint64 public immutable vestingCliff;
    uint64 public immutable vestingDuration;

    address public agent;

    PoolKey public poolKey;
    mapping(address => UserState) public userStates;

    uint256 public totalEthToLiquidity;
    uint256 public totalLiquidity;
    uint256 public totalTokensClaimed;
    uint256 public totalDeposits;
    uint256 public totalUsdcDeposited;
    uint256 public totalUsdcRaised;
    uint160 initialSqrtPriceX96;

    uint256 public positionTokenId;

    bool public isLgeFinished;
    bool public isLgeSuccessful;

    uint256 public participantFeesBooked;
    uint256 public agentAccrued;
    uint256 public protocolAccrued;
    uint256 public feeIndex;
    uint256 public totalActiveWeight;

    mapping(address => uint256) public lpShares;
    bool public lpLocked;

    uint64[30] public feeBucketDay;
    uint256[30] public feeBucketAmt;

    uint256 public treasuryUsdc;
    uint256 public pendingBuy;

    Split[] public splits;
    bytes32 public pendingSplitsHash;
    uint64 public splitsEffectiveAt;

    bool private inHookOp;

    constructor(HookParams memory p) BaseHook(IPoolManager(p.poolManager)) {
        if (p.feeBps > MAX_TOTAL_FEE_BPS) revert FeeTooHigh();
        if (p.operator == address(0)) revert NotOperator();
        token = LGEToken(p.token);
        positionManager = IPositionManager(p.positionManager);
        permit2 = IAllowanceTransfer(p.permit2);
        vestingVault = VestingVault(p.vestingVault);
        inferenceEscrow = InferenceEscrow(p.inferenceEscrow);
        agent = p.agent;
        protocol = p.protocol;
        operator = p.operator;
        startBlock = p.startBlock;
        streamBlocks = p.streamBlocks;
        minTokenPrice = p.minTokenPrice;
        maxTokenPrice = p.maxTokenPrice;
        exitThreshold = p.exitThreshold;
        feeBps = p.feeBps;
        vestingCliff = p.vestingCliff;
        vestingDuration = p.vestingDuration;

        cap = token.cap();

        splits.push(Split({to: p.protocol, bps: uint16(BPS)}));
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
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function getPoolId() external view returns (PoolId) {
        return poolKey.toId();
    }

    function currentTokenPrice() public view returns (uint256) {
        return
            LGECalculationsLibrary.calculateCurrentTokenPrice(
                block.number,
                startBlock,
                streamBlocks,
                minTokenPrice,
                maxTokenPrice
            );
    }

    function deposit(uint256 amountOfTokens) external payable {
        _deposit(amountOfTokens);
    }

    function deposit(
        uint256 amountOfTokens,
        uint256 maxUsdcPerToken,
        uint256 deadline
    ) external payable {
        if (block.timestamp > deadline) revert LGEFinished();
        uint256 price = currentTokenPrice();
        uint256 usdcPerToken = (1e18 + price - 1) / price;
        if (usdcPerToken > maxUsdcPerToken) revert InvalidPrice();
        _deposit(amountOfTokens);
    }

    function _deposit(uint256 amountOfTokens) internal {
        if (isLgeFinished) revert LGEFinished();
        if (block.number > startBlock + streamBlocks) revert LGEFinished();

        uint256 usdcExpected = LGECalculationsLibrary.calculateUsdcNeeded(
            block.number,
            startBlock,
            streamBlocks,
            minTokenPrice,
            maxTokenPrice,
            amountOfTokens
        );

        if (totalTokensClaimed + amountOfTokens > cap) revert TooManyTokens();

        if (msg.value < usdcExpected) revert InvalidPrice();
        uint256 refund = msg.value - usdcExpected;

        uint256 usdcPortion = usdcExpected / 2;
        totalTokensClaimed += amountOfTokens;
        totalDeposits += 1;
        totalUsdcDeposited += usdcExpected;

        userStates[msg.sender].usdcToLiquidityDeposited += usdcPortion;
        userStates[msg.sender].remainingUsdcDeposited += usdcPortion;
        userStates[msg.sender].tokensToLiquidity += amountOfTokens;

        emit Deposited(
            msg.sender,
            amountOfTokens,
            usdcPortion,
            address(this).balance - refund
        );

        if (
            block.number >= (startBlock + streamBlocks) ||
            totalTokensClaimed == cap
        ) {
            isLgeFinished = true;
            if (totalTokensClaimed == cap) {
                _finalizeSuccess();
            } else {
                emit LGEFailed();
            }
        }

        _sendNative(msg.sender, refund);
    }

    function _finalizeSuccess() internal {
        isLgeSuccessful = true;

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });

        uint256 raised = totalUsdcDeposited;
        totalEthToLiquidity = raised / 2;
        totalUsdcRaised = raised;
        treasuryUsdc = raised - totalEthToLiquidity;
        totalActiveWeight = totalEthToLiquidity;

        uint256 averagePrice = cap / totalEthToLiquidity; // tokens per USDC
        if (averagePrice == 0) revert InvalidPrice();
        initialSqrtPriceX96 = LGECalculationsLibrary.getSqrtPrice(averagePrice);

        token.mint(address(this), cap);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            totalEthToLiquidity,
            cap
        );

        positionTokenId = positionManager.nextTokenId();

        bytes[] memory params = new bytes[](2);
        bytes[] memory mintParams = new bytes[](3);

        params[0] = abi.encodeWithSelector(
            IPoolInitializer_v4.initializePool.selector,
            poolKey,
            initialSqrtPriceX96
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );
        mintParams[0] = abi.encode(
            poolKey,
            MIN_TICK,
            MAX_TICK,
            liquidity,
            totalEthToLiquidity,
            cap,
            address(this),
            new bytes(0)
        );
        mintParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        mintParams[2] = abi.encode(poolKey.currency0, address(this));

        params[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + 60
        );

        _approveTokensForLiquidity();

        inHookOp = true;
        positionManager.multicall{value: totalEthToLiquidity}(params);
        inHookOp = false;

        totalLiquidity = liquidity;

        emit LGESuccessful(
            poolKey,
            address(this).balance,
            initialSqrtPriceX96,
            totalEthToLiquidity,
            liquidity
        );

        try this.treasuryBuy() {} catch {
            pendingBuy = cap / 20;
        }
    }

    function treasuryBuy() external {
        uint256 target;
        if (msg.sender == address(this)) {
            target = cap / 20;
        } else {
            if (!isLgeSuccessful) revert LGENotSuccessful();
            if (pendingBuy == 0) revert NoPendingBuy();
            target = pendingBuy;
        }
        _treasuryBuy(target);
    }

    function _treasuryBuy(uint256 target) internal {
        if (target == 0) {
            _escrowTreasuryRemainder();
            return;
        }
        inHookOp = true;
        (uint256 usdcIn, uint256 tokensOut) = abi.decode(
            poolManager.unlock(abi.encode(target)),
            (uint256, uint256)
        );
        inHookOp = false;

        treasuryUsdc -= usdcIn;
        if (tokensOut > 0) {
            token.approve(address(vestingVault), tokensOut);
            vestingVault.create(
                address(token),
                agent,
                uint128(tokensOut),
                vestingCliff,
                vestingDuration
            );
        }
        pendingBuy = target - tokensOut;
        emit TreasuryBuyExecuted(tokensOut, usdcIn, pendingBuy);

        if (pendingBuy == 0) {
            _escrowTreasuryRemainder();
        }
    }

    function _escrowTreasuryRemainder() internal {
        uint256 amount = treasuryUsdc;
        if (amount == 0) return;
        treasuryUsdc = 0;
        inferenceEscrow.credit{value: amount}();
        emit TreasuryEscrowed(amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!inHookOp) revert Unauthorized();

        uint256 target = abi.decode(data, (uint256));

        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(target),
                sqrtPriceLimitX96: initialSqrtPriceX96 / 2
            }),
            ""
        );

        uint256 usdcIn = uint256(int256(-delta.amount0()));
        uint256 tokensOut = uint256(int256(delta.amount1()));

        poolManager.settle{value: usdcIn}();
        poolManager.take(poolKey.currency1, address(this), tokensOut);

        return abi.encode(usdcIn, tokensOut);
    }

    function withdraw() external {
        if (isLgeSuccessful) revert CannotWithdrawUSDC();
        if (userStates[msg.sender].usdcToLiquidityDeposited == 0)
            revert NoUSDCDeposited();
        if (block.number < startBlock + streamBlocks) {
            revert WithdrawTooEarly();
        }

        if (!isLgeFinished) {
            isLgeFinished = true;
            emit LGEFailed();
        }

        uint256 usdcToWithdraw = userStates[msg.sender].usdcToLiquidityDeposited +
            userStates[msg.sender].remainingUsdcDeposited;

        userStates[msg.sender].usdcToLiquidityDeposited = 0;
        userStates[msg.sender].remainingUsdcDeposited = 0;

        _sendNative(msg.sender, usdcToWithdraw);

        emit Withdrawn(msg.sender, usdcToWithdraw);
    }

    function finalize() external {
        if (isLgeFinished) return;
        if (block.number < startBlock + streamBlocks) revert LGEActive();
        isLgeFinished = true;
        emit LGEFailed();
    }

    function claimLiquidity() external returns (uint256 share) {
        if (!isLgeSuccessful) revert CannotClaimLiquidity();

        UserState storage u = userStates[msg.sender];
        if (u.hasClaimedLp) revert AlreadyClaimed();
        if (u.usdcToLiquidityDeposited == 0) revert NoUSDCDeposited();

        u.hasClaimedLp = true;
        share = (u.usdcToLiquidityDeposited * totalLiquidity) / totalEthToLiquidity;
        lpShares[msg.sender] += share;

        emit LpShareClaimed(msg.sender, share);
    }

    function exitLiquidity() external {
        if (!isLgeSuccessful) revert LGENotSuccessful();
        if (lpLocked) revert LpLockedForever();
        if (exitThreshold == 0) revert ExitDisabled();
        if (feeVolume30d() >= exitThreshold) revert ExitThresholdNotMet();

        UserState storage u = userStates[msg.sender];
        uint256 share = lpShares[msg.sender];
        if (share == 0) revert NoLpShare();

        uint256 weight = u.usdcToLiquidityDeposited;
        uint256 feesOwed = u.accruedFees +
            (weight * (feeIndex - u.userIndexPaid)) /
            SCALE;

        lpShares[msg.sender] = 0;
        u.usdcToLiquidityDeposited = 0;
        u.accruedFees = 0;
        u.userIndexPaid = feeIndex;
        u.exited = true;
        totalActiveWeight -= weight;

        uint256 usdcBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));

        inHookOp = true;
        bytes memory decreaseActions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionTokenId, share, 0, 0, new bytes(0));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        positionManager.modifyLiquidities(
            abi.encode(decreaseActions, params),
            block.timestamp + 60
        );
        inHookOp = false;

        uint256 usdcOut = address(this).balance - usdcBefore;
        uint256 tokensOut = token.balanceOf(address(this)) - tokenBefore;

        if (tokensOut > 0) token.transfer(msg.sender, tokensOut);
        _sendNative(msg.sender, usdcOut + feesOwed);

        emit Exited(msg.sender, share, usdcOut, tokensOut, feesOwed);
    }

    function claimParticipant() external {
        UserState storage u = userStates[msg.sender];
        if (u.exited) revert NothingToClaim();
        uint256 weight = u.usdcToLiquidityDeposited;
        uint256 pending = u.accruedFees +
            (weight * (feeIndex - u.userIndexPaid)) /
            SCALE;
        if (pending == 0) revert NothingToClaim();

        u.accruedFees = 0;
        u.userIndexPaid = feeIndex;
        _sendNative(msg.sender, pending);

        emit ParticipantFeesClaimed(msg.sender, pending);
    }

    function claimAgent() external {
        uint256 amount = agentAccrued;
        if (amount == 0) revert NothingToClaim();
        agentAccrued = 0;
        _sendNative(agent, amount);
        emit AgentFeesClaimed(agent, amount);
    }

    function setAgent(address newAgent) external {
        if (msg.sender != operator) revert NotOperator();
        address oldAgent = agent;
        if (newAgent == address(0) || newAgent == oldAgent) revert InvalidAgent();

        uint256 accrued = agentAccrued;
        agentAccrued = 0;
        agent = newAgent;
        vestingVault.migrateBeneficiary(address(token), oldAgent, newAgent);
        emit AgentRotated(oldAgent, newAgent);

        if (accrued > 0) {
            _sendNative(oldAgent, accrued);
            emit AgentFeesClaimed(oldAgent, accrued);
        }
    }

    function claimProtocol() external {
        uint256 amount = protocolAccrued;
        if (amount < MIN_SWEEP) revert BelowMinSweep();
        protocolAccrued = 0;

        uint256 n = splits.length;
        uint256 sent;
        for (uint256 i; i < n; ++i) {
            uint256 portion = i == n - 1 ? amount - sent : (amount * splits[i].bps) / BPS;
            sent += portion;
            _sendNative(splits[i].to, portion);
        }
        emit ProtocolFeesSwept(amount);
    }

    function proposeSplits(Split[] calldata newSplits) external {
        if (msg.sender != protocol) revert NotProtocol();
        pendingSplitsHash = keccak256(abi.encode(newSplits));
        splitsEffectiveAt = uint64(block.timestamp) + SPLITS_TIMELOCK;
        emit SplitsProposed(pendingSplitsHash, splitsEffectiveAt);
    }

    function applySplits(Split[] calldata newSplits) external {
        if (msg.sender != protocol) revert NotProtocol();
        if (pendingSplitsHash == bytes32(0)) revert NoPendingSplits();
        if (block.timestamp < splitsEffectiveAt) revert TimelockNotElapsed();
        if (keccak256(abi.encode(newSplits)) != pendingSplitsHash)
            revert SplitsMismatch();

        uint256 total;
        for (uint256 i; i < newSplits.length; ++i) total += newSplits[i].bps;
        if (total != BPS) revert InvalidSplits();

        delete splits;
        for (uint256 i; i < newSplits.length; ++i) splits.push(newSplits[i]);
        pendingSplitsHash = bytes32(0);
        emit SplitsApplied();
    }

    function splitsLength() external view returns (uint256) {
        return splits.length;
    }

    function feeVolume30d() public view returns (uint256 sum) {
        uint64 today = uint64(block.timestamp / 1 days);
        for (uint256 i; i < 30; ++i) {
            if (feeBucketDay[i] + 30 > today) sum += feeBucketAmt[i];
        }
    }

    function participantClaimable(address user) external view returns (uint256) {
        UserState memory u = userStates[user];
        if (u.exited) return 0;
        return
            u.accruedFees +
            (u.usdcToLiquidityDeposited * (feeIndex - u.userIndexPaid)) /
            SCALE;
    }

    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160
    ) internal view override returns (bytes4) {
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
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (inHookOp) {
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }
        if (PoolId.unwrap(poolKey.toId()) != PoolId.unwrap(key.toId())) {
            revert WrongPool();
        }

        if (params.zeroForOne && params.amountSpecified < 0) {
            uint256 input = uint256(-params.amountSpecified);
            uint256 fee = (input * feeBps) / BPS;
            if (fee > 0) {
                poolManager.take(key.currency0, address(this), fee);
                _bookFee(fee);
                return (
                    BaseHook.beforeSwap.selector,
                    toBeforeSwapDelta(fee.toInt128(), 0),
                    0
                );
            }
        }

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (inHookOp) return (BaseHook.afterSwap.selector, 0);

        if (!params.zeroForOne && params.amountSpecified > 0) {
            revert ExactOutputSellUnsupported();
        }

        int128 specifiedDelta = (params.amountSpecified < 0) == params.zeroForOne
            ? delta.amount0()
            : delta.amount1();
        if (params.zeroForOne && params.amountSpecified < 0) {
            uint256 input = uint256(-params.amountSpecified);
            uint256 inputFee = (input * feeBps) / BPS;
            int256 expected = params.amountSpecified + int256(inputFee);
            if (specifiedDelta != expected) revert PartialFill();
            return (BaseHook.afterSwap.selector, 0);
        }
        if (specifiedDelta != params.amountSpecified) revert PartialFill();

        int128 amount0 = delta.amount0();
        uint256 usdcLeg = amount0 < 0
            ? uint256(int256(-amount0))
            : uint256(int256(amount0));
        uint256 fee = (usdcLeg * feeBps) / BPS;
        if (fee == 0) return (BaseHook.afterSwap.selector, 0);

        poolManager.take(key.currency0, address(this), fee);
        _bookFee(fee);

        return (BaseHook.afterSwap.selector, fee.toInt128());
    }

    function _bookFee(uint256 fee) internal {
        uint256 participantShare = fee / 4;
        uint256 agentShare = fee / 2;
        uint256 protocolShare = fee - participantShare - agentShare;

        participantFeesBooked += participantShare;
        agentAccrued += agentShare;
        protocolAccrued += protocolShare;

        uint256 weight = totalActiveWeight;
        if (weight > 0) {
            feeIndex += (participantShare * SCALE) / weight;
        } else {
            protocolAccrued += participantShare;
        }

        uint64 day = uint64(block.timestamp / 1 days);
        uint256 i = day % 30;
        if (feeBucketDay[i] != day) {
            feeBucketDay[i] = day;
            feeBucketAmt[i] = 0;
        }
        feeBucketAmt[i] += fee;

        if (!lpLocked && participantFeesBooked >= totalUsdcRaised) {
            lpLocked = true;
            emit LpLocked(participantFeesBooked);
        }

        emit FeeCharged(fee, participantShare, agentShare, protocolShare);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (!inHookOp) revert Unauthorized();
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (!inHookOp) revert Unauthorized();
        return this.beforeRemoveLiquidity.selector;
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
