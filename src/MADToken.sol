// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mutually Assured Destruction (MAD)
/// @notice A plain, fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`), which at launch is the IdentityMD ProjectFactory. The factory then pays
/// the supply out: the swarm's share to the launch's MerkleDistributor, the pool share into the
/// Uniswap v4 pool, and the remainder to the requester.
/// @dev Deliberately minimal:
///  - no owner, admin, minter or upgrade path: the supply can never grow after deployment;
///  - no pause, blacklist, freeze, seize or fee-on-transfer: a transfer always moves exactly `amount`;
///  - no `selfdestruct`, `delegatecall` or external calls of any kind.
/// Every transfer rule is the unmodified OpenZeppelin v5 ERC20 implementation.
contract MADToken is ERC20 {
    /// @notice Token name as returned by `name()`.
    string public constant TOKEN_NAME = "Mutually Assured Destruction";

    /// @notice Token symbol as returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "MAD";

    /// @notice Number of decimals (the ERC-20 default, 18).
    uint8 public constant DECIMALS = 18;

    /// @notice The fixed total supply in minor units: 1,000,000,000 MAD with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints the entire fixed supply to the deployer.
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain and the
    /// launch manifest needs no constructor arguments for it.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
