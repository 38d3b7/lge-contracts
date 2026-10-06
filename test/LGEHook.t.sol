// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {PosmTestSetup} from "./utils/PosmTestSetup.sol";
import {Deploy} from "./utils/Deploy.sol";
import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";
import {LGEToken} from "../src/LGEToken.sol";
import {LGECalculationsLibrary} from "../src/libraries/LGECalculationsLibrary.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {InferenceEscrow} from "../src/InferenceEscrow.sol";
import {HookCreationCode} from "../src/HookCreationCode.sol";

import {console} from "forge-std/console.sol";

/// @notice Rejects native transfers, to exercise the pending-credit fallback.
contract RejectingReceiver {
    receive() external payable {
        revert("no native");
    }
}

/// @notice Parks a refund as a pending credit, then re-enters
///         claimPendingNative from its receive() to try to be paid repeatedly.
contract ReentrantClaimer {
    LGEHook internal immutable hook;
    bool internal accept;
    uint256 public reentries;

    constructor(LGEHook hook_) {
        hook = hook_;
    }

    function deposit(uint256 tokenAmount) external payable {
        hook.deposit{value: msg.value}(tokenAmount);
    }

    function attack() external {
        accept = true;
        hook.claimPendingNative();
    }

    receive() external payable {
        if (!accept) revert("no native");
        if (reentries < 5) {
            reentries++;
            try hook.claimPendingNative() {} catch {}
        }
    }
}

/// @notice Overpays a deposit and, from the refund callback, tries to slip in
///         a second deposit before the first one's ledgers are written.
contract ReentrantDepositor {
    LGEHook internal immutable hook;
    bool public reentered;
    bool public innerSucceeded;

    constructor(LGEHook hook_) {
        hook = hook_;
    }

    function deposit(uint256 tokenAmount) external payable {
        hook.deposit{value: msg.value}(tokenAmount);
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;
        try hook.deposit{value: 2}(1) {
            innerSucceeded = true;
        } catch {}
    }
}

