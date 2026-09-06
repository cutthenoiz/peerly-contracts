// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PeerlyEscrow} from "../src/PeerlyEscrow.sol";

/// @dev Owner-only admin actions on a deployed PeerlyEscrow. Reads env vars:
/// ESCROW (address), ACTION (one of: pause, unpause, pauseDeposits, unpauseDeposits).
contract Pause is Script {
    function run() external {
        PeerlyEscrow escrow = PeerlyEscrow(vm.envAddress("ESCROW"));
        string memory action = vm.envString("ACTION");

        vm.startBroadcast();
        if (_eq(action, "pause")) {
            escrow.pause();
        } else if (_eq(action, "unpause")) {
            escrow.unpause();
        } else if (_eq(action, "pauseDeposits")) {
            escrow.setDepositsPaused(true);
        } else if (_eq(action, "unpauseDeposits")) {
            escrow.setDepositsPaused(false);
        } else {
            revert("ACTION must be one of: pause, unpause, pauseDeposits, unpauseDeposits");
        }
        vm.stopBroadcast();

        console.log("ACTION executed:", action);
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
