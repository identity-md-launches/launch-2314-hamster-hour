// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

contract TokenFactory {
    function deploy() external returns (HamsterToken) {
        return new HamsterToken();
    }
}

contract HamsterTokenTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 private constant SUPPLY = 1_000_000_000 ether;
    HamsterToken private token;
    address private alice;
    address private bob;

    function setUp() public {
        token = new HamsterToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_metadataAndExactFixedSupply() public view {
        assertEq(token.name(), "Hamster Hour");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_factoryReceivesEverythingAndOriginReceivesNothing() public {
        TokenFactory factory = new TokenFactory();
        vm.prank(alice, bob);
        HamsterToken launched = factory.deploy();
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new HamsterToken();
    }

    function test_transferEmitsEventAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 1 ether);
        assertTrue(token.transfer(alice, 1 ether));
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address recipient, uint256 amountSeed) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        uint256 amount = bound(amountSeed, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroAndSelfTransfersAreStandardERC20() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_approveEmitsEventAndTransferFromSpendsAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), alice, 20 ether);
        assertTrue(token.approve(alice, 20 ether));
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 7 ether));
        assertEq(token.allowance(address(this), alice), 13 ether);
        assertEq(token.balanceOf(bob), 7 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 7 ether);
    }

    function test_maximumAllowanceRetainsStandardInfiniteApprovalBehavior() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_revokedApprovalCannotSpend() public {
        token.approve(alice, 1 ether);
        token.approve(alice, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFailsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromCannotExceedAllowance() public {
        token.approve(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 1, 2));
        token.transferFrom(address(this), bob, 2);
        assertEq(token.allowance(address(this), alice), 1);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_failedTransferFromRestoresAllowance() public {
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10));
        token.transferFrom(alice, address(this), 10);
        assertEq(token.allowance(alice, bob), 10);
    }

    function test_zeroRecipientAndZeroSpenderRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_neitherDeployerNorHolderHasMintBurnPauseOrUpgradeEntryPoints() public {
        bytes[9] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether),
            abi.encodeWithSignature("burn(uint256)", 1 ether),
            abi.encodeWithSignature("burnFrom(address,uint256)", address(this), 1 ether),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("setFee(uint256)", 1),
            abi.encodeWithSignature("blacklist(address)", bob),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("upgradeTo(address)", alice)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerOk,) = address(token).call(calls[i]);
            vm.prank(alice);
            (bool holderOk,) = address(token).call(calls[i]);
            assertFalse(deployerOk);
            assertFalse(holderOk);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
