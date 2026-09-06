// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PeerlyEscrow} from "../src/PeerlyEscrow.sol";
import {MockERC20, FeeOnTransferERC20} from "./mocks/MockERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PeerlyEscrowTest is Test {
    PeerlyEscrow escrow;
    MockERC20 tokenA; // sell side
    MockERC20 tokenB; // buy/quote side

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address offerer = makeAddr("offerer");
    address taker = makeAddr("taker");

    uint16 constant FEE_BPS = 100; // 1%

    function setUp() public {
        escrow = new PeerlyEscrow(owner, feeRecipient, FEE_BPS);
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");

        tokenA.mint(offerer, 1_000 ether);
        tokenB.mint(taker, 1_000 ether);

        vm.prank(offerer);
        tokenA.approve(address(escrow), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(escrow), type(uint256).max);
    }

    function _createOffer(uint256 amountSell, uint256 amountBuy) internal returns (uint256 offerId) {
        vm.prank(offerer);
        offerId = escrow.createOffer(address(tokenA), amountSell, address(tokenB), amountBuy);
    }

    // ---------- createOffer ----------

    function test_createOffer_escrowsTokensAndStoresOffer() public {
        uint256 offererBalBefore = tokenA.balanceOf(offerer);

        uint256 offerId = _createOffer(100 ether, 50 ether);

        (address off, address tSell, uint256 aSell, address tBuy, uint256 aBuy, bool active) = escrow.offers(offerId);
        assertEq(off, offerer);
        assertEq(tSell, address(tokenA));
        assertEq(aSell, 100 ether);
        assertEq(tBuy, address(tokenB));
        assertEq(aBuy, 50 ether);
        assertTrue(active);

        assertEq(tokenA.balanceOf(offerer), offererBalBefore - 100 ether);
        assertEq(tokenA.balanceOf(address(escrow)), 100 ether);
        assertEq(escrow.nextOfferId(), offerId + 1);
    }

    function test_createOffer_revertsOnZeroAmountSell() public {
        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.ZeroAmount.selector);
        escrow.createOffer(address(tokenA), 0, address(tokenB), 50 ether);
    }

    function test_createOffer_revertsOnZeroAmountBuy() public {
        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.ZeroAmount.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 0);
    }

    function test_createOffer_revertsOnSameToken() public {
        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.SameToken.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenA), 50 ether);
    }

    function test_createOffer_revertsWhenPaused() public {
        vm.prank(owner);
        escrow.pause();

        vm.prank(offerer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 50 ether);
    }

    function test_createOffer_feeOnTransferToken_recordsActualReceivedAmount() public {
        FeeOnTransferERC20 deflationary = new FeeOnTransferERC20("Deflate", "DEF", 1000); // 10% burn on transfer
        deflationary.mint(offerer, 1_000 ether);
        vm.prank(offerer);
        deflationary.approve(address(escrow), type(uint256).max);

        vm.prank(offerer);
        uint256 offerId = escrow.createOffer(address(deflationary), 100 ether, address(tokenB), 50 ether);

        (,, uint256 aSell,,,) = escrow.offers(offerId);
        assertEq(aSell, 90 ether, "recorded amountSell must equal actual balance received, not requested");
        assertEq(deflationary.balanceOf(address(escrow)), 90 ether);
    }

    // ---------- cancelOffer ----------

    function test_cancelOffer_returnsEscrowedTokens() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);
        uint256 offererBalBefore = tokenA.balanceOf(offerer);

        vm.prank(offerer);
        escrow.cancelOffer(offerId);

        (,,,,, bool active) = escrow.offers(offerId);
        assertFalse(active);
        assertEq(tokenA.balanceOf(offerer), offererBalBefore + 100 ether);
        assertEq(tokenA.balanceOf(address(escrow)), 0);
    }

    function test_cancelOffer_revertsForNonOfferer() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);

        vm.prank(taker);
        vm.expectRevert(PeerlyEscrow.NotOfferer.selector);
        escrow.cancelOffer(offerId);
    }

    function test_cancelOffer_revertsIfAlreadyCancelled() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);

        vm.prank(offerer);
        escrow.cancelOffer(offerId);

        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.OfferNotActive.selector);
        escrow.cancelOffer(offerId);
    }

    function test_cancelOffer_revertsIfAlreadyTaken() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);
        vm.prank(taker);
        escrow.takeOffer(offerId);

        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.OfferNotActive.selector);
        escrow.cancelOffer(offerId);
    }

    function test_cancelOffer_worksWhilePaused() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);

        vm.prank(owner);
        escrow.pause();

        vm.prank(offerer);
        escrow.cancelOffer(offerId); // must not revert: pause can never trap funds

        (,,,,, bool active) = escrow.offers(offerId);
        assertFalse(active);
    }

    // ---------- takeOffer ----------

    function test_takeOffer_settlesTradeAndFee() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);

        uint256 offererBBefore = tokenB.balanceOf(offerer);
        uint256 takerABefore = tokenA.balanceOf(taker);
        uint256 recipientBBefore = tokenB.balanceOf(feeRecipient);

        vm.prank(taker);
        escrow.takeOffer(offerId);

        uint256 amountBuy = 50 ether;
        uint256 expectedFee = (amountBuy * FEE_BPS) / 10_000;

        assertEq(tokenB.balanceOf(offerer), offererBBefore + 50 ether - expectedFee);
        assertEq(tokenB.balanceOf(feeRecipient), recipientBBefore + expectedFee);
        assertEq(tokenA.balanceOf(taker), takerABefore + 100 ether);
        assertEq(tokenA.balanceOf(address(escrow)), 0);

        (,,,,, bool active) = escrow.offers(offerId);
        assertFalse(active);
    }

    function test_takeOffer_zeroFeeSendsFullAmountToOfferer() public {
        vm.prank(owner);
        escrow.setFee(0);

        uint256 offerId = _createOffer(100 ether, 50 ether);
        uint256 offererBBefore = tokenB.balanceOf(offerer);

        vm.prank(taker);
        escrow.takeOffer(offerId);

        assertEq(tokenB.balanceOf(offerer), offererBBefore + 50 ether);
        assertEq(tokenB.balanceOf(feeRecipient), 0);
    }

    function test_takeOffer_revertsIfInactive() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);
        vm.prank(offerer);
        escrow.cancelOffer(offerId);

        vm.prank(taker);
        vm.expectRevert(PeerlyEscrow.OfferNotActive.selector);
        escrow.takeOffer(offerId);
    }

    function test_takeOffer_revertsIfAlreadyTaken() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);
        vm.prank(taker);
        escrow.takeOffer(offerId);

        address secondTaker = makeAddr("secondTaker");
        tokenB.mint(secondTaker, 100 ether);
        vm.prank(secondTaker);
        tokenB.approve(address(escrow), type(uint256).max);

        vm.prank(secondTaker);
        vm.expectRevert(PeerlyEscrow.OfferNotActive.selector);
        escrow.takeOffer(offerId);
    }

    function test_takeOffer_revertsWhenPaused() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);

        vm.prank(owner);
        escrow.pause();

        vm.prank(taker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.takeOffer(offerId);
    }

    // ---------- owner controls ----------

    function test_setFee_revertsAboveCeiling() public {
        uint16 tooHigh = escrow.MAX_FEE_BPS() + 1;

        vm.prank(owner);
        vm.expectRevert(PeerlyEscrow.FeeTooHigh.selector);
        escrow.setFee(tooHigh);
    }

    function test_setFee_revertsForNonOwner() public {
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, taker));
        escrow.setFee(200);
    }

    function test_setFeeRecipient_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PeerlyEscrow.ZeroAddress.selector);
        escrow.setFeeRecipient(address(0));
    }

    function test_constructor_revertsOnFeeAboveCeiling() public {
        vm.expectRevert(PeerlyEscrow.FeeTooHigh.selector);
        new PeerlyEscrow(owner, feeRecipient, 501);
    }

    function test_constructor_revertsOnZeroFeeRecipient() public {
        vm.expectRevert(PeerlyEscrow.ZeroAddress.selector);
        new PeerlyEscrow(owner, address(0), FEE_BPS);
    }

    function test_setFeeRecipient_updatesRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(owner);
        escrow.setFeeRecipient(newRecipient);

        assertEq(escrow.feeRecipient(), newRecipient);
    }

    function test_unpause_reenablesCreateAndTakeOffer() public {
        vm.startPrank(owner);
        escrow.pause();
        escrow.unpause();
        vm.stopPrank();

        uint256 offerId = _createOffer(100 ether, 50 ether);

        vm.prank(taker);
        escrow.takeOffer(offerId);

        (,,,,, bool active) = escrow.offers(offerId);
        assertFalse(active);
    }

    function test_createOffer_revertsWhenTransferDeliversZero() public {
        FeeOnTransferERC20 fullyTaxed = new FeeOnTransferERC20("FullTax", "TAX", 10_000); // 100% burn
        fullyTaxed.mint(offerer, 1_000 ether);
        vm.prank(offerer);
        fullyTaxed.approve(address(escrow), type(uint256).max);

        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.ZeroAmount.selector);
        escrow.createOffer(address(fullyTaxed), 100 ether, address(tokenB), 50 ether);
    }

    // ---------- fuzz ----------

    function testFuzz_takeOffer_feeMathNeverExceedsAmountBuy(uint256 amountSell, uint256 amountBuy, uint16 feeBps)
        public
    {
        amountSell = bound(amountSell, 1, 1_000 ether);
        amountBuy = bound(amountBuy, 1, 1_000 ether);
        feeBps = uint16(bound(feeBps, 0, escrow.MAX_FEE_BPS()));

        vm.prank(owner);
        escrow.setFee(feeBps);

        tokenA.mint(offerer, amountSell);
        tokenB.mint(taker, amountBuy);

        vm.prank(offerer);
        uint256 offerId = escrow.createOffer(address(tokenA), amountSell, address(tokenB), amountBuy);

        uint256 offererBBefore = tokenB.balanceOf(offerer);
        uint256 recipientBBefore = tokenB.balanceOf(feeRecipient);

        vm.prank(taker);
        escrow.takeOffer(offerId);

        uint256 expectedFee = (amountBuy * feeBps) / 10_000;
        assertEq(tokenB.balanceOf(offerer), offererBBefore + amountBuy - expectedFee);
        assertEq(tokenB.balanceOf(feeRecipient), recipientBBefore + expectedFee);
        assertLe(expectedFee, amountBuy);
    }

    // ---------- depositsPaused ----------

    function test_setDepositsPaused_defaultsToFalse() public {
        assertFalse(escrow.depositsPaused());
        _createOffer(100 ether, 50 ether); // must not revert on a fresh deploy
    }

    function test_setDepositsPaused_blocksCreateOffer() public {
        vm.prank(owner);
        escrow.setDepositsPaused(true);

        assertTrue(escrow.depositsPaused());

        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.DepositsPaused.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 50 ether);
    }

    function test_setDepositsPaused_allowsTakeOffer() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);

        vm.prank(owner);
        escrow.setDepositsPaused(true);

        uint256 offererBBefore = tokenB.balanceOf(offerer);
        uint256 takerABefore = tokenA.balanceOf(taker);
        uint256 recipientBBefore = tokenB.balanceOf(feeRecipient);

        vm.prank(taker);
        escrow.takeOffer(offerId); // deposits paused must never block settlement

        uint256 expectedFee = (uint256(50 ether) * FEE_BPS) / 10_000;
        assertEq(tokenB.balanceOf(offerer), offererBBefore + 50 ether - expectedFee);
        assertEq(tokenB.balanceOf(feeRecipient), recipientBBefore + expectedFee);
        assertEq(tokenA.balanceOf(taker), takerABefore + 100 ether);
        assertEq(tokenA.balanceOf(address(escrow)), 0);

        (,,,,, bool active) = escrow.offers(offerId);
        assertFalse(active);
    }

    function test_setDepositsPaused_allowsCancelOffer() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);
        uint256 offererBalBefore = tokenA.balanceOf(offerer);

        vm.prank(owner);
        escrow.setDepositsPaused(true);

        vm.prank(offerer);
        escrow.cancelOffer(offerId); // must not revert: deposits pause can never trap funds

        (,,,,, bool active) = escrow.offers(offerId);
        assertFalse(active);
        assertEq(tokenA.balanceOf(offerer), offererBalBefore + 100 ether);
        assertEq(tokenA.balanceOf(address(escrow)), 0);
    }

    function test_setDepositsPaused_isReversible() public {
        vm.prank(owner);
        escrow.setDepositsPaused(true);

        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.DepositsPaused.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 50 ether);

        vm.prank(owner);
        escrow.setDepositsPaused(false);

        assertFalse(escrow.depositsPaused());
        uint256 offerId = _createOffer(100 ether, 50 ether);

        (,,,,, bool active) = escrow.offers(offerId);
        assertTrue(active);
    }

    function test_setDepositsPaused_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(escrow));
        emit PeerlyEscrow.DepositsPausedSet(true);
        vm.prank(owner);
        escrow.setDepositsPaused(true);

        vm.expectEmit(false, false, false, true, address(escrow));
        emit PeerlyEscrow.DepositsPausedSet(false);
        vm.prank(owner);
        escrow.setDepositsPaused(false);
    }

    function test_setDepositsPaused_revertsForNonOwner() public {
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, taker));
        escrow.setDepositsPaused(true);

        vm.prank(offerer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, offerer));
        escrow.setDepositsPaused(true);

        assertFalse(escrow.depositsPaused());
    }

    function test_setDepositsPaused_idempotent() public {
        vm.startPrank(owner);
        escrow.setDepositsPaused(true);
        escrow.setDepositsPaused(true);
        vm.stopPrank();

        assertTrue(escrow.depositsPaused());
        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.DepositsPaused.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 50 ether);

        vm.startPrank(owner);
        escrow.setDepositsPaused(false);
        escrow.setDepositsPaused(false);
        vm.stopPrank();

        assertFalse(escrow.depositsPaused());
        _createOffer(100 ether, 50 ether);
    }

    // ---------- depositsPaused x global pause ----------

    function test_depositsPaused_andGlobalPause_bothBlockCreateOffer() public {
        // deposits pause only
        vm.prank(owner);
        escrow.setDepositsPaused(true);
        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.DepositsPaused.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 50 ether);

        // both: the whenNotPaused modifier runs before the body, so EnforcedPause wins
        vm.prank(owner);
        escrow.pause();
        vm.prank(offerer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 50 ether);

        // global pause only
        vm.startPrank(owner);
        escrow.setDepositsPaused(false);
        vm.stopPrank();
        vm.prank(offerer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 50 ether);
    }

    function test_globalUnpause_doesNotClearDepositsPaused() public {
        vm.startPrank(owner);
        escrow.setDepositsPaused(true);
        escrow.pause();
        escrow.unpause();
        vm.stopPrank();

        assertFalse(escrow.paused());
        assertTrue(escrow.depositsPaused(), "the two switches are independent");

        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.DepositsPaused.selector);
        escrow.createOffer(address(tokenA), 100 ether, address(tokenB), 50 ether);
    }

    function test_depositsPaused_doesNotBlockCancelWhileGloballyPaused() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);
        uint256 offererBalBefore = tokenA.balanceOf(offerer);

        vm.startPrank(owner);
        escrow.setDepositsPaused(true);
        escrow.pause();
        vm.stopPrank();

        vm.prank(offerer);
        escrow.cancelOffer(offerId); // neither switch may ever trap escrowed funds

        assertEq(tokenA.balanceOf(offerer), offererBalBefore + 100 ether);
        assertEq(tokenA.balanceOf(address(escrow)), 0);
    }

    function test_depositsPaused_takeOfferStillBlockedByGlobalPause() public {
        uint256 offerId = _createOffer(100 ether, 50 ether);

        vm.startPrank(owner);
        escrow.setDepositsPaused(true);
        escrow.pause();
        vm.stopPrank();

        vm.prank(taker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.takeOffer(offerId);
    }

    // ---------- V2 wind-down scenario ----------

    function test_depositsPaused_existingOffersDrainToZero() public {
        uint256 id0 = _createOffer(100 ether, 50 ether);
        uint256 id1 = _createOffer(200 ether, 60 ether);
        uint256 id2 = _createOffer(300 ether, 70 ether);
        assertEq(tokenA.balanceOf(address(escrow)), 600 ether);

        vm.prank(owner);
        escrow.setDepositsPaused(true);

        // no new liquidity can enter
        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.DepositsPaused.selector);
        escrow.createOffer(address(tokenA), 1 ether, address(tokenB), 1 ether);

        vm.prank(taker);
        escrow.takeOffer(id0);
        assertEq(tokenA.balanceOf(address(escrow)), 500 ether);

        vm.startPrank(offerer);
        escrow.cancelOffer(id1);
        escrow.cancelOffer(id2);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(address(escrow)), 0, "escrow must fully drain while deposits are paused");

        // still closed after the drain
        vm.prank(offerer);
        vm.expectRevert(PeerlyEscrow.DepositsPaused.selector);
        escrow.createOffer(address(tokenA), 1 ether, address(tokenB), 1 ether);
    }

    // ---------- fuzz ----------

    function testFuzz_setDepositsPaused_createOfferGatedByFlag(bool paused, uint256 amountSell, uint256 amountBuy)
        public
    {
        amountSell = bound(amountSell, 1, 1_000 ether);
        amountBuy = bound(amountBuy, 1, 1_000 ether);
        tokenA.mint(offerer, amountSell);

        vm.prank(owner);
        escrow.setDepositsPaused(paused);

        vm.prank(offerer);
        if (paused) {
            vm.expectRevert(PeerlyEscrow.DepositsPaused.selector);
            escrow.createOffer(address(tokenA), amountSell, address(tokenB), amountBuy);
            assertEq(tokenA.balanceOf(address(escrow)), 0);
        } else {
            uint256 offerId = escrow.createOffer(address(tokenA), amountSell, address(tokenB), amountBuy);
            (,, uint256 aSell,,, bool active) = escrow.offers(offerId);
            assertEq(aSell, amountSell);
            assertTrue(active);
        }
    }
}
