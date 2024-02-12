// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19 <0.9.0;

import { PRBTest } from "@prb/test/PRBTest.sol";
import { console2 } from "forge-std/console2.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { IERC20Metadata as IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IWETH9 } from "src/dependencies/IWETH9.sol";
import { Registry } from "lib/registry/src/Registry.sol";
import { Arrays } from "src/utils/Arrays.sol";

import { IFlashLoaner } from "../src/balancer/interfaces/IFlashLoaner.sol";
import { ISiloLens } from "../src/silo/interfaces/ISiloLens.sol";
import { MockBorrower } from "./MockBorrower.sol";
import { SiloWrapper } from "../src/silo/SiloWrapper.sol";

/// @dev If this is your first time with Forge, read this tutorial in the Foundry Book:
/// https://book.getfoundry.sh/forge/writing-tests
contract SiloWrapperTest is PRBTest, StdCheats {
    using Arrays for uint256;
    using Arrays for address;
    using SafeERC20 for IERC20;

    SiloWrapper internal wrapper;
    MockBorrower internal borrower;
    address internal gmx;
    IFlashLoaner internal balancer;

    ISiloLens public lens;
    IWETH9 internal nativeToken;
    IERC20 internal intermediateToken;

    uint256 internal dust = 1e10;

    /// @dev A function invoked before each test case is run.
    function setUp() public virtual {
        // Revert if there is no API key.
        string memory alchemyApiKey = vm.envOr("API_KEY_ALCHEMY", string(""));
        if (bytes(alchemyApiKey).length == 0) {
            revert("API_KEY_ALCHEMY variable missing");
        }

        vm.createSelectFork({ urlOrAlias: "arbitrum_one", blockNumber: 172_023_656 });
        balancer = IFlashLoaner(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
        gmx = 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;

        lens = ISiloLens(0x07b94eB6AaD663c4eaf083fBb52928ff9A15BE47);
        intermediateToken = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1); // IWETH9

        wrapper = new SiloWrapper(lens, balancer, intermediateToken);
        borrower = new MockBorrower(wrapper);

        // Silo has a rounding issue for which we get 1 wei less than what we deposited
        vm.prank(address(balancer));
        intermediateToken.safeTransfer(address(wrapper), dust);
    }

    /// @dev Basic test. Run it with `forge test -vvv` to see the console log.
    function test_flashFee() external {
        console2.log("test_flashFee");
        assertEq(wrapper.flashFee(gmx, 1e18), 0, "Fee not zero");
    }

    function test_maxFlashLoan() external {
        console2.log("test_maxFlashLoan");
        assertEq(wrapper.maxFlashLoan(gmx), 12_620.330550150872407615e18, "Max flash loan not right");
    }

    function test_maxFlashLoan_unsupportedAsset() external {
        console2.log("test_maxFlashLoan");
        assertEq(wrapper.maxFlashLoan(address(1)), 0, "Max flash loan not right");
    }

    function test_flashFee_unsupportedAsset() external {
        console2.log("test_flashFee");
        vm.expectRevert("Unsupported currency");
        wrapper.flashFee(address(1), 1e18);
    }

    function test_flashFee_insufficientLiquidity() external {
        console2.log("test_flashFee");
        assertEq(wrapper.flashFee(gmx, 20_000e18), type(uint256).max, "Fee not zero");
    }

    function test_flashLoan() external {
        console2.log("test_flashLoan");
        uint256 loan = 10_000e18;
        uint256 fee = wrapper.flashFee(gmx, loan);
        IERC20(gmx).safeTransfer(address(borrower), fee);
        bytes memory result = borrower.flashBorrow(gmx, loan);

        // Test the return values passed through the wrapper
        (bytes32 callbackReturn) = abi.decode(result, (bytes32));
        assertEq(uint256(callbackReturn), uint256(borrower.ERC3156PP_CALLBACK_SUCCESS()), "Callback failed");

        // Test the borrower state during the callback
        assertEq(borrower.flashInitiator(), address(borrower));
        assertEq(address(borrower.flashAsset()), address(gmx));
        assertEq(borrower.flashAmount(), loan);
        assertEq(borrower.flashBalance(), loan + fee); // The amount we transferred to pay for fees, plus the amount we
        // borrowed
        assertEq(borrower.flashFee(), fee);

        assertEq(intermediateToken.balanceOf(address(wrapper)), dust - 1, "Too much dust spent");
    }

    function test_receiveFlashLoan_permissions() public {
        vm.expectRevert(SiloWrapper.NotBalancer.selector);
        wrapper.receiveFlashLoan(address(gmx).toArray(), uint256(1e18).toArray(), uint256(0).toArray(), "");

        vm.prank(address(balancer));
        vm.expectRevert(SiloWrapper.HashMismatch.selector);
        wrapper.receiveFlashLoan(address(gmx).toArray(), uint256(1e18).toArray(), uint256(0).toArray(), "");
    }
}
