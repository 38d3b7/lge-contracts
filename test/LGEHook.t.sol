// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PosmTestSetup} from "./utils/PosmTestSetup.sol";
import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";
import {LGEToken} from "../src/LGEToken.sol";
import {LGECalculationsLibrary} from "../src/libraries/LGECalculationsLibrary.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

import {console} from "forge-std/console.sol";

contract LGEHookTest is Test, PosmTestSetup {
    uint160 private immutable FLAGS =
        uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG
        );

    LGEManager lgeManager;

    address owner = address(0xABCD);
    address tokenAdmin = address(0x1234);
    address tokenCreator = address(0x5678);

    address user = address(0x9ABC);
    address user2 = address(0xDEF0);
    address user3 = address(0x1111);
    address user4 = address(0x2222);

    address tokenAddress;
    address hookAddress;

    uint256 startBlock;

    uint256 minTokenPrice = 20_000_000_000;
    uint256 maxTokenPrice = 15_000_000_000;

    uint256 constant TOKEN_CAP = 17745440000e18;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployPosm(manager);

        _deployLGEManager();
        _deployTokenAndHook();
    }

    function _deployLGEManager() internal {
        lgeManager = new LGEManager(
            address(manager),
            address(lpm),
            address(permit2)
        );
    }

    function _deployTokenAndHook() internal {
        vm.prank(tokenCreator);
        vm.roll(31160653);

        startBlock = block.number;
        (tokenAddress, hookAddress) = _deployWithConfig();
    }

    function _deployWithConfig() internal returns (address, address) {
        LGEManager.DeploymentConfig memory config;

        config.tokenConfig.tokenAdmin = tokenAdmin;
        config.tokenConfig.name = "Test Token";
        config.tokenConfig.symbol = "TEST";
        config.tokenConfig.image = "https://example.com/image.png";
        config.tokenConfig.metadata = "https://example.com/metadata.json";
        config.tokenConfig.tokenSalt = keccak256(
            abi.encodePacked(tokenAdmin, block.timestamp)
        );

        bytes memory tokenConstructorArgs = abi.encode(
            config.tokenConfig.name,
            config.tokenConfig.symbol,
            config.tokenConfig.tokenAdmin,
            config.tokenConfig.image,
            config.tokenConfig.metadata,
            address(lgeManager)
        );

        address tokenAddressComputed = vm.computeCreate2Address(
            config.tokenConfig.tokenSalt,
            hashInitCode(type(LGEToken).creationCode, tokenConstructorArgs),
            address(lgeManager)
        );

        bytes memory constructorArgs = abi.encode(
            address(manager),
            address(lpm),
            address(permit2),
            tokenAddressComputed,
            startBlock,
            minTokenPrice,
            maxTokenPrice
        );

        (, bytes32 salt) = HookMiner.find(
            address(lgeManager),
            FLAGS,
            type(LGEHook).creationCode,
            constructorArgs
        );

        config.hookConfig.minTokenPrice = minTokenPrice;
        config.hookConfig.maxTokenPrice = maxTokenPrice;
        config.hookConfig.hookSalt = salt;
        config.hookConfig.startBlock = startBlock;

        return lgeManager.deployToken(config);
    }

    function calculateETHNeeded(
        uint256 tokenAmount
    ) internal view returns (uint256) {
        uint256 ethPerToken = LGECalculationsLibrary.calculateCurrentTokenPrice(
            minTokenPrice,
            maxTokenPrice,
            block.number,
            startBlock
        );
        return (tokenAmount / ethPerToken) * 2;
    }

    function test_depositSuccess() public {
        uint256 tokenAmount = 3_549_088e18;
        uint256 ethNeeded = calculateETHNeeded(tokenAmount);
        hoax(user);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded}(tokenAmount);

        LGEHook.UserState memory userState = _getUserState(user);

        assertEq(address(LGEHook(payable(hookAddress))).balance, ethNeeded);
        assertEq(userState.ethToLiquidityDeposited, ethNeeded / 2);
        assertEq(userState.remainingEthDeposited, ethNeeded / 2);
        assertEq(userState.tokensToLiquidity, tokenAmount);
        assertFalse(userState.hasClaimed);
    }

    function test_depositInvalidPriceRevert() public {
        uint256 tokenAmount = 3_549_088e18;
        uint256 ethNeeded = calculateETHNeeded(tokenAmount);
        hoax(user);
        vm.expectRevert(LGEHook.InvalidPrice.selector);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded - 1}(
            tokenAmount
        );
    }

    function test_depostAfterLGEFinishedRevert() public {
        _reachCapSuccessfully();

        vm.roll(startBlock + 5001);
        uint256 tokenAmount = 100e18;
        uint256 ethNeeded = calculateETHNeeded(tokenAmount);

        hoax(user);
        vm.expectRevert(LGEHook.LGEFinished.selector);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded}(tokenAmount);
    }

    function test_depositMultipleUsers() public {
        vm.roll(startBlock + 100);

        uint256 tokenAmount1 = 1000e18;
        uint256 ethNeeded1 = calculateETHNeeded(tokenAmount1);
        hoax(user);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded1}(tokenAmount1);

        vm.roll(startBlock + 200);
        uint256 tokenAmount2 = 2000e18;
        uint256 ethNeeded2 = calculateETHNeeded(tokenAmount2);
        hoax(user2);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded2}(tokenAmount2);

        LGEHook.UserState memory user1State = _getUserState(user);
        assertEq(user1State.tokensToLiquidity, tokenAmount1);

        LGEHook.UserState memory user2State = _getUserState(user2);
        assertEq(user2State.tokensToLiquidity, tokenAmount2);

        assertEq(
            LGEHook(payable(hookAddress)).totalTokensClaimed(),
            tokenAmount1 + tokenAmount2
        );
        assertEq(LGEHook(payable(hookAddress)).totalDeposits(), 2);
    }

    function test_depositPriceChangesOverTime() public {
        uint256 tokenAmount = 1000e18;

        vm.roll(startBlock + 100);
        uint256 earlyPrice = calculateETHNeeded(tokenAmount);

        vm.roll(startBlock + 4000);
        uint256 latePrice = calculateETHNeeded(tokenAmount);

        console.log("earlyPrice:", earlyPrice);
        console.log("latePrice:", latePrice);
        assertTrue(latePrice < earlyPrice);
    }

    function test_LGESuccess() public {
        _reachCapSuccessfully();

        assertTrue(LGEHook(payable(hookAddress)).isLgeSuccessful());
        assertTrue(LGEHook(payable(hookAddress)).isLgeFinished());

        uint256 liquidity = LGEHook(payable(hookAddress)).totalLiquidity();
        assertTrue(liquidity > 0);

        uint256 positionId = LGEHook(payable(hookAddress)).positionTokenId();
        assertTrue(positionId > 0);
    }

    function test_LGEFailedPartialCapReached() public {
        vm.roll(startBlock + 100);
        uint256 tokenAmount = 1000e18; // Much less than cap
        uint256 ethNeeded = calculateETHNeeded(tokenAmount);

        hoax(user);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded}(tokenAmount);

        vm.roll(startBlock + 5000);
        uint256 ethNeeded1 = calculateETHNeeded(tokenAmount);
        hoax(user2);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded1}(tokenAmount);

        assertFalse(LGEHook(payable(hookAddress)).isLgeSuccessful());
        assertTrue(LGEHook(payable(hookAddress)).isLgeFinished());
    }

    function test_withdrawAfterLGEFailed() public {
        vm.roll(startBlock + 100);
        uint256 tokenAmount = 1000e18;
        uint256 ethNeeded = calculateETHNeeded(tokenAmount);

        hoax(user);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded}(tokenAmount);

        vm.roll(startBlock + 5000);
        uint256 ethNeeded1 = calculateETHNeeded(tokenAmount);
        hoax(user2);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded1}(tokenAmount);

        uint256 balanceBefore = user.balance;

        vm.prank(user);
        LGEHook(payable(hookAddress)).withdraw();

        assertEq(user.balance - balanceBefore, ethNeeded);

        LGEHook.UserState memory userState = _getUserState(user);
        assertEq(userState.ethToLiquidityDeposited, 0);
        assertEq(userState.remainingEthDeposited, 0);
    }

    function test_withdrawTooEarlyRevert() public {
        vm.roll(startBlock + 100);
        uint256 tokenAmount = 1000e18;
        uint256 ethNeeded = calculateETHNeeded(tokenAmount);

        hoax(user);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded}(tokenAmount);

        vm.roll(startBlock + 4999);
        vm.prank(user);
        vm.expectRevert(LGEHook.WithdrawTooEarly.selector);
        LGEHook(payable(hookAddress)).withdraw();
    }

    function test_withdrawAfterSuccessfullLGERevert() public {
        _reachCapSuccessfully();

        vm.prank(user);
        vm.expectRevert(LGEHook.CannotWithdrawETH.selector);
        LGEHook(payable(hookAddress)).withdraw();
    }

    function test_withdrawNoDepositRevert() public {
        vm.roll(startBlock + 5001);

        vm.prank(user3);
        vm.expectRevert(LGEHook.NoETHDeposited.selector);
        LGEHook(payable(hookAddress)).withdraw();
    }

    function test_claimLiquiditySuccess() public {
        _reachCapSuccessfully();

        vm.prank(user);
        uint256 userPositionId = LGEHook(payable(hookAddress)).claimLiquidity();

        assertTrue(userPositionId > 0);

        uint128 userPositionLiquidity = lpm.getPositionLiquidity(
            userPositionId
        );

        assertTrue(userPositionLiquidity > 0);

        console.log("Position ID:", userPositionId);
        console.log("User Position Liquidity: ", userPositionLiquidity);

        LGEHook.UserState memory userState = _getUserState(user);
        assertTrue(userState.hasClaimed);
        assertEq(userState.ethToLiquidityDeposited, 0);
    }

    function test_claimLiquidityMultipleClaims() public {
        _reachCapSuccessfully();

        vm.prank(user);
        uint256 position1 = LGEHook(payable(hookAddress)).claimLiquidity();

        vm.prank(user2);
        uint256 position2 = LGEHook(payable(hookAddress)).claimLiquidity();

        assertTrue(position1 != position2);
    }

    function test_claimLiquidityDoubleClaimRevert() public {
        _reachCapSuccessfully();

        vm.prank(user);
        LGEHook(payable(hookAddress)).claimLiquidity();

        vm.prank(user);
        vm.expectRevert(LGEHook.AlreadyClaimed.selector);
        LGEHook(payable(hookAddress)).claimLiquidity();
    }

    // function test_claimLiquidityBeforeEndBlockRevert() public {
    //     vm.roll(startBlock + 4000);
    //     _depositToReachCap();

    //     vm.prank(user);
    //     vm.expectRevert(LGEHook.CannotClaimLiquidity.selector);
    //     LGEHook(payable(hookAddress)).claimLiquidity();
    // }

    function _getUserState(
        address userState
    ) internal view returns (LGEHook.UserState memory) {
        (
            uint256 ethToLiquidityDeposited,
            uint256 remainingEthDeposited,
            uint256 tokensToLiquidity,
            bool hasClaimed
        ) = LGEHook(payable(hookAddress)).userStates(userState);

        return
            LGEHook.UserState({
                ethToLiquidityDeposited: ethToLiquidityDeposited,
                remainingEthDeposited: remainingEthDeposited,
                tokensToLiquidity: tokensToLiquidity,
                hasClaimed: hasClaimed
            });
    }

    function _reachCapSuccessfully() internal {
        uint256 tokensPerUser = TOKEN_CAP / 4;

        vm.roll(startBlock + 1000);
        uint256 eth1 = calculateETHNeeded(tokensPerUser);
        vm.deal(user, eth1);
        vm.prank(user);
        LGEHook(payable(hookAddress)).deposit{value: eth1}(tokensPerUser);

        vm.roll(startBlock + 2000);
        uint256 eth2 = calculateETHNeeded(tokensPerUser);
        vm.deal(user2, eth2);
        vm.prank(user2);
        LGEHook(payable(hookAddress)).deposit{value: eth2}(tokensPerUser);

        vm.roll(startBlock + 3000);
        uint256 eth3 = calculateETHNeeded(tokensPerUser);
        vm.deal(user3, eth3);
        vm.prank(user3);
        LGEHook(payable(hookAddress)).deposit{value: eth3}(tokensPerUser);

        vm.roll(startBlock + 5000);
        uint256 eth4 = calculateETHNeeded(tokensPerUser);
        vm.deal(user4, eth4);
        vm.prank(user4);
        LGEHook(payable(hookAddress)).deposit{value: eth4}(tokensPerUser);
    }

    function _depositToReachCap() internal {
        uint256 remaining = TOKEN_CAP -
            LGEHook(payable(hookAddress)).totalTokensClaimed();
        uint256 ethNeeded = calculateETHNeeded(remaining);

        hoax(user4);
        LGEHook(payable(hookAddress)).deposit{value: ethNeeded}(remaining);
    }
}
