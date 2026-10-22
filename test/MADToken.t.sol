// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";
import {DeployMADToken} from "../script/DeployMADToken.s.sol";

/// @notice Stands in for the launch factory: deploys the token's creation code through CREATE2 from
/// its own address, exactly as ProjectFactory.launchCustom does, so the supply lands on it.
contract FactoryStandIn {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }

    function move(MADToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract MADTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    MADToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new MADToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), token.name());
        assertEq(token.TOKEN_SYMBOL(), token.symbol());
        assertEq(token.DECIMALS(), token.decimals());
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new MADToken();
    }

    /// @dev Each deployment is independent: a second deployment mints its own supply to its own deployer
    /// and does not touch the first.
    function test_eachDeploymentMintsToItsOwnDeployer() public {
        vm.prank(alice);
        MADToken second = new MADToken();
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch shape: CREATE2 from a factory, supply held by the factory, flows exact
    // ---------------------------------------------------------------------------------------------

    function test_factoryDeploymentHoldsWholeSupplyAndPaysOutExactly() public {
        FactoryStandIn factory = new FactoryStandIn();
        address predicted =
            vm.computeCreate2Address(bytes32(uint256(7)), keccak256(type(MADToken).creationCode), address(factory));
        address deployed = factory.deploy(type(MADToken).creationCode, bytes32(uint256(7)));
        assertEq(deployed, predicted, "CREATE2 address is not predictable");

        MADToken launched = MADToken(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "factory does not hold the whole supply");

        // Swarm share (10%), pool share (80%) and remainder (10%) all arrive whole.
        uint256 swarm = SUPPLY / 10;
        uint256 pool = (SUPPLY * 8_000) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;
        assertTrue(factory.move(launched, alice, swarm));
        assertTrue(factory.move(launched, bob, pool));
        assertTrue(factory.move(launched, stranger, remainder));
        assertEq(launched.balanceOf(alice), swarm);
        assertEq(launched.balanceOf(bob), pool);
        assertEq(launched.balanceOf(stranger), remainder);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.totalSupply(), SUPPLY, "payout changed the supply");
    }

    function test_deployScriptFunctionMintsToCaller() public {
        DeployMADToken script = new DeployMADToken();
        MADToken deployed = script.deploy();
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.name(), "Mutually Assured Destruction");
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 1_234 ether;
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(alice, bob, 60 ether);
        vm.prank(alice);
        assertTrue(token.approve(bob, 60 ether));
        assertEq(token.allowance(alice, bob), 60 ether);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, stranger, 25 ether));
        assertEq(token.balanceOf(alice), 75 ether);
        assertEq(token.balanceOf(stranger), 25 ether);
        assertEq(token.balanceOf(bob), 0, "spender must not receive anything");
        assertEq(token.allowance(alice, bob), 35 ether, "allowance must decrease by the amount spent");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(deployer, alice, 1 ether);
        assertEq(token.allowance(deployer, bob), type(uint256).max);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(bob, 10 ether);
        token.approve(bob, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, bob), 3 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------------

    function test_RevertWhen_TransferExceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_RevertWhen_DeployerTransfersMoreThanSupply() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_RevertWhen_TransferToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_RevertWhen_TransferFromWithoutAllowance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_RevertWhen_TransferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 5 ether, 5 ether + 1)
        );
        token.transferFrom(deployer, alice, 5 ether + 1);
    }

    function test_RevertWhen_TransferFromExceedsOwnerBalance() public {
        // Allowance is ample but the owner holds nothing.
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, stranger, 1 ether);
    }

    function test_RevertWhen_ApproveZeroAddressSpender() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface: nothing mints, pauses, freezes, seizes or burns on another's behalf
    // ---------------------------------------------------------------------------------------------

    function test_noCallIncreasesSupplyOrGrantsTokens() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "burn(uint256)"
        ];
        address[2] memory callers = [stranger, deployer];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], stranger, type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, string.concat("unexpected function exists: ", signatures[i]));
                assertEq(token.totalSupply(), SUPPLY, signatures[i]);
                assertEq(token.balanceOf(stranger), 0, signatures[i]);
            }
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000 ether);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, string.concat("unexpected function exists: ", signatures[i]));
        }
        // The deployer cannot pull from a holder without an allowance.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);

        assertEq(token.balanceOf(alice), 1_000 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500 ether));
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_RevertWhen_SendingEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token must not accept ether");
        vm.prank(alice);
        (ok,) = address(token).call{value: 1 ether}(abi.encodeWithSignature("transfer(address,uint256)", bob, 0));
        assertFalse(ok, "non-payable function accepted ether");
    }

    // ---------------------------------------------------------------------------------------------
    // Bytecode: size and forbidden opcodes (the launch floor refuses DELEGATECALL/CALLCODE/SELFDESTRUCT)
    // ---------------------------------------------------------------------------------------------

    function test_runtimeIsWithinEip170AndHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
                assertTrue(op != 0xF2, "runtime code contains CALLCODE");
                assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation of supply and exactness of transfers
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupplyAndIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowanceAmount, uint256 spend) public {
        allowanceAmount = bound(allowanceAmount, 0, SUPPLY);
        spend = bound(spend, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(bob, allowanceAmount);
        vm.prank(bob);
        if (spend > allowanceAmount) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowanceAmount, spend)
            );
            token.transferFrom(deployer, alice, spend);
        } else {
            assertTrue(token.transferFrom(deployer, alice, spend));
            assertEq(token.balanceOf(alice), spend);
            assertEq(token.allowance(deployer, bob), allowanceAmount - spend);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }

    function testFuzz_RevertWhen_TransferExceedsBalance(uint256 held, uint256 attempt) public {
        held = bound(held, 0, SUPPLY - 1);
        attempt = bound(attempt, held + 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, attempt));
        token.transfer(bob, attempt);
    }
}
