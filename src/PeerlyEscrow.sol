// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PeerlyEscrow
/// @notice P2P token escrow: an offerer locks tokenSell and names a tokenBuy price;
/// a taker pays that price directly to the offerer and receives the escrowed tokens.
/// @dev Trade logic (create/cancel/take) is not upgradeable - no proxy, no logic swap.
/// The owner only controls a capped protocol fee, an emergency pause, and a narrower
/// deposit pause that blocks new offers while leaving existing ones takeable (wind-down
/// path for a V2 migration). Neither pause blocks cancelOffer, so the owner can never
/// trap escrowed funds.
contract PeerlyEscrow is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Offer {
        address offerer;
        address tokenSell;
        uint256 amountSell;
        address tokenBuy;
        uint256 amountBuy;
        bool active;
    }

    /// @notice Hard ceiling on the protocol fee. The owner can never set a higher fee.
    uint16 public constant MAX_FEE_BPS = 500; // 5%
    uint16 private constant BPS_DENOMINATOR = 10_000;

    mapping(uint256 => Offer) public offers;
    uint256 public nextOfferId;

    uint16 public feeBps;
    address public feeRecipient;

    /// @notice When true, no new offers can be created. Existing offers stay takeable
    /// and cancellable so escrow drains on its own (V2 migration path).
    bool public depositsPaused;

    event OfferCreated(
        uint256 indexed offerId,
        address indexed offerer,
        address tokenSell,
        uint256 amountSell,
        address tokenBuy,
        uint256 amountBuy
    );
    event OfferCancelled(uint256 indexed offerId);
    event OfferTaken(uint256 indexed offerId, address indexed taker, uint256 fee);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event DepositsPausedSet(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error SameToken();
    error FeeTooHigh();
    error NotOfferer();
    error OfferNotActive();
    error DepositsPaused();

    constructor(address initialOwner, address initialFeeRecipient, uint16 initialFeeBps) Ownable(initialOwner) {
        if (initialFeeRecipient == address(0)) revert ZeroAddress();
        if (initialFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeRecipient = initialFeeRecipient;
        feeBps = initialFeeBps;
    }

    /// @notice Escrow `amountSell` of `tokenSell`, asking `amountBuy` of `tokenBuy` in return.
    /// @dev Records the actual balance received (not the requested amount) as `amountSell`,
    /// so a fee-on-transfer/deflationary tokenSell can never under-collateralize the offer
    /// and eat into another offer's balance of the same token.
    function createOffer(address tokenSell, uint256 amountSell, address tokenBuy, uint256 amountBuy)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 offerId)
    {
        if (depositsPaused) revert DepositsPaused();
        if (amountSell == 0 || amountBuy == 0) revert ZeroAmount();
        if (tokenSell == tokenBuy) revert SameToken();

        uint256 balBefore = IERC20(tokenSell).balanceOf(address(this));
        IERC20(tokenSell).safeTransferFrom(msg.sender, address(this), amountSell);
        uint256 received = IERC20(tokenSell).balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();

        offerId = nextOfferId++;
        offers[offerId] = Offer({
            offerer: msg.sender,
            tokenSell: tokenSell,
            amountSell: received,
            tokenBuy: tokenBuy,
            amountBuy: amountBuy,
            active: true
        });

        emit OfferCreated(offerId, msg.sender, tokenSell, received, tokenBuy, amountBuy);
    }

    /// @notice Cancel an active offer and reclaim the escrowed tokens.
    /// @dev Deliberately not gated by whenNotPaused - pause can only stop new
    /// offers/takes, never trap funds already in escrow.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (!offer.active) revert OfferNotActive();
        if (offer.offerer != msg.sender) revert NotOfferer();

        offer.active = false;
        IERC20(offer.tokenSell).safeTransfer(offer.offerer, offer.amountSell);
    }

    /// @notice Take an active offer, paying amountBuy of tokenBuy to receive amountSell of tokenSell.
    /// @dev The protocol fee is deducted from the payment to the offerer, not added on top for
    /// the taker. Payment moves directly taker -> offerer / taker -> feeRecipient; the contract
    /// never custodies tokenBuy, so a fee-on-transfer tokenBuy only affects taker/offerer economics,
    /// never contract solvency.
    function takeOffer(uint256 offerId) external nonReentrant whenNotPaused {
        Offer storage offer = offers[offerId];
        if (!offer.active) revert OfferNotActive();

        offer.active = false;

        uint256 fee = (offer.amountBuy * feeBps) / BPS_DENOMINATOR;
        IERC20(offer.tokenBuy).safeTransferFrom(msg.sender, offer.offerer, offer.amountBuy - fee);
        if (fee > 0) {
            IERC20(offer.tokenBuy).safeTransferFrom(msg.sender, feeRecipient, fee);
        }

        IERC20(offer.tokenSell).safeTransfer(msg.sender, offer.amountSell);

        emit OfferTaken(offerId, msg.sender, fee);
    }

    function setFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Block or re-allow new offers without touching takeOffer/cancelOffer.
    /// @dev Independent of the global pause: unpause() does not clear this flag.
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }
}
