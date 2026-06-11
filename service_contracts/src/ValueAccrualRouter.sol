// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {FVMPay} from "@fvm-solidity/FVMPay.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Dutch} from "@fws-payments/Dutch.sol";
import {FIRST_AUCTION_START_PRICE, MAX_AUCTION_START_PRICE, FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "./Errors.sol";

/// @title ValueAccrualRouter
/// @notice Terminal sink for the network value-accrual fee (NVAF) charged on FWSS USDC rails.
///
/// FWSS sets this contract as the `serviceFeeRecipient` of USDC rails, so the rails' operator
/// commission accrues to this contract's account inside FilecoinPay. The accumulated tokens are
/// sold for native FIL through a recurring Dutch auction — the same mechanism FilecoinPay itself
/// uses for its network fee (`burnForFees`) — and the FIL paid by the buyer is destroyed via the
/// burn actor (f099). Buyback-and-burn without any DEX or price-oracle dependency: the decaying
/// price lets arbitrageurs compete the auction down to market rate.
///
/// Fully permissionless and immutable: no owner, no parameters to govern. Tokens sent here can
/// only ever leave through the auction; the FIL paid for them is always burned.
contract ValueAccrualRouter is ReentrancyGuard {
    using Dutch for uint256;
    using SafeERC20 for IERC20;

    FilecoinPayV1 public immutable payments;

    // pack into one storage slot (mirrors FilecoinPayV1's fee auction)
    struct AuctionInfo {
        uint88 startPrice; // highest possible price is MAX_AUCTION_START_PRICE
        uint168 startTime;
    }

    mapping(IERC20 token => AuctionInfo) public auctionInfo;

    event CommissionCollected(IERC20 indexed token, uint256 amount);
    event CommissionBurned(
        IERC20 indexed token, address indexed buyer, address indexed recipient, uint256 tokenAmount, uint256 filBurned
    );

    constructor(FilecoinPayV1 _payments) {
        require(address(_payments) != address(0), Errors.ZeroAddress(Errors.AddressField.FilecoinPayV1));
        payments = _payments;
    }

    /// @notice Pulls this contract's accrued commission for `token` out of FilecoinPay and arms
    ///         the auction if it isn't already running. Callable by anyone; also runs
    ///         automatically at the start of every `burnForCommission`.
    /// @param token The commission token to collect
    /// @return collected The amount pulled from FilecoinPay (0 if nothing had accrued)
    function collect(IERC20 token) external nonReentrant returns (uint256 collected) {
        return _collect(token);
    }

    function _collect(IERC20 token) internal returns (uint256 collected) {
        (collected,,,) = payments.accounts(token, address(this));
        if (collected > 0) {
            payments.withdraw(token, collected);
            emit CommissionCollected(token, collected);
        }

        // (Re)arm the auction whenever there is stock to sell and no live price. Mirrors
        // FilecoinPay's fee auction lifecycle: a fully-decayed auction resets to zero and is
        // re-armed at the first price on the next accrual.
        if (token.balanceOf(address(this)) > 0) {
            AuctionInfo storage auction = auctionInfo[token];
            if (auction.startPrice == 0) {
                auction.startPrice = FIRST_AUCTION_START_PRICE;
                auction.startTime = uint168(block.timestamp);
            }
        }
    }

    /// @notice Burn FIL to buy the accumulated commission tokens.
    /// @dev The price is for the lot, independent of `requested` — rational buyers take
    ///      everything available (same semantics as FilecoinPay's `burnForFees`). The price
    ///      decays by 3/4 every week; each purchase resets it to 4x the clearing price.
    /// @param token Which commission token to buy
    /// @param recipient Receives the purchased tokens
    /// @param requested Exact amount of tokens transferred
    function burnForCommission(IERC20 token, address recipient, uint256 requested) external payable nonReentrant {
        _collect(token);

        uint256 available = token.balanceOf(address(this));
        require(requested <= available, Errors.CommissionExceedsAvailable(requested, available));

        AuctionInfo storage auction = auctionInfo[token];
        uint256 auctionPrice = uint256(auction.startPrice).decay(block.timestamp - auction.startTime);
        require(msg.value >= auctionPrice, Errors.InsufficientNativeTokenForBurn(msg.value, auctionPrice));

        auctionPrice *= Dutch.RESET_FACTOR;
        if (auctionPrice > MAX_AUCTION_START_PRICE) {
            auctionPrice = MAX_AUCTION_START_PRICE;
        }
        auction.startPrice = uint88(auctionPrice);
        auction.startTime = uint168(block.timestamp);

        require(FVMPay.burn(msg.value), Errors.NativeBurnFailed(msg.value));

        token.safeTransfer(recipient, requested);

        emit CommissionBurned(token, msg.sender, recipient, requested, msg.value);
    }

    /// @notice Current auction price (attoFIL) to take the accumulated `token` commission.
    function currentPrice(IERC20 token) external view returns (uint256) {
        AuctionInfo storage auction = auctionInfo[token];
        return uint256(auction.startPrice).decay(block.timestamp - auction.startTime);
    }
}
