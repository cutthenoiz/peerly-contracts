// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PeerlyEscrow} from "../src/PeerlyEscrow.sol";

/// @dev Reads deployment params from env vars so the same script targets any chain:
/// OWNER, FEE_RECIPIENT (addresses), FEE_BPS (uint16, e.g. 100 = 1%).
contract Deploy is Script {
    function run() external returns (PeerlyEscrow escrow) {
        address ownerAddr = vm.envAddress("OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint16 feeBps = uint16(vm.envUint("FEE_BPS"));

        vm.startBroadcast();
        escrow = new PeerlyEscrow(ownerAddr, feeRecipient, feeBps);
        vm.stopBroadcast();

        console.log("PeerlyEscrow deployed at:", address(escrow));
    }
}
