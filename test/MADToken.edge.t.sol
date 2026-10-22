// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @notice Edge cases and failure paths the base suite does not pin: the zero address as sender,
/// owner-initiated transferFrom, allowance at its extremes, and fuzzed allowance/transfer properties.
contract MADTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MADToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new MADToken();
    }

    function test_onlyOneMintEverHappened() public {
        // A fresh deployment emits exactly one Transfer, from the zero address, for the whole supply.
        vm.recordLogs();
        vm.prank(alice);
        MADToken fresh = new MADToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_RevertWhen_OwnerUsesTransferFromWithoutSelfAllowance() public {
        // transferFrom always spends an allowance, even when the caller is the owner.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_ownerTransferFromWithSelfAllowance() public {
        vm.startPrank(deployer);
        token.approve(deployer, 10 ether);
        assertTrue(token.transferFrom(deployer, alice, 4 ether));
        vm.stopPrank();
        assertEq(token.allowance(deployer, deployer), 6 ether);
        assertEq(token.balanceOf(alice), 4 ether);
    }

    function test_RevertWhen_TransferFromZeroAddressOwner() public {
        // Spending a finite allowance writes it back through _approve, which refuses the zero owner
        // before the transfer's own sender check is reached.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function test_RevertWhen_TransferFromToZeroAddress() public {
        vm.prank(deployer);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, bob), 1 ether, "a reverted call must not spend the allowance");
    }

    function test_RevertWhen_ApproveFromZeroAddress() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(bob, 1);
    }

    function test_zeroAmountTransferFromWithNoAllowanceSucceeds() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(deployer, alice, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, bob), 0);
    }

    function test_allowanceOneBelowMaxIsDecremented() public {
        vm.prank(deployer);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.allowance(deployer, bob), type(uint256).max - 2);
    }

    function test_infiniteAllowanceStillBoundedByBalance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_RevertWhen_TransferMaxUint() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_revokeAllowanceBlocksFurtherSpend() public {
        vm.prank(deployer);
        token.approve(bob, 5 ether);
        vm.prank(deployer);
        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_RevertWhen_UnknownSelectorOrCalldata() public {
        (bool ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok);
        (ok,) = address(token).call(hex"");
        assertFalse(ok);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_selfTransferIsNoOp(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromCheckedAgainstBothLimits(uint256 held, uint256 allowed, uint256 spend) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, SUPPLY);
        spend = bound(spend, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.prank(bob);
        if (spend > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, spend)
            );
            token.transferFrom(alice, deployer, spend);
        } else if (spend > held) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, spend));
            token.transferFrom(alice, deployer, spend);
        } else {
            assertTrue(token.transferFrom(alice, deployer, spend));
            assertEq(token.balanceOf(alice), held - spend);
            assertEq(token.allowance(alice, bob), allowed - spend);
            assertEq(token.balanceOf(bob), 0);
            return;
        }
        // Failure leaves everything untouched.
        assertEq(token.balanceOf(alice), held);
        assertEq(token.allowance(alice, bob), allowed);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveSetsExactValue(address spender, uint256 amount) public {
        spender = address(uint160(bound(uint160(spender), 1, type(uint160).max)));
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(alice, spender, amount);
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(alice, spender), amount);
    }
}
