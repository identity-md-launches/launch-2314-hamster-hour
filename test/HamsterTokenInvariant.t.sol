// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @dev Finite holder set allows an independent sum-of-balances invariant after arbitrary action sequences.
contract TokenHandler is Test {
    HamsterToken public immutable token;
    address[4] public holders;

    constructor(HamsterToken token_) {
        token = token_;
        holders = [makeAddr("holder 0"), makeAddr("holder 1"), makeAddr("holder 2"), makeAddr("holder 3")];
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = holders[fromSeed % 4];
        address to = holders[toSeed % 4];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount) external {
        address owner = holders[ownerSeed % 4];
        vm.prank(owner);
        token.approve(holders[spenderSeed % 4], amount);
    }

    function transferFrom(uint8 fromSeed, uint8 toSeed, uint8 spenderSeed, uint256 amountSeed) external {
        address from = holders[fromSeed % 4];
        address to = holders[toSeed % 4];
        address spender = holders[spenderSeed % 4];
        uint256 limit = token.balanceOf(from);
        uint256 allowance = token.allowance(from, spender);
        if (allowance < limit) limit = allowance;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        token.transferFrom(from, to, amount);
    }
}

contract HamsterTokenInvariantTest is Test {
    HamsterToken private token;
    TokenHandler private handler;

    function setUp() public {
        token = new HamsterToken();
        handler = new TokenHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.holders(i), token.INITIAL_SUPPLY() / 4);
        }
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyAndSumOfBalancesNeverChange() public view {
        uint256 balances;
        for (uint256 i; i < 4; ++i) {
            balances += token.balanceOf(handler.holders(i));
        }
        assertEq(balances, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }
}
