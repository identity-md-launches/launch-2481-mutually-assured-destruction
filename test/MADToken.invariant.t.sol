// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @notice Drives MADToken with random sequences of transfers, approvals and allowance spends among a
/// fixed set of actors, including calls that must fail. It keeps an independent ledger (ghost balances
/// and allowances) updated only from the ERC-20 specification, never by reading the token after the
/// fact, so the invariants compare the token against what the calls should have done.
contract MADHandler is Test {
    MADToken public immutable token;
    address[] internal actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    /// @dev Counters prove the run exercised each path, so the invariants are not vacuous.
    uint256 public ghostTransfers;
    uint256 public ghostTransferFroms;
    uint256 public ghostApprovals;
    uint256 public ghostExpectedReverts;
    /// @dev Set if any call behaved differently from the specification (wrong revert, wrong success).
    uint256 public ghostViolations;
    /// @dev Set if any successful transfer did not move exactly `amount` between the two parties.
    uint256 public ghostInexactMoves;

    constructor(MADToken token_, address[] memory actors_, address holder) {
        token = token_;
        actors = actors_;
        ghostBalance[holder] = token_.balanceOf(holder);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Amounts favour the interesting edges: zero, the whole balance, one past it, and anything.
    function _amount(uint256 seed, uint256 balance) internal pure returns (uint256) {
        uint256 mode = seed % 5;
        if (mode == 0) return 0;
        if (mode == 1) return balance;
        if (mode == 2) return balance + 1;
        if (mode == 3) return bound(seed >> 8, 0, balance);
        return bound(seed >> 8, 0, 2_000_000_000 ether);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = _amount(amountSeed, balance);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok || amount > balance) ghostViolations++;
            _checkExactMove(from, to, amount, balance, toBefore);
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ghostTransfers++;
        } catch (bytes memory reason) {
            _expect(
                amount > balance,
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
        }
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = _amount(amountSeed, token.balanceOf(from));
        vm.prank(from);
        try token.transfer(address(0), amount) {
            ghostViolations++;
        } catch (bytes memory reason) {
            _expect(true, reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 mode = amountSeed % 4;
        uint256 amount = mode == 0 ? type(uint256).max : mode == 1 ? 0 : bound(amountSeed >> 8, 0, 1_500_000_000 ether);
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) ghostViolations++;
            ghostAllowance[owner][spender] = amount;
            ghostApprovals++;
        } catch {
            ghostViolations++;
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        // Aim at the smaller of the two limits so successes are common, but still cross either edge.
        uint256 amount = _amount(amountSeed, balance < allowed ? balance : allowed);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (!ok || amount > balance || amount > allowed) ghostViolations++;
            _checkExactMove(owner, to, amount, balance, toBefore);
            // The spender gains nothing unless it is itself the owner or the recipient.
            if (spender != owner && spender != to && token.balanceOf(spender) != spenderBefore) ghostViolations++;
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] -= amount;
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            ghostTransferFroms++;
        } catch (bytes memory reason) {
            // Allowance is checked before balance.
            bytes memory expected = amount > allowed
                ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
                : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount);
            _expect(amount > allowed || amount > balance, reason, expected);
        }
    }

    /// @dev Any actor, including the original holder, tries the privileged surface a token might have.
    /// None of it exists, so every call must fail and change nothing.
    function privilegedCall(uint256 callerSeed, uint256 targetSeed, uint256 which) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", caller, 1 ether),
            abi.encodeWithSignature("burn(uint256)", 1),
            abi.encodeWithSignature("burnFrom(address,uint256)", target, 1),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", target),
            abi.encodeWithSignature("transferOwnership(address)", caller),
            abi.encodeWithSignature("seize(address)", target),
            abi.encodeWithSignature("freeze(address)", target)
        ];
        vm.prank(caller);
        (bool ok,) = address(token).call(calls[which % calls.length]);
        if (ok) ghostViolations++;
        ghostExpectedReverts++;
    }

    function _checkExactMove(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore) internal {
        if (from == to) {
            if (token.balanceOf(from) != fromBefore) ghostInexactMoves++;
        } else {
            if (token.balanceOf(from) != fromBefore - amount) ghostInexactMoves++;
            if (token.balanceOf(to) != toBefore + amount) ghostInexactMoves++;
        }
    }

    function _expect(bool shouldRevert, bytes memory reason, bytes memory expected) internal {
        if (!shouldRevert || keccak256(reason) != keccak256(expected)) ghostViolations++;
        ghostExpectedReverts++;
    }
}

/// @notice Invariants of a fixed-supply, fee-free ERC-20 with no privileged surface, checked after
/// every random call sequence the handler drives.
contract MADTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    MADToken internal token;
    MADHandler internal handler;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new MADToken();

        address[] memory actors = new address[](5);
        actors[0] = deployer;
        actors[1] = makeAddr("alice");
        actors[2] = makeAddr("bob");
        actors[3] = makeAddr("carol");
        actors[4] = makeAddr("dave");
        handler = new MADHandler(token, actors, deployer);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = MADHandler.transfer.selector;
        selectors[1] = MADHandler.transferToZero.selector;
        selectors[2] = MADHandler.approve.selector;
        selectors[3] = MADHandler.transferFrom.selector;
        selectors[4] = MADHandler.privilegedCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_actorBalancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, token.totalSupply(), "tokens left the actor set or were created");
        assertEq(token.balanceOf(address(0)), 0, "tokens were sent to the zero address");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchLedger() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actorAt(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance diverged from the specification");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actorAt(i);
                address spender = handler.actorAt(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance diverged from the specification"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyCallBehavedAsSpecified() public view {
        assertEq(handler.ghostViolations(), 0, "a call succeeded or reverted against the specification");
        assertEq(handler.ghostInexactMoves(), 0, "a successful transfer did not move exactly its amount");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noBalanceExceedsSupply() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            assertLe(token.balanceOf(handler.actorAt(i)), SUPPLY);
        }
    }

    /// @dev Records which paths the run reached; read with -vv. Guards against a suite that only ever
    /// hits reverts and therefore checks nothing.
    function afterInvariant() external view {
        assertGt(
            handler.ghostTransfers() + handler.ghostTransferFroms() + handler.ghostApprovals(),
            0,
            "the run never executed a successful state change"
        );
    }
}
