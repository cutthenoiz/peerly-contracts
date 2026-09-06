// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PeerlyEscrow} from "../../src/PeerlyEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Drives random create/cancel/take sequences against the escrow, tracking
/// per-token escrowed totals so the invariant test can assert solvency.
contract EscrowHandler is Test {
    PeerlyEscrow public escrow;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public owner;
    address[] public actors;
    uint256[] public activeOfferIds;

    mapping(address => uint256) public ghost_escrowedByToken;

    constructor(PeerlyEscrow escrow_, MockERC20 tokenA_, MockERC20 tokenB_, address owner_) {
        escrow = escrow_;
        owner = owner_;
        tokenA = tokenA_;
        tokenB = tokenB_;

        for (uint256 i = 0; i < 3; i++) {
            address actor = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(actor);
            tokenA.mint(actor, 1_000_000 ether);
            tokenB.mint(actor, 1_000_000 ether);
            vm.prank(actor);
            tokenA.approve(address(escrow), type(uint256).max);
            vm.prank(actor);
            tokenB.approve(address(escrow), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function createOffer(uint256 actorSeed, bool sellIsA, uint256 amountSell, uint256 amountBuy) external {
        amountSell = bound(amountSell, 1, 1_000 ether);
        amountBuy = bound(amountBuy, 1, 1_000 ether);

        if (escrow.depositsPaused()) return; // deposits closed: no new escrow to track

        address offerer = _actor(actorSeed);
        MockERC20 sellToken = sellIsA ? tokenA : tokenB;
        MockERC20 buyToken = sellIsA ? tokenB : tokenA;

        vm.prank(offerer);
        uint256 offerId = escrow.createOffer(address(sellToken), amountSell, address(buyToken), amountBuy);

        (,, uint256 recordedAmountSell,,,) = escrow.offers(offerId);
        ghost_escrowedByToken[address(sellToken)] += recordedAmountSell;
        activeOfferIds.push(offerId);
    }

    function cancelOffer(uint256 idSeed) external {
        if (activeOfferIds.length == 0) return;
        uint256 idx = idSeed % activeOfferIds.length;
        uint256 offerId = activeOfferIds[idx];

        (address offerer, address tokenSell, uint256 amountSell,,, bool active) = escrow.offers(offerId);
        if (!active) return;

        vm.prank(offerer);
        escrow.cancelOffer(offerId);

        ghost_escrowedByToken[tokenSell] -= amountSell;
        _removeActiveOffer(idx);
    }

    function takeOffer(uint256 actorSeed, uint256 idSeed) external {
        if (activeOfferIds.length == 0) return;
        uint256 idx = idSeed % activeOfferIds.length;
        uint256 offerId = activeOfferIds[idx];

        (, address tokenSell, uint256 amountSell,,, bool active) = escrow.offers(offerId);
        if (!active) return;

        address taker = _actor(actorSeed);
        vm.prank(taker);
        escrow.takeOffer(offerId);

        ghost_escrowedByToken[tokenSell] -= amountSell;
        _removeActiveOffer(idx);
    }

    /// @dev Flips the deposit switch mid-run so the solvency invariant is exercised
    /// across arbitrary pause/unpause sequences interleaved with trading.
    function toggleDepositsPaused(uint256 seed) external {
        vm.prank(owner);
        escrow.setDepositsPaused(seed % 2 == 0);
    }

    function _removeActiveOffer(uint256 idx) internal {
        activeOfferIds[idx] = activeOfferIds[activeOfferIds.length - 1];
        activeOfferIds.pop();
    }
}
