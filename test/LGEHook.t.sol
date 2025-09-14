// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PosmTestSetup} from "./utils/PosmTestSetup.sol";
import {LGEManager} from "../src/LGEManager.sol";
import {LGEHook} from "../src/hooks/LGEHook.sol";
import {LGEToken} from "../src/LGEToken.sol";
import {LGECalculationsLibrary} from "../src/libraries/LGECalculationsLibrary.sol";

import {console} from "forge-std/console.sol";

contract LGEHookTest is Test, PosmTestSetup {
    StateView stateView;

    LGEManager lgeManager;

    address owner = address(0xABCD);
    address tokenAdmin = address(0x1234);
    address tokenCreator = address(0x5678);
    address user = address(0x9ABC);
    address user2 = address(0xDEF0);

    address tokenAddress;
    address hookAddress;

    uint256 startBlock;

    uint256 minTokenPrice = 100_000_000;
    uint256 maxTokenPrice = 10_000_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployPosm(manager);

        _deployLGEManager();
        _deployTokenAndHook();
    }

    function _deployLGEManager() internal {
        lgeManager = new LGEManager(
            manager,
            IPositionManager(address(lpm)),
            IAllowanceTransfer(address(permit2)),
            address(this)
        );
    }

    function _deployTokenAndHook() internal {
        vm.prank(tokenCreator);
        vm.roll(10);

        (tokenAddress, hookAddress) = _deployWithConfig();
        startBlock = block.number;
    }

    function _deployWithConfig() internal returns (address, address) {
        LGEManager.DeploymentConfig memory config;

        config.tokenConfig.tokenAdmin = tokenAdmin;
        config.tokenConfig.name = "Test Token";
        config.tokenConfig.symbol = "TEST";
        config.tokenConfig.image = "https://example.com/image.png";
        config.tokenConfig.metadata = "https://example.com/metadata.json";

        config.hookConfig.minTokenPrice = minTokenPrice;
        config.hookConfig.maxTokenPrice = maxTokenPrice;

        return lgeManager.deployToken(config);
    }

    function test_addLiquidity() public {
        for (uint256 i = startBlock + 1; i <= startBlock + 4999; ) {
            vm.roll(i);
            uint256 tokenAmount = 3_549_088e18;
            uint256 ethPrice = LGECalculationsLibrary
                .calculateCurrentTokenPrice(
                    minTokenPrice,
                    maxTokenPrice,
                    block.number,
                    startBlock
                );
            hoax(user);
            LGEHook(payable(hookAddress)).deposit{
                value: (tokenAmount / ethPrice) * 2
            }(tokenAmount);

            unchecked {
                i += 1;
            }
        }

        console.log("Balance BEFORE:", address(hookAddress).balance);
        vm.roll(startBlock + 5000);
        uint256 tokenAmount1 = 3_549_088e18;
        uint256 ethPrice1 = LGECalculationsLibrary.calculateCurrentTokenPrice(
            minTokenPrice,
            maxTokenPrice,
            block.number,
            startBlock
        );

        // console.log("ETH Amount calculated:", ethAmount);
        hoax(user2);
        LGEHook(payable(hookAddress)).deposit{
            value: (tokenAmount1 / ethPrice1) * 2
        }(tokenAmount1);

        console.log(
            "tokenId:",
            LGEHook(payable(hookAddress)).positionTokenId()
        );
        console.log("Balance:", address(hookAddress).balance);
        console.log(
            "TOKEN Balance:",
            LGEToken(tokenAddress).balanceOf(hookAddress)
        );
        console.log(
            "Liquidity:",
            StateLibrary.getLiquidity(
                manager,
                LGEHook(payable(hookAddress)).getPoolId()
            )
        );

        console.log(
            "Position Liquidity:",
            lpm.getPositionLiquidity(
                LGEHook(payable(hookAddress)).positionTokenId()
            )
        );

        vm.prank(user2);
        uint256 userTokenId = LGEHook(payable(hookAddress)).claimLiquidity();

        console.log("User NFT balance:", userTokenId);
    }
}