contract LGEHookTest is Test, PosmTestSetup {
    using stdStorage for StdStorage;

    uint160 private immutable FLAGS =
        uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
                Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

    LGEManager lgeManager;
    VestingVault vestingVault;
    InferenceEscrow inferenceEscrow;
    HookCreationCode hookCreationCode;

    address owner = address(0xABCD);
    address tokenAdmin = address(0x1234);
    address tokenCreator = address(0x5678);
    address operator = address(0x0909);

    address user = address(0x9ABC);
    address user2 = address(0xDEF0);
    address user3 = address(0x1111);
    address user4 = address(0x2222);

    address tokenAddress;
    address hookAddress;

    uint256 startBlock;
    uint256 deployNonce;

    // default "small" config: full raise is well under 1 USDC
    uint256 constant TOKEN_CAP = 1_774_544e18;
    uint256 constant STREAM_BLOCKS = 3600;
    uint256 constant MIN_PRICE = 1e9; // tokens per USDC
    uint256 constant MAX_PRICE = 4e9;
    uint24 constant FEE_BPS = 100;
    uint256 constant EXIT_THRESHOLD = 1_000e18;
    // 12-month cliff (the launch minimum); duration runs from the grant start,
    // so half unlocks at the cliff and the rest vests linearly to month 24
    uint64 constant VESTING_CLIFF = 365 days;
    uint64 constant VESTING_DURATION = 730 days;

    struct DeployParams {
        uint256 cap;
        uint256 minPrice;
        uint256 maxPrice;
        uint24 feeBps;
        uint256 exitThreshold;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployPosm(manager);
        Deploy.lgeCalculationsLibrary();

        vestingVault = new VestingVault();
        inferenceEscrow = new InferenceEscrow(owner);
        hookCreationCode = new HookCreationCode();
        lgeManager = new LGEManager(
            address(manager),
            address(lpm),
            address(permit2),
            address(vestingVault),
            address(inferenceEscrow),
            owner,
            address(hookCreationCode)
        );

        vm.roll(31160653);
        startBlock = block.number;
        (tokenAddress, hookAddress) = _deployWithConfig(_defaultParams());
    }

    function _defaultParams() internal pure returns (DeployParams memory) {
        return
            DeployParams({
                cap: TOKEN_CAP,
                minPrice: MIN_PRICE,
                maxPrice: MAX_PRICE,
                feeBps: FEE_BPS,
                exitThreshold: EXIT_THRESHOLD
            });
    }

    /// @dev Launch as `tokenAdmin`: the agent deploys its own token.
    function _deployWithConfig(
        DeployParams memory p
    ) internal returns (address, address) {
        LGEManager.DeploymentConfig memory config = _buildConfig(p);
        vm.prank(tokenAdmin);
        return lgeManager.deployToken(config);
    }

    /// @dev Replace the current launch with a new one. One address gets one
    ///      launch at a time, so the new launch gets a fresh agent.
    function _relaunchAsNewAgent(
        DeployParams memory p
    ) internal returns (address, address) {
        tokenAdmin = address(uint160(0xA6E000 + deployNonce));
        return _deployWithConfig(p);
    }

    /// @dev A config for tests that expect deployToken to revert on the launch
    ///      rule, which is checked before anything is deployed — so no hook
    ///      salt needs mining.
    function _unminedConfig()
        internal
        view
        returns (LGEManager.DeploymentConfig memory config)
    {
        config.tokenConfig.tokenAdmin = tokenAdmin;
        config.tokenConfig.cap = TOKEN_CAP;
        config.tokenConfig.tokenSalt = bytes32(deployNonce);
        config.hookConfig.startBlock = block.number;
        config.hookConfig.streamBlocks = STREAM_BLOCKS;
        config.hookConfig.minTokenPrice = MIN_PRICE;
        config.hookConfig.maxTokenPrice = MAX_PRICE;
        config.hookConfig.feeBps = FEE_BPS;
        config.hookConfig.vestingCliff = VESTING_CLIFF;
        config.hookConfig.operator = operator;
    }

    function _buildConfig(
        DeployParams memory p
    ) internal returns (LGEManager.DeploymentConfig memory config) {
        bytes32 tokenSalt = keccak256(abi.encodePacked(tokenAdmin, deployNonce++));
        address tokenComputed = _computeTokenAddress(p, tokenSalt);
        bytes32 hookSalt = _mineHookSalt(p, tokenComputed);

        config.tokenConfig.tokenAdmin = tokenAdmin;
        config.tokenConfig.name = "Test Token";
        config.tokenConfig.symbol = "TEST";
        config.tokenConfig.image = "https://example.com/image.png";
        config.tokenConfig.metadata = "https://example.com/metadata.json";
        config.tokenConfig.cap = p.cap;
        config.tokenConfig.tokenSalt = tokenSalt;

        config.hookConfig.hookSalt = hookSalt;
        config.hookConfig.startBlock = startBlock;
        config.hookConfig.streamBlocks = STREAM_BLOCKS;
        config.hookConfig.minTokenPrice = p.minPrice;
        config.hookConfig.maxTokenPrice = p.maxPrice;
        config.hookConfig.exitThreshold = p.exitThreshold;
        config.hookConfig.feeBps = p.feeBps;
        config.hookConfig.vestingCliff = VESTING_CLIFF;
        config.hookConfig.vestingDuration = VESTING_DURATION;
        config.hookConfig.operator = operator;
    }

    function _computeTokenAddress(
        DeployParams memory p,
        bytes32 tokenSalt
    ) internal view returns (address) {
        bytes memory tokenConstructorArgs = abi.encode(
            "Test Token",
            "TEST",
            tokenAdmin,
            "https://example.com/image.png",
            "https://example.com/metadata.json",
            address(lgeManager),
            p.cap
        );

        return
            vm.computeCreate2Address(
                tokenSalt,
                hashInitCode(type(LGEToken).creationCode, tokenConstructorArgs),
                address(lgeManager)
            );
    }

    function _mineHookSalt(
        DeployParams memory p,
        address tokenComputed
    ) internal view returns (bytes32) {
        LGEHook.HookParams memory hp = LGEHook.HookParams({
            poolManager: address(manager),
            positionManager: address(lpm),
            permit2: address(permit2),
            token: tokenComputed,
            agent: tokenAdmin,
            operator: operator,
            protocol: owner,
            vestingVault: address(vestingVault),
            inferenceEscrow: address(inferenceEscrow),
            startBlock: startBlock,
            streamBlocks: STREAM_BLOCKS,
            minTokenPrice: p.minPrice,
            maxTokenPrice: p.maxPrice,
            exitThreshold: p.exitThreshold,
            feeBps: p.feeBps,
            vestingCliff: VESTING_CLIFF,
            vestingDuration: VESTING_DURATION
        });

        (, bytes32 salt) = HookMiner.find(
            address(lgeManager),
            FLAGS,
            type(LGEHook).creationCode,
            abi.encode(hp)
        );
        return salt;
    }

    function _hook() internal view returns (LGEHook) {
        return LGEHook(payable(hookAddress));
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        (Currency c0, Currency c1, uint24 fee, int24 ts, IHooks hk) = _hook()
            .poolKey();
        key = PoolKey(c0, c1, fee, ts, hk);
    }

    /// @dev Deposit as `who`: the quote is computed BEFORE the prank so the
    ///      external staticcalls in calculateUSDCNeeded cannot consume it.
    function _depositAs(address who, uint256 tokenAmount) internal {
        uint256 needed = calculateUSDCNeeded(tokenAmount);
        vm.deal(who, needed);
        vm.prank(who);
        _hook().deposit{value: needed}(tokenAmount);
    }

    /// @dev Reads the curve params from the currently deployed hook.
    function calculateUSDCNeeded(
        uint256 tokenAmount
    ) internal view returns (uint256) {
        LGEHook h = _hook();
        return
            LGECalculationsLibrary.calculateUsdcNeeded(
                block.number,
                h.startBlock(),
                h.streamBlocks(),
                h.minTokenPrice(),
                h.maxTokenPrice(),
                tokenAmount
            );
    }

    // ------------------------------------------------------------------
    // Sale mechanics
    // ------------------------------------------------------------------

    function test_depositSuccess() public {
        uint256 tokenAmount = 549_088e18;
        uint256 usdcNeeded = calculateUSDCNeeded(tokenAmount);
        hoax(user);
        _hook().deposit{value: usdcNeeded}(tokenAmount);

        LGEHook.UserState memory userState = _getUserState(user);

        assertEq(address(_hook()).balance, usdcNeeded);
        assertEq(userState.usdcToLiquidityDeposited, usdcNeeded / 2);
        assertEq(userState.remainingUsdcDeposited, usdcNeeded / 2);
        assertEq(userState.tokensToLiquidity, tokenAmount);
        assertFalse(userState.hasClaimedLp);
    }

    function test_depositInvalidPriceRevert() public {
        uint256 tokenAmount = 549_088e18;
        uint256 usdcNeeded = calculateUSDCNeeded(tokenAmount);
        hoax(user);
        vm.expectRevert(LGEHook.InvalidPrice.selector);
        _hook().deposit{value: usdcNeeded - 1}(tokenAmount);
    }

    /// @dev Regression: floor division `amountOfTokens / tokensPerUsdc` quoted
    ///      0 for buys smaller than the ratio and the hook accepted
    ///      msg.value == 0 — free tokens. Pin the ABSOLUTE quote so the price
    ///      units (raw token-wei per usdc-wei) can never drift again: at
    ///      MIN_PRICE = 1e9, 1 token costs ceil(1e18/1e9) = 1e9 usdc-wei per
    ///      half, and 1 token-wei (dust) still quotes 1 usdc-wei per half.
    function test_depositQuoteAbsoluteUnits() public {
        assertEq(calculateUSDCNeeded(1e18), 2e9); // 1 token at min price
        assertEq(calculateUSDCNeeded(1), 2); // 1 token-wei of dust, ceil-rounded
        assertEq(calculateUSDCNeeded(549_088e18), 1_098_176_000_000_000); // exact

        vm.expectRevert(LGEHook.InvalidPrice.selector);
        _hook().deposit{value: 0}(1);

        _depositAs(user, 1e18);
        LGEHook.UserState memory st = _getUserState(user);
        assertEq(st.tokensToLiquidity, 1e18);
        assertEq(st.usdcToLiquidityDeposited, 1e9);
    }

    function test_depositAfterLGEFinishedRevert() public {
        _reachCapSuccessfully();

        vm.roll(startBlock + 5001);
        uint256 tokenAmount = 100e18;
        uint256 usdcNeeded = calculateUSDCNeeded(tokenAmount);

        hoax(user);
        vm.expectRevert(LGEHook.LGEFinished.selector);
        _hook().deposit{value: usdcNeeded}(tokenAmount);
    }

    function test_depositMultipleUsers() public {
        vm.roll(startBlock + 100);

        uint256 tokenAmount1 = 1000e18;
        _depositAs(user, tokenAmount1);

        vm.roll(startBlock + 200);
        uint256 tokenAmount2 = 2000e18;
        _depositAs(user2, tokenAmount2);

        assertEq(_getUserState(user).tokensToLiquidity, tokenAmount1);
        assertEq(_getUserState(user2).tokensToLiquidity, tokenAmount2);
        assertEq(_hook().totalTokensClaimed(), tokenAmount1 + tokenAmount2);
        assertEq(_hook().totalDeposits(), 2);
    }

    function test_depositPriceChangesOverTime() public {
        uint256 tokenAmount = 1000e18;

        vm.roll(startBlock + 100);
        uint256 earlyPrice = calculateUSDCNeeded(tokenAmount);

        vm.roll(startBlock + 3000);
        uint256 latePrice = calculateUSDCNeeded(tokenAmount);

        assertTrue(latePrice < earlyPrice); // Dutch: USDC cost falls as the rate rises
    }

    /// @dev Pre-start price reads clamp to minPrice instead of underflowing —
    ///      UIs and the e2e quote before the window opens.
    function test_priceClampsBeforeStart() public {
        vm.roll(startBlock - 5);
        uint256 early = calculateUSDCNeeded(1000e18);
        vm.roll(startBlock);
        uint256 atStart = calculateUSDCNeeded(1000e18);
        assertEq(early, atStart);
        assertGt(early, 0);
    }

    function test_depositOverloadGuards() public {
        uint256 tokenAmount = 1000e18;
        uint256 usdcNeeded = calculateUSDCNeeded(tokenAmount);

        // deadline in the past
        hoax(user);
        vm.expectRevert(LGEHook.LGEFinished.selector);
        _hook().deposit{value: usdcNeeded}(
            tokenAmount,
            type(uint256).max,
            block.timestamp - 1
        );

        // maxUsdcPerToken below the current price
        uint256 price = _hook().currentTokenPrice(); // token-wei per usdc-wei
        uint256 usdcPerToken = 1e18 / price; // floor; hook computes the ceil
        hoax(user);
        vm.expectRevert(LGEHook.InvalidPrice.selector);
        _hook().deposit{value: usdcNeeded}(
            tokenAmount,
            usdcPerToken - 1,
            block.timestamp + 1
        );

        // happy path
        hoax(user);
        _hook().deposit{value: usdcNeeded}(
            tokenAmount,
            type(uint256).max,
            block.timestamp + 1
        );
        assertEq(_getUserState(user).tokensToLiquidity, tokenAmount);
    }

    function test_depositRefundParksForRejectingWallet() public {
        RejectingReceiver r = new RejectingReceiver();
        uint256 tokenAmount = 1000e18;
        uint256 usdcNeeded = calculateUSDCNeeded(tokenAmount);
        vm.deal(address(r), usdcNeeded + 1e15);

        vm.prank(address(r));
        _hook().deposit{value: usdcNeeded + 1e15}(tokenAmount); // 1e15 overpay

        // the refund could not be pushed; it sits as a pending credit
        assertEq(_hook().pendingNative(address(r)), 1e15);
    }

    /// @dev Regression: claimPendingNative sent before zeroing the credit, so
    ///      a re-entrant receive() was paid the same credit once per nested
    ///      call — draining other depositors' USDC. The credit pays out once.
    function test_claimPendingNativeReentrancyPaysOnce() public {
        _depositAs(user, 100_000e18); // victim funds held by the hook

        ReentrantClaimer a = new ReentrantClaimer(_hook());
        uint256 tokenAmount = 1000e18;
        uint256 usdcNeeded = calculateUSDCNeeded(tokenAmount);
        // small enough that the victim's deposit could fund every re-entry
        uint256 overpay = 1e13;
        a.deposit{value: usdcNeeded + overpay}(tokenAmount);
        assertEq(_hook().pendingNative(address(a)), overpay);

        uint256 hookBefore = address(_hook()).balance;
        a.attack();

        assertGt(a.reentries(), 0); // the re-entry was attempted
        assertEq(address(a).balance, overpay);
        assertEq(address(_hook()).balance, hookBefore - overpay);
        assertEq(_hook().pendingNative(address(a)), 0);
    }

    /// @dev Regression: the refund was sent between the cap check and the
    ///      totalTokensClaimed update, so a deposit re-entered from the refund
    ///      callback passed the stale check and pushed the total past the cap —
    ///      `== cap` was then unreachable and the campaign could only fail.
    function test_depositReentrancyCannotOvershootCap() public {
        uint256 cap = LGEToken(tokenAddress).cap();
        uint256 tokensPerUser = cap / 4;

        vm.roll(startBlock + 1000);
        _depositAs(user, tokensPerUser);
        _depositAs(user2, tokensPerUser);
        _depositAs(user3, tokensPerUser);

        ReentrantDepositor a = new ReentrantDepositor(_hook());
        uint256 usdcNeeded = calculateUSDCNeeded(tokensPerUser);
        a.deposit{value: usdcNeeded + 1e12}(tokensPerUser); // final deposit, overpaid

        assertTrue(a.reentered()); // the refund callback did fire
        assertFalse(a.innerSucceeded());
        assertEq(_hook().totalTokensClaimed(), cap);
        assertTrue(_hook().isLgeSuccessful());
        assertEq(address(a).balance, 1e12); // refund still delivered
    }

    /// @dev Regression: success sized the raise from address(this).balance,
    ///      which also holds parked refund credits and plain donations. Parked
    ///      credits were paired into the pool while still owed to their owner.
    function test_finalizeIgnoresParkedCreditsAndDonations() public {
        uint256 cap = LGEToken(tokenAddress).cap();
        uint256 tokensPerUser = cap / 4;
        uint256 parked = 1e15;
        uint256 donation = 3e15;

        vm.roll(startBlock + 1000);
        uint256 usdcNeeded = calculateUSDCNeeded(tokensPerUser);

        RejectingReceiver r = new RejectingReceiver();
        vm.deal(address(r), usdcNeeded + parked);
        vm.prank(address(r));
        _hook().deposit{value: usdcNeeded + parked}(tokensPerUser);

        (bool ok, ) = address(_hook()).call{value: donation}("");
        assertTrue(ok);

        _depositAs(user, tokensPerUser);
        _depositAs(user2, tokensPerUser);
        _depositAs(user3, tokensPerUser);

        assertTrue(_hook().isLgeSuccessful());
        assertEq(_hook().totalUsdcRaised(), usdcNeeded * 4);
        assertEq(_hook().totalEthToLiquidity(), usdcNeeded * 2);
        // the parked credit is still owed and still backed
        assertEq(_hook().pendingNative(address(r)), parked);
        assertGe(address(_hook()).balance, parked + donation);
    }

    // ------------------------------------------------------------------
    // Success / failure
    // ------------------------------------------------------------------

    function test_LGESuccess() public {
        _reachCapSuccessfully();

        assertTrue(_hook().isLgeSuccessful());
        assertTrue(_hook().isLgeFinished());
        assertTrue(_hook().totalLiquidity() > 0);
        assertTrue(_hook().positionTokenId() > 0);

        // no native dust stranded in the position manager (SWEEP runs)
        assertEq(address(lpm).balance, 0);
    }

    function test_treasuryBuyOnSuccess() public {
        _reachCapSuccessfully();

        // 5% of supply vested to the agent
        (uint128 total, , , , ) = vestingVault.grants(tokenAddress, tokenAdmin);
        assertApproxEqAbs(uint256(total), TOKEN_CAP / 20, TOKEN_CAP / 20 / 100 + 2);

        // remainder credited to the agent's inference escrow
        assertGt(inferenceEscrow.creditOf(hookAddress), 0);

        // buy completed atomically; nothing pending
        assertEq(_hook().pendingBuy(), 0);
        assertEq(_hook().treasuryUsdc(), 0);

        // no stranded token tranche left in the hook (dust only)
        assertLt(LGEToken(tokenAddress).balanceOf(hookAddress), TOKEN_CAP / 1000);
    }

    function test_completeTreasuryBuyRevertsWhenNonePending() public {
        _reachCapSuccessfully();
        vm.expectRevert(LGEHook.NoPendingBuy.selector);
        _hook().treasuryBuy();
    }

    /// The treasury buy is a hook-initiated swap: it must never be charged the
    /// hook fee. The invariant is "no FeeCharged / no booked share", not
    /// "which layer skipped the callback". `inHookOp` is the hook's own
    /// skip; some PoolManagers also skip self-initiated callbacks.
    function test_treasuryBuyBooksNoFee() public {
        vm.recordLogs();
        _reachCapSuccessfully();

        assertEq(_hook().participantFeesBooked(), 0, "participant fees booked by treasury buy");
        assertEq(_hook().agentAccrued(), 0, "agent fees booked by treasury buy");
        assertEq(_hook().protocolAccrued(), 0, "protocol fees booked by treasury buy");

        // no FeeCharged log from the success path
        bytes32 sig = keccak256("FeeCharged(uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].topics[0] == sig, "FeeCharged emitted during treasury buy");
        }
    }

    function test_LGEFailedPartialCapReached() public {
        vm.roll(startBlock + 100);
        uint256 tokenAmount = 1000e18;
        _depositAs(user, tokenAmount);

        vm.roll(startBlock + STREAM_BLOCKS);
        _depositAs(user2, tokenAmount);

        assertFalse(_hook().isLgeSuccessful());
        assertTrue(_hook().isLgeFinished());
    }

    function test_withdrawAfterLGEFailed() public {
        vm.roll(startBlock + 100);
        uint256 tokenAmount = 1000e18;
        uint256 usdcNeeded = calculateUSDCNeeded(tokenAmount);

        hoax(user);
        _hook().deposit{value: usdcNeeded}(tokenAmount);

        vm.roll(startBlock + STREAM_BLOCKS);
        _depositAs(user2, tokenAmount);

        uint256 balanceBefore = user.balance;

        vm.prank(user);
        _hook().withdraw();

        assertEq(user.balance - balanceBefore, usdcNeeded);

        LGEHook.UserState memory userState = _getUserState(user);
        assertEq(userState.usdcToLiquidityDeposited, 0);
        assertEq(userState.remainingUsdcDeposited, 0);
    }

    /// @dev The flag must not depend on a finalizing deposit poke: a failed
    ///      campaign whose participant withdraws directly is finished.
    function test_withdrawFinalizesFailedLGE() public {
        vm.roll(startBlock + 100);
        _depositAs(user, 1000e18);

        vm.roll(startBlock + STREAM_BLOCKS + 1);
        assertFalse(_hook().isLgeFinished());

        vm.prank(user);
        _hook().withdraw();

        assertTrue(_hook().isLgeFinished());
        assertFalse(_hook().isLgeSuccessful());
    }

    /// @dev Campaigns whose participants never transact again still finalize,
    ///      via a permissionless poke. claimed == cap always finalizes inside
    ///      the deposit that reaches it, so only the failed branch is reachable.
    function test_finalizePermissionlessPoke() public {
        vm.roll(startBlock + 100);
        _depositAs(user, 1000e18);

        vm.expectRevert(LGEHook.LGEActive.selector);
        _hook().finalize();

        vm.roll(startBlock + STREAM_BLOCKS + 1);
        vm.prank(user2);
        _hook().finalize();
        assertTrue(_hook().isLgeFinished());
        assertFalse(_hook().isLgeSuccessful());

        _hook().finalize(); // idempotent
        assertTrue(_hook().isLgeFinished());
    }

    function test_withdrawTooEarlyRevert() public {
        vm.roll(startBlock + 100);
        uint256 tokenAmount = 1000e18;
        _depositAs(user, tokenAmount);

        vm.roll(startBlock + STREAM_BLOCKS - 1);
        vm.prank(user);
        vm.expectRevert(LGEHook.WithdrawTooEarly.selector);
        _hook().withdraw();
    }

    function test_withdrawAfterSuccessfulLGERevert() public {
        _reachCapSuccessfully();

        vm.prank(user);
        vm.expectRevert(LGEHook.CannotWithdrawUSDC.selector);
        _hook().withdraw();
    }

    function test_withdrawNoDepositRevert() public {
        vm.roll(startBlock + 5001);

        vm.prank(user3);
        vm.expectRevert(LGEHook.NoUSDCDeposited.selector);
        _hook().withdraw();
    }

    // ------------------------------------------------------------------
    // LP shares (hook-custodied)
    // ------------------------------------------------------------------

    function test_claimLiquidityRecordsShare() public {
        _reachCapSuccessfully();

        uint256 weight = _getUserState(user).usdcToLiquidityDeposited;
        uint256 totalLiquidity = _hook().totalLiquidity();
        uint256 totalLiq = _hook().totalEthToLiquidity();

        vm.prank(user);
        uint256 share = _hook().claimLiquidity();
        assertTrue(share > 0);
        assertEq(_hook().lpShares(user), share);
        assertEq(share, (weight * totalLiquidity) / totalLiq);

        // deposit weight is preserved (it is the fee weight)
        assertGt(_getUserState(user).usdcToLiquidityDeposited, 0);
        assertTrue(_getUserState(user).hasClaimedLp);
    }

    function test_claimLiquidityDoubleClaimRevert() public {
        _reachCapSuccessfully();

        vm.prank(user);
        _hook().claimLiquidity();

        vm.prank(user);
        vm.expectRevert(LGEHook.AlreadyClaimed.selector);
        _hook().claimLiquidity();
    }

    // ------------------------------------------------------------------
    // Swap fees
    // ------------------------------------------------------------------

    function _swapBuyExactInput(
        uint256 usdcIn
    ) internal returns (BalanceDelta delta) {
        PoolKey memory key = _poolKey();
        vm.deal(address(this), usdcIn);
        delta = swapRouter.swap{value: usdcIn}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(usdcIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function test_swapExactInputBuyTakesFeeOnInput() public {
        _reachCapSuccessfully();

        uint256 usdcIn = _hook().totalUsdcRaised() / 100;
        uint256 expectedFee = (usdcIn * FEE_BPS) / 10_000;

        uint256 hookBalBefore = hookAddress.balance;
        BalanceDelta delta = _swapBuyExactInput(usdcIn);

        // hook collected the fee in native USDC
        assertEq(hookAddress.balance - hookBalBefore, expectedFee);

        // the swapper settled the full input; the pool saw it net of fee
        assertEq(delta.amount0(), -int256(usdcIn));

        // ledgers: 25 / 50 / 25, dust to protocol
        uint256 participant = expectedFee / 4;
        uint256 agentShare = expectedFee / 2;
        uint256 protocol = expectedFee - participant - agentShare;
        assertEq(_hook().participantFeesBooked(), participant);
        assertEq(_hook().agentAccrued(), agentShare);
        assertEq(_hook().protocolAccrued(), protocol);
    }

    function test_swapExactOutputBuyGrossesUpFee() public {
        _reachCapSuccessfully();

        PoolKey memory key = _poolKey();
        uint256 tokensOut = TOKEN_CAP / 1000;

        uint256 hookBalBefore = hookAddress.balance;

        vm.deal(address(this), 1 ether);
        uint256 balBefore = address(this).balance;
        BalanceDelta delta = swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(tokensOut),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        // caller delta = pool cost + fee on top (grossed up)
        uint256 paid = uint256(int256(-delta.amount0()));
        uint256 hookFee = hookAddress.balance - hookBalBefore;
        // fee = poolCost * 100/10000 and paid = poolCost + fee  =>  fee ≈ paid/101
        assertApproxEqAbs(hookFee, paid / 101, 2);
        assertEq(balBefore - address(this).balance, paid);
        assertEq(uint256(int256(delta.amount1())), tokensOut);
    }

    function test_swapSellExactInputDeductsFee() public {
        _reachCapSuccessfully();

        // buy first to get tokens
        uint256 usdcIn = _hook().totalUsdcRaised() / 100;
        BalanceDelta buyDelta = _swapBuyExactInput(usdcIn);
        uint256 tokensBought = uint256(int256(buyDelta.amount1()));

        LGEToken(tokenAddress).approve(address(swapRouter), type(uint256).max);

        PoolKey memory key = _poolKey();
        uint256 balBefore = address(this).balance;
        uint256 hookBalBefore = hookAddress.balance;

        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokensBought),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        // caller delta = gross output minus the fee
        uint256 received = uint256(int256(delta.amount0()));
        uint256 hookFee = hookAddress.balance - hookBalBefore;
        // fee = gross/100 and received = gross - fee  =>  fee ≈ received/99
        assertApproxEqAbs(hookFee, received / 99, 2);
        assertEq(address(this).balance - balBefore, received);
    }

    function test_swapExactOutputSellReverts() public {
        _reachCapSuccessfully();

        PoolKey memory key = _poolKey();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(); // ExactOutputSellUnsupported, wrapped by the PoolManager
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(1e6), // exact USDC out
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function test_swapsOpenIndefinitelyAfterSuccess() public {
        _reachCapSuccessfully();

        // far past the old TOTAL_BLOCKS swap window
        vm.roll(startBlock + 1_000_000);
        uint256 usdcIn = _hook().totalUsdcRaised() / 1000;
        BalanceDelta delta = _swapBuyExactInput(usdcIn);
        assertTrue(delta.amount1() > 0);
    }

    function test_thirdPartyLiquidityReverts() public {
        _reachCapSuccessfully();

        PoolKey memory key = _poolKey();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            TickMath.MIN_TICK,
            TickMath.MAX_TICK,
            uint256(1000),
            uint256(0.001 ether),
            uint256(1e18),
            user3,
            new bytes(0)
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        vm.deal(user3, 1 ether);
        vm.startPrank(user3);
        vm.expectRevert(); // Unauthorized, wrapped by posm/PoolManager
        lpm.modifyLiquidities{value: 0.001 ether}(
            abi.encode(
                abi.encodePacked(
                    uint8(Actions.MINT_POSITION),
                    uint8(Actions.SETTLE_PAIR)
                ),
                params
            ),
            block.timestamp + 60
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Fee claims
    // ------------------------------------------------------------------

    function test_claimParticipantProRata() public {
        _reachCapSuccessfully();

        uint256 usdcIn = _hook().totalUsdcRaised() / 100;
        _swapBuyExactInput(usdcIn);

        uint256 booked = _hook().participantFeesBooked();
        assertGt(booked, 0);

        uint256 weight = _getUserState(user).usdcToLiquidityDeposited;
        uint256 totalWeight = _hook().totalActiveWeight();
        uint256 expected = (booked * weight) / totalWeight;
        assertGt(expected, 0);

        uint256 balBefore = user.balance;
        vm.prank(user);
        _hook().claimParticipant();
        assertApproxEqAbs(user.balance - balBefore, expected, 4);

        // second claim reverts: nothing new accrued
        vm.prank(user);
        vm.expectRevert(LGEHook.NothingToClaim.selector);
        _hook().claimParticipant();
    }

    function test_claimAgentAndRotation() public {
        _reachCapSuccessfully();

        uint256 usdcIn = _hook().totalUsdcRaised() / 100;
        _swapBuyExactInput(usdcIn);

        uint256 accrued = _hook().agentAccrued();
        assertGt(accrued, 0);

        uint256 balBefore = tokenAdmin.balance;
        _hook().claimAgent(); // permissionless trigger, pays the agent
        assertEq(tokenAdmin.balance - balBefore, accrued);
        assertEq(_hook().agentAccrued(), 0);

        // rotate the agent
        vm.prank(operator);
        _hook().setAgent(user3);
        assertEq(_hook().agent(), user3);
    }

    /// @dev Rotation moves the vest (schedule and claimed amount included) and
    ///      the escrow spending rights, and pays fees accrued before the
    ///      rotation to the old agent.
    function test_rotationMovesVestCreditAndPaysOldAgentFees() public {
        _reachCapSuccessfully();
        _swapBuyExactInput(_hook().totalUsdcRaised() / 100);
        uint256 accrued = _hook().agentAccrued();
        assertGt(accrued, 0);

        // the old agent claims part of the vest (past the cliff) before rotating
        vm.warp(block.timestamp + VESTING_CLIFF + 30 days);
        vm.prank(tokenAdmin);
        vestingVault.claim(tokenAddress);
        (uint128 total, uint128 claimed, uint64 start, uint64 cliff, uint64 duration) =
            vestingVault.grants(tokenAddress, tokenAdmin);
        assertGt(claimed, 0);

        uint256 oldBal = tokenAdmin.balance;
        vm.prank(operator);
        _hook().setAgent(user3);

        // fees accrued before the rotation went to the old agent
        assertEq(tokenAdmin.balance - oldBal, accrued);
        assertEq(_hook().agentAccrued(), 0);

        // the grant moved whole, schedule and claimed amount included
        (uint128 oldTotal, , , , ) = vestingVault.grants(tokenAddress, tokenAdmin);
        assertEq(oldTotal, 0);
        (uint128 t, uint128 c, uint64 s, uint64 cl, uint64 d) =
            vestingVault.grants(tokenAddress, user3);
        assertEq(t, total);
        assertEq(c, claimed);
        assertEq(s, start);
        assertEq(cl, cliff);
        assertEq(d, duration);

        vm.prank(tokenAdmin);
        vm.expectRevert(VestingVault.NoGrant.selector);
        vestingVault.claim(tokenAddress);
        vm.warp(block.timestamp + VESTING_DURATION);
        vm.prank(user3);
        vestingVault.claim(tokenAddress);
        assertEq(LGEToken(tokenAddress).balanceOf(user3), total - claimed);

        // escrow spending rights followed the hook's agent
        vm.startPrank(owner);
        inferenceEscrow.setGasCap(1e9);
        inferenceEscrow.setGasBudget(1e9);
        vm.stopPrank();
        vm.prank(tokenAdmin);
        vm.expectRevert(InferenceEscrow.NotAgent.selector);
        inferenceEscrow.fundGas(hookAddress, 1e9);
        vm.prank(user3);
        inferenceEscrow.fundGas(hookAddress, 1e9);
    }

    /// @dev The gas budget is keyed by hook, so rotating cannot reset it.
    function test_gasBudgetSurvivesRotation() public {
        _reachCapSuccessfully();
        vm.startPrank(owner);
        inferenceEscrow.setGasCap(1e9);
        inferenceEscrow.setGasBudget(1e9);
        vm.stopPrank();

        vm.prank(tokenAdmin);
        inferenceEscrow.fundGas(hookAddress, 1e9);

        vm.prank(operator);
        _hook().setAgent(user3);

        vm.prank(user3);
        vm.expectRevert(InferenceEscrow.GasBudgetExceeded.selector);
        inferenceEscrow.fundGas(hookAddress, 1);
    }

    function test_setAgentGuards() public {
        vm.prank(tokenAdmin); // the agent itself can no longer rotate
        vm.expectRevert(LGEHook.NotOperator.selector);
        _hook().setAgent(user3);

        vm.startPrank(operator);
        vm.expectRevert(LGEHook.InvalidAgent.selector);
        _hook().setAgent(address(0));
        vm.expectRevert(LGEHook.InvalidAgent.selector);
        _hook().setAgent(tokenAdmin); // self-rotation would delete the grant
        vm.stopPrank();
    }

    /// @dev Before success there is no grant; rotation must not revert, and the
    ///      grant is later created for the new agent.
    function test_rotationBeforeSuccess() public {
        vm.prank(operator);
        _hook().setAgent(user3);

        _reachCapSuccessfully();
        (uint128 oldTotal, , , , ) = vestingVault.grants(tokenAddress, tokenAdmin);
        (uint128 newTotal, , , , ) = vestingVault.grants(tokenAddress, user3);
        assertEq(oldTotal, 0);
        assertGt(newTotal, 0);
    }

    /// @dev An attacker with its own launch (agent and operator both its own)
    ///      cannot reach another hook's credit. Credit is keyed by hook, so
    ///      the victim's credit is untouched and unreachable. (Launching in the
    ///      victim's name is blocked earlier: see test_launchForOtherAgentReverts.)
    function test_foreignLaunchCannotTakeAgentCredit() public {
        _reachCapSuccessfully();
        address victimHook = hookAddress;
        uint256 victimCredit = inferenceEscrow.creditOf(victimHook);
        assertGt(victimCredit, 0);

        address attacker = address(0xBAD);
        tokenAdmin = attacker;
        operator = attacker;
        startBlock = block.number;
        (, address attackerHook) = _deployWithConfig(_defaultParams());
        assertEq(LGEHook(payable(attackerHook)).agent(), attacker);

        vm.startPrank(owner);
        inferenceEscrow.setGasCap(victimCredit);
        inferenceEscrow.setGasBudget(victimCredit);
        vm.stopPrank();
        vm.startPrank(attacker);
        vm.expectRevert(InferenceEscrow.NotAgent.selector);
        inferenceEscrow.fundGas(victimHook, 1);
        vm.expectRevert(InferenceEscrow.InsufficientCredit.selector);
        inferenceEscrow.fundGas(attackerHook, 1);
        vm.stopPrank();

        assertEq(inferenceEscrow.creditOf(victimHook), victimCredit);
    }

    // ------------------------------------------------------------------
    // Launch rule: one successful launch per agent address
    // ------------------------------------------------------------------

    function test_launchStatusLifecycle() public {
        assertEq(uint8(lgeManager.statusOf(user)), uint8(LGEManager.LaunchStatus.None));
        assertEq(lgeManager.launchOf(tokenAdmin), hookAddress);
        assertEq(uint8(lgeManager.statusOf(tokenAdmin)), uint8(LGEManager.LaunchStatus.Active));
        _reachCapSuccessfully();
        assertEq(uint8(lgeManager.statusOf(tokenAdmin)), uint8(LGEManager.LaunchStatus.Successful));
    }

    function test_launchWhileActiveReverts() public {
        LGEManager.DeploymentConfig memory config = _unminedConfig();
        vm.prank(tokenAdmin);
        vm.expectRevert(LGEManager.LaunchActive.selector);
        lgeManager.deployToken(config);
    }

    function test_secondLaunchAfterSuccessReverts() public {
        _reachCapSuccessfully();
        startBlock = block.number;
        LGEManager.DeploymentConfig memory config = _unminedConfig();
        vm.prank(tokenAdmin);
        vm.expectRevert(LGEManager.AlreadyLaunched.selector);
        lgeManager.deployToken(config);
    }

    /// @dev A failed launch can be retried in one transaction: no finalize,
    ///      withdraw or outcome-recording call first.
    function test_retryAfterFailureIsOneTransaction() public {
        _depositAs(user, 1000e18); // partial fill only
        vm.roll(startBlock + STREAM_BLOCKS + 1);
        assertFalse(_hook().isLgeFinished()); // nobody poked the failed launch
        assertEq(uint8(lgeManager.statusOf(tokenAdmin)), uint8(LGEManager.LaunchStatus.Failed));

        address failedHook = hookAddress;
        startBlock = block.number;
        (, address retryHook) = _deployWithConfig(_defaultParams());
        assertTrue(retryHook != failedHook);
        assertEq(lgeManager.launchOf(tokenAdmin), retryHook);
        assertEq(uint8(lgeManager.statusOf(tokenAdmin)), uint8(LGEManager.LaunchStatus.Active));
    }

    /// @dev The squatting attack: launching in another agent's name would
    ///      block or burn that agent's launch rights.
    function test_launchForOtherAgentReverts() public {
        address victim = address(0x7777);
        tokenAdmin = victim;
        LGEManager.DeploymentConfig memory config = _unminedConfig();
        vm.prank(user);
        vm.expectRevert(LGEManager.NotTokenAdmin.selector);
        lgeManager.deployToken(config);
        assertEq(uint8(lgeManager.statusOf(victim)), uint8(LGEManager.LaunchStatus.None));
    }

    /// @dev launchOf is keyed by the launching address, not hook.agent(), so
    ///      rotating the hook's agent does not free the original address.
    function test_rotationDoesNotUnlockSecondLaunch() public {
        _reachCapSuccessfully();
        vm.prank(operator);
        _hook().setAgent(user3);

        assertEq(uint8(lgeManager.statusOf(tokenAdmin)), uint8(LGEManager.LaunchStatus.Successful));
        startBlock = block.number;
        LGEManager.DeploymentConfig memory config = _unminedConfig();
        vm.prank(tokenAdmin);
        vm.expectRevert(LGEManager.AlreadyLaunched.selector);
        lgeManager.deployToken(config);
    }

    /// @dev The agent's stake must be locked for at least 12 months. Covers the
    ///      no-lock schedule (cliff 0, duration 0) too; a 12-month cliff with a
    ///      zero duration (full unlock at the cliff) is allowed.
    function test_launchRequiresTwelveMonthCliff() public {
        tokenAdmin = address(0x7777); // no prior launch, so only the cliff rule bites
        LGEManager.DeploymentConfig memory config = _unminedConfig();

        uint64[3] memory tooShort = [uint64(0), uint64(30 days), uint64(365 days - 1)];
        for (uint256 i; i < 3; ++i) {
            config.hookConfig.vestingCliff = tooShort[i];
            config.hookConfig.vestingDuration = 0;
            vm.prank(tokenAdmin);
            vm.expectRevert(LGEManager.CliffTooShort.selector);
            lgeManager.deployToken(config);
        }

        // exactly 12 months with zero duration passes the cliff rule (it then
        // fails later, at CREATE2, only because this config has no mined salt)
        config.hookConfig.vestingCliff = 365 days;
        vm.prank(tokenAdmin);
        vm.expectRevert(LGEManager.HookDeployFailed.selector);
        lgeManager.deployToken(config);
    }

    /// @dev Regression for the vesting bypass: only the token's hook may create
    ///      or move that token's grants.
    function test_vaultOnlyTokenHook() public {
        vm.startPrank(user);
        vm.expectRevert(VestingVault.NotHook.selector);
        vestingVault.create(tokenAddress, tokenAdmin, 1, 0, 0);
        vm.expectRevert(VestingVault.NotHook.selector);
        vestingVault.migrateBeneficiary(tokenAddress, tokenAdmin, user);
        vm.stopPrank();
    }

    function test_claimProtocolSweepAndSplits() public {
        // bigger raise so protocol fees clear MIN_SWEEP (25 USDC)
        DeployParams memory p = _defaultParams();
        p.cap = 10_000e18;
        p.minPrice = 1; // 1 token per USDC (raw ratio, both legs 18-dec)
        p.maxPrice = 4;
        (tokenAddress, hookAddress) = _relaunchAsNewAgent(p);
        _reachCapSuccessfully();

        _swapBuyExactInput(12_000e18);

        uint256 accrued = _hook().protocolAccrued();
        assertGe(accrued, 25e18);

        uint256 balBefore = owner.balance;
        _hook().claimProtocol(); // permissionless
        assertEq(owner.balance - balBefore, accrued); // default split: 100% to protocol
        assertEq(_hook().protocolAccrued(), 0);
    }

    function test_claimProtocolBelowMinSweepReverts() public {
        _reachCapSuccessfully(); // tiny raise -> tiny fees

        uint256 usdcIn = _hook().totalUsdcRaised() / 100;
        _swapBuyExactInput(usdcIn);

        vm.expectRevert(LGEHook.BelowMinSweep.selector);
        _hook().claimProtocol();
    }

    function test_splitsTimelock() public {
        _reachCapSuccessfully();

        LGEHook.Split[] memory newSplits = new LGEHook.Split[](2);
        newSplits[0] = LGEHook.Split({to: owner, bps: 5000});
        newSplits[1] = LGEHook.Split({to: user3, bps: 5000});

        vm.prank(owner);
        _hook().proposeSplits(newSplits);

        vm.prank(owner);
        vm.expectRevert(LGEHook.TimelockNotElapsed.selector);
        _hook().applySplits(newSplits);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        _hook().applySplits(newSplits);
        assertEq(_hook().splitsLength(), 2);

        // non-protocol cannot propose
        vm.prank(user3);
        vm.expectRevert(LGEHook.NotProtocol.selector);
        _hook().proposeSplits(newSplits);
    }

    // ------------------------------------------------------------------
    // Lock and exit
    // ------------------------------------------------------------------

    function test_lockTransition() public {
        _reachCapSuccessfully();

        vm.prank(user);
        _hook().claimLiquidity();

        // drive booked fees to just below the raise, then cross with one swap
        uint256 raised = _hook().totalUsdcRaised();
        stdstore
            .target(hookAddress)
            .sig("participantFeesBooked()")
            .checked_write(raised - 1);

        _swapBuyExactInput(raised / 100);

        assertTrue(_hook().lpLocked());

        vm.prank(user);
        vm.expectRevert(LGEHook.LpLockedForever.selector);
        _hook().exitLiquidity();
    }

    function test_exitLiquidityPaysBothLegsAndFees() public {
        _reachCapSuccessfully();

        vm.prank(user);
        uint256 share = _hook().claimLiquidity();
        assertGt(share, 0);

        // book some fees first
        _swapBuyExactInput(_hook().totalUsdcRaised() / 100);

        uint256 claimable = _hook().participantClaimable(user);
        assertGt(claimable, 0);

        uint256 weight = _getUserState(user).usdcToLiquidityDeposited;
        uint256 totalWeightBefore = _hook().totalActiveWeight();

        uint256 usdcBefore = user.balance;
        uint256 tokenBefore = LGEToken(tokenAddress).balanceOf(user);

        vm.prank(user);
        _hook().exitLiquidity();

        // both legs paid out, plus accrued fees
        assertGt(user.balance - usdcBefore, claimable);
        assertGt(LGEToken(tokenAddress).balanceOf(user), tokenBefore);

        // share and weight cleared; future participant claims revert
        assertEq(_hook().lpShares(user), 0);
        assertEq(_getUserState(user).usdcToLiquidityDeposited, 0);
        assertTrue(_getUserState(user).exited);
        assertEq(_hook().totalActiveWeight(), totalWeightBefore - weight);

        vm.prank(user);
        vm.expectRevert(LGEHook.NothingToClaim.selector);
        _hook().claimParticipant();
    }

    function test_exitDisabledWhenThresholdZero() public {
        DeployParams memory p = _defaultParams();
        p.exitThreshold = 0;
        (tokenAddress, hookAddress) = _relaunchAsNewAgent(p);
        _reachCapSuccessfully();

        vm.prank(user);
        _hook().claimLiquidity();

        vm.prank(user);
        vm.expectRevert(LGEHook.ExitDisabled.selector);
        _hook().exitLiquidity();
    }

    function test_exitBlockedWhenVolumeAboveThreshold() public {
        DeployParams memory p = _defaultParams();
        p.exitThreshold = 1; // any booked fee blocks the exit
        (tokenAddress, hookAddress) = _relaunchAsNewAgent(p);
        _reachCapSuccessfully();

        vm.prank(user);
        _hook().claimLiquidity();

        _swapBuyExactInput(_hook().totalUsdcRaised() / 100);

        vm.prank(user);
        vm.expectRevert(LGEHook.ExitThresholdNotMet.selector);
        _hook().exitLiquidity();
    }

    // ------------------------------------------------------------------
    // Vesting + inference escrow
    // ------------------------------------------------------------------

    function test_vestingSchedule() public {
        _reachCapSuccessfully();
        // absolute times from the grant: under via_ir a cached block.timestamp
        // local is re-read after vm.warp, so `t0 + x` would drift
        (uint128 total, , uint64 start, uint64 cliff, ) =
            vestingVault.grants(tokenAddress, tokenAdmin);
        assertEq(cliff, start + VESTING_CLIFF);

        // locked for the whole 12-month cliff
        vm.warp(cliff - 1);
        assertEq(vestingVault.claimable(tokenAddress, tokenAdmin), 0);
        vm.prank(tokenAdmin);
        vm.expectRevert(VestingVault.NothingVested.selector);
        vestingVault.claim(tokenAddress);

        // at the cliff, the elapsed share of the 24-month schedule unlocks: half
        vm.warp(cliff);
        uint128 claimable = vestingVault.claimable(tokenAddress, tokenAdmin);
        assertApproxEqAbs(uint256(claimable), uint256(total) / 2, 2);

        uint256 balBefore = LGEToken(tokenAddress).balanceOf(tokenAdmin);
        vm.prank(tokenAdmin);
        vestingVault.claim(tokenAddress);
        assertEq(
            LGEToken(tokenAddress).balanceOf(tokenAdmin) - balBefore,
            claimable
        );
    }

    function test_inferenceEscrow() public {
        _reachCapSuccessfully();

        uint256 credit = inferenceEscrow.creditOf(hookAddress);
        assertGt(credit, 0);

        // gas funding within the cap
        uint256 gasAmount = credit / 4;
        vm.prank(owner);
        inferenceEscrow.setGasCap(gasAmount);
        vm.prank(owner);
        inferenceEscrow.setGasBudget(gasAmount);
        uint256 balBefore = tokenAdmin.balance;
        vm.prank(tokenAdmin);
        inferenceEscrow.fundGas(hookAddress, gasAmount);
        assertEq(tokenAdmin.balance - balBefore, gasAmount);

        // over the cap reverts (within credit, so the cap is what bites)
        vm.prank(tokenAdmin);
        vm.expectRevert(InferenceEscrow.GasCapExceeded.selector);
        inferenceEscrow.fundGas(hookAddress, gasAmount * 2);

        // provider flow: propose, timelock, apply, pay
        vm.prank(owner);
        inferenceEscrow.proposeProvider(user3);
        vm.prank(owner);
        vm.expectRevert(InferenceEscrow.TimelockNotElapsed.selector);
        inferenceEscrow.applyProvider();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        inferenceEscrow.applyProvider();

        uint256 providerBefore = user3.balance;
        vm.prank(tokenAdmin);
        inferenceEscrow.payProvider(hookAddress, credit / 8);
        assertEq(user3.balance - providerBefore, credit / 8);

        // provider settable once
        vm.prank(owner);
        vm.expectRevert(InferenceEscrow.ProviderAlreadySet.selector);
        inferenceEscrow.proposeProvider(user4);
    }

    /// @dev Regression: gasCap was per call only, so a loop of fundGas calls
    ///      moved the agent's whole credit to its wallet as raw USDC. The
    ///      lifetime gasBudget now stops the loop.
    function test_fundGasLoopStopsAtBudget() public {
        _reachCapSuccessfully();
        uint256 credit = inferenceEscrow.creditOf(hookAddress);
        uint256 perCall = credit / 100;
        uint256 budget = perCall * 3;

        vm.startPrank(owner);
        inferenceEscrow.setGasCap(perCall);
        inferenceEscrow.setGasBudget(budget);
        vm.stopPrank();

        vm.startPrank(tokenAdmin);
        for (uint256 i; i < 3; ++i) inferenceEscrow.fundGas(hookAddress, perCall);
        vm.expectRevert(InferenceEscrow.GasBudgetExceeded.selector);
        inferenceEscrow.fundGas(hookAddress, 1);
        vm.stopPrank();

        assertEq(inferenceEscrow.totalGasFunded(hookAddress), budget);
        assertEq(inferenceEscrow.creditOf(hookAddress), credit - budget);
    }

    function test_fundGasDisabledUntilBudgetSet() public {
        _reachCapSuccessfully();
        vm.prank(owner);
        inferenceEscrow.setGasCap(1e18);

        vm.prank(tokenAdmin);
        vm.expectRevert(InferenceEscrow.GasBudgetExceeded.selector);
        inferenceEscrow.fundGas(hookAddress, 1);
    }

    function test_gasBudgetCanOnlyBeLowered() public {
        vm.startPrank(owner);
        inferenceEscrow.setGasBudget(10e18); // first set: any value
        vm.expectRevert(InferenceEscrow.GasBudgetIncrease.selector);
        inferenceEscrow.setGasBudget(10e18 + 1);
        inferenceEscrow.setGasBudget(5e18); // lowering is allowed
        vm.expectRevert(InferenceEscrow.GasBudgetIncrease.selector);
        inferenceEscrow.setGasBudget(6e18);
        vm.stopPrank();
        assertEq(inferenceEscrow.gasBudget(), 5e18);

        vm.prank(tokenAdmin);
        vm.expectRevert(InferenceEscrow.NotOwner.selector);
        inferenceEscrow.setGasBudget(1);
    }

    // ------------------------------------------------------------------
    // Treasury buy at several raise sizes (DECISIONS.md open question #7)
    // ------------------------------------------------------------------

    function test_treasuryBuyAcrossRaiseSizes() public {
        uint256[3] memory caps = [
            uint256(1_000e18),
            uint256(1_774_544e18),
            uint256(10_000_000e18)
        ];
        for (uint256 i; i < 3; ++i) {
            startBlock = block.number;
            DeployParams memory p = _defaultParams();
            p.cap = caps[i];
            p.minPrice = 1e18;
            p.maxPrice = 4e18;
            (tokenAddress, hookAddress) = _relaunchAsNewAgent(p);
            _reachCapSuccessfully();

            (uint128 total, , , , ) = vestingVault.grants(
                tokenAddress,
                tokenAdmin
            );
            // the 5% buy fills (nearly) completely at every size
            assertApproxEqAbs(
                uint256(total),
                caps[i] / 20,
                caps[i] / 20 / 100 + 2
            );
            assertGt(inferenceEscrow.creditOf(hookAddress), 0);
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _getUserState(
        address userState
    ) internal view returns (LGEHook.UserState memory) {
        (
            uint256 usdcToLiquidityDeposited,
            uint256 remainingUsdcDeposited,
            uint256 tokensToLiquidity,
            uint256 accruedFees,
            uint256 userIndexPaid,
            bool hasClaimedLp,
            bool exited
        ) = _hook().userStates(userState);

        return
            LGEHook.UserState({
                usdcToLiquidityDeposited: usdcToLiquidityDeposited,
                remainingUsdcDeposited: remainingUsdcDeposited,
                tokensToLiquidity: tokensToLiquidity,
                accruedFees: accruedFees,
                userIndexPaid: userIndexPaid,
                hasClaimedLp: hasClaimedLp,
                exited: exited
            });
    }

    function _reachCapSuccessfully() internal {
        uint256 cap = LGEToken(tokenAddress).cap();
        uint256 tokensPerUser = cap / 4;

        vm.roll(startBlock + 1000);
        _depositAs(user, tokensPerUser);

        vm.roll(startBlock + 2000);
        _depositAs(user2, tokensPerUser);

        vm.roll(startBlock + 3000);
        _depositAs(user3, tokensPerUser);

        vm.roll(startBlock + STREAM_BLOCKS);
        _depositAs(user4, tokensPerUser);
    }
}
