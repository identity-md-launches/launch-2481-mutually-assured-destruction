// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MADToken} from "../src/MADToken.sol";

/// @title DeployMADToken
/// @notice Reviewable deployment entry point for MADToken.
/// @dev At launch the IdentityMD factory deploys the token from its creation code, so this script is
/// not what launches it. It exists so the deployment can be reviewed and rehearsed locally (for
/// example against an Anvil fork), and so tests can call `deploy()` directly. The token takes no
/// constructor arguments: whoever calls `deploy()` receives the whole supply. This script never
/// reads environment variables.
contract DeployMADToken is Script {
    /// @notice Deploys a new MADToken. The caller (the broadcasting account, or the factory at
    /// launch) receives the full fixed supply.
    function deploy() public returns (MADToken token) {
        token = new MADToken();
    }

    /// @notice Broadcast entry point for `forge script`.
    function run() external returns (MADToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
