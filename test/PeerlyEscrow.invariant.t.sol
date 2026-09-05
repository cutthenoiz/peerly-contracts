// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PeerlyEscrow} from "../src/PeerlyEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {EscrowHandler} from "./handlers/EscrowHandler.sol";

/// @notice Core solvency guarantee: the contract must always hold enough of each
/// token to cover every active offer's escrowed amount for that token.
contract PeerlyEscrowInvariantTest is Test {
    PeerlyEscrow escrow;
    MockERC20 tokenA;
    MockERC20 tokenB;
    EscrowHandler handler;

    function setUp() public {
        escrow = new PeerlyEscrow(makeAddr("owner"), makeAddr("feeRecipient"), 100);
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");

        handler = new EscrowHandler(escrow, tokenA, tokenB);
        targetContract(address(handler));
    }

    function invariant_contractHoldsEnoughToCoverActiveOffers() public view {
        assertGe(tokenA.balanceOf(address(escrow)), handler.ghost_escrowedByToken(address(tokenA)));
        assertGe(tokenB.balanceOf(address(escrow)), handler.ghost_escrowedByToken(address(tokenB)));
    }
}
