// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts@5.0.0/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts@5.0.0/access/Ownable.sol";
import "@openzeppelin/contracts@5.0.0/token/ERC20/IERC20.sol";

/// @title RealEstateVault
/// @notice Multi-token (ERC-1155) contract managing fractional property
///         shares, rental-rights tokens, and downside-hedge positions for
///         the RealHedge platform.
///
/// Token ID layout (mirrors the project's ID convention):
///   1               .. 99_999      Property shares      (id == propertyId)
///   100_000         .. 999_999     Rental rights         (id == 100_000 + propertyId)
///   1_000_000+                     Hedge positions        (id == 1_000_000 + hedgeNonce), non-fungible (amount == 1)
contract RealEstateVault is ERC1155, Ownable {
    IERC20 public immutable usdx;

    uint256 public constant RENTAL_OFFSET = 100_000;
    uint256 public constant HEDGE_OFFSET = 1_000_000;

    struct Property {
        string name;
        uint256 currentValue;   // in USDX (18 decimals), acts as the on-chain price feed
        uint256 totalShares;
        bool active;
    }

    struct HedgePosition {
        uint256 propertyId;
        address holder;
        uint256 shareAmount;     // shares this hedge is locking as its backing exposure
        uint256 exposure;        // USDX value of the hedged position at purchase time
        uint256 protectedLevel;  // USDX floor value the holder is protected down to
        uint256 premiumPaid;     // USDX premium paid for the hedge
        uint256 expiry;          // unix timestamp
        bool settled;
    }

    mapping(uint256 => Property) public properties;
    mapping(uint256 => HedgePosition) public hedgePositions;
    uint256 public hedgeNonce;

    /// @notice Shares locked as active-hedge backing: holder => propertyId
    ///         => amount currently un-transferable because a hedge is
    ///         relying on them. Prevents buying a hedge, then immediately
    ///         selling the shares it's supposed to be protecting while
    ///         still collecting the payout.
    mapping(address => mapping(uint256 => uint256)) public lockedShares;

    // ---- Rental settlement (pull-based, reward-per-token accounting) ----
    uint256 private constant RENT_PRECISION = 1e18;
    mapping(uint256 => uint256) public totalRentalSupply;        // propertyId => total rental-right tokens issued
    mapping(uint256 => uint256) public cumulativeRentPerToken;   // propertyId => accumulated rent per token, scaled by RENT_PRECISION
    mapping(uint256 => mapping(address => uint256)) public rentDebt;       // propertyId => holder => cumulativeRentPerToken snapshot at last settle
    mapping(uint256 => mapping(address => uint256)) public claimableRent;  // propertyId => holder => rent owed, unclaimed

    event PropertyCreated(uint256 indexed propertyId, string name, uint256 initialValue, uint256 totalShares);
    event PropertyValueUpdated(uint256 indexed propertyId, uint256 newValue);
    event SharesPurchased(uint256 indexed propertyId, address indexed buyer, uint256 shares, uint256 cost);
    event RentalRightsIssued(uint256 indexed propertyId, address indexed to, uint256 amount);
    event RentalDistributed(uint256 indexed propertyId, uint256 amount);
    event RentalClaimed(uint256 indexed propertyId, address indexed holder, uint256 amount);
    event HedgePurchased(uint256 indexed hedgeTokenId, uint256 indexed propertyId, address indexed holder, uint256 exposure, uint256 protectedLevel, uint256 premium, uint256 expiry);
    event HedgeSettled(uint256 indexed hedgeTokenId, uint256 payout, uint256 currentExposure);

    constructor(address usdxAddress, string memory uri_) ERC1155(uri_) Ownable(msg.sender) {
        usdx = IERC20(usdxAddress);
    }

    // ---------------------------------------------------------------
    // Admin / oracle-style functions
    // ---------------------------------------------------------------

    /// @notice Register a new property and its fractionalization scheme.
    function createProperty(
        uint256 propertyId,
        string calldata name,
        uint256 initialValue,
        uint256 totalShares
    ) external onlyOwner {
        require(propertyId > 0 && propertyId < RENTAL_OFFSET, "Vault: bad propertyId range");
        require(!properties[propertyId].active, "Vault: property exists");
        require(totalShares > 0, "Vault: totalShares must be > 0");

        properties[propertyId] = Property({
            name: name,
            currentValue: initialValue,
            totalShares: totalShares,
            active: true
        });

        emit PropertyCreated(propertyId, name, initialValue, totalShares);
    }

    /// @notice Push a new valuation for a property. Stands in for an
    ///         off-chain valuation/price oracle feed.
    function updatePropertyValue(uint256 propertyId, uint256 newValue) external onlyOwner {
        require(properties[propertyId].active, "Vault: unknown property");
        properties[propertyId].currentValue = newValue;
        emit PropertyValueUpdated(propertyId, newValue);
    }

    // ---------------------------------------------------------------
    // Fractional ownership
    // ---------------------------------------------------------------

    /// @notice Buy fractional shares of a property using USDX.
    function buyShares(uint256 propertyId, uint256 shareAmount) external {
        Property storage p = properties[propertyId];
        require(p.active, "Vault: unknown property");
        require(shareAmount > 0, "Vault: shareAmount must be > 0");

        uint256 cost = (p.currentValue * shareAmount) / p.totalShares;
        require(usdx.transferFrom(msg.sender, address(this), cost), "Vault: USDX transfer failed");

        _mint(msg.sender, propertyId, shareAmount, "");
        emit SharesPurchased(propertyId, msg.sender, shareAmount, cost);
    }

    /// @notice Issue rental-rights tokens tied to a property (e.g. to the
    ///         property's shareholders, pro-rata off-chain).
    function issueRentalRights(uint256 propertyId, address to, uint256 amount) external onlyOwner {
        require(properties[propertyId].active, "Vault: unknown property");
        uint256 rentalId = RENTAL_OFFSET + propertyId;
        totalRentalSupply[propertyId] += amount;
        _mint(to, rentalId, amount, "");
        emit RentalRightsIssued(propertyId, to, amount);
    }

    // ---------------------------------------------------------------
    // Rental settlement
    // ---------------------------------------------------------------

    /// @notice Deposit collected rent for a property, splitting it pro-rata
    ///         across all current rental-right token holders. Callable
    ///         periodically (e.g. monthly) by the platform operator.
    function distributeRental(uint256 propertyId, uint256 amount) external onlyOwner {
        require(properties[propertyId].active, "Vault: unknown property");
        uint256 supply = totalRentalSupply[propertyId];
        require(supply > 0, "Vault: no rental rights issued yet");
        require(amount > 0, "Vault: amount must be > 0");

        require(usdx.transferFrom(msg.sender, address(this), amount), "Vault: USDX transfer failed");
        cumulativeRentPerToken[propertyId] += (amount * RENT_PRECISION) / supply;

        emit RentalDistributed(propertyId, amount);
    }

    /// @notice Claim your accrued rental income for a property. Safe to
    ///         call any time; correctly accounts for tokens received or
    ///         sent between distributions.
    function claimRental(uint256 propertyId) external {
        _settleRental(propertyId, msg.sender);

        uint256 amount = claimableRent[propertyId][msg.sender];
        require(amount > 0, "Vault: nothing to claim");

        claimableRent[propertyId][msg.sender] = 0;
        require(usdx.transfer(msg.sender, amount), "Vault: payout transfer failed");

        emit RentalClaimed(propertyId, msg.sender, amount);
    }

    /// @notice View how much rent `holder` could currently claim for a
    ///         property, including rent accrued since their last settle.
    function pendingRental(uint256 propertyId, address holder) external view returns (uint256) {
        uint256 rentalId = RENTAL_OFFSET + propertyId;
        uint256 owed = (balanceOf(holder, rentalId) * (cumulativeRentPerToken[propertyId] - rentDebt[propertyId][holder])) / RENT_PRECISION;
        return claimableRent[propertyId][holder] + owed;
    }

    /// @dev Settles `holder`'s accrued rent up to the current
    ///      cumulativeRentPerToken, using their balance *before* any
    ///      pending transfer. Called on every rental-token mint/burn/transfer
    ///      via `_update` so accounting always reflects the correct holder.
    function _settleRental(uint256 propertyId, address holder) internal {
        uint256 rentalId = RENTAL_OFFSET + propertyId;
        uint256 owed = (balanceOf(holder, rentalId) * (cumulativeRentPerToken[propertyId] - rentDebt[propertyId][holder])) / RENT_PRECISION;
        if (owed > 0) {
            claimableRent[propertyId][holder] += owed;
        }
        rentDebt[propertyId][holder] = cumulativeRentPerToken[propertyId];
    }

    /// @dev Hook fired on every mint / burn / transfer. Settles rental
    ///      accounting for rental-right tokens, and blocks transferring
    ///      property shares below the amount currently locked by an active
    ///      hedge on them.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal virtual override {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id >= RENTAL_OFFSET && id < HEDGE_OFFSET) {
                uint256 propertyId = id - RENTAL_OFFSET;
                if (from != address(0)) _settleRental(propertyId, from);
                if (to != address(0)) _settleRental(propertyId, to);
            } else if (id > 0 && id < RENTAL_OFFSET && from != address(0)) {
                // Property share: sending away more than the unlocked
                // (non-hedged) balance is not allowed.
                uint256 currentBalance = balanceOf(from, id);
                uint256 unlocked = currentBalance - lockedShares[from][id];
                require(values[i] <= unlocked, "Vault: shares locked by an active hedge");
            }
        }
        super._update(from, to, ids, values);
    }

    /// @notice Current USDX value of `shareAmount` shares in a property.
    function shareValue(uint256 propertyId, uint256 shareAmount) public view returns (uint256) {
        Property storage p = properties[propertyId];
        require(p.active, "Vault: unknown property");
        return (p.currentValue * shareAmount) / p.totalShares;
    }

    // ---------------------------------------------------------------
    // Hedging
    // ---------------------------------------------------------------

    /// @notice Purchase downside protection on a share position.
    /// @param propertyId The property being hedged.
    /// @param shareAmount The number of shares the exposure is based on.
    /// @param propertyFloorLevel The USDX floor for the WHOLE property (not
    ///        this position). Internally translated down to a position-level
    ///        protectedLevel at the same proportional ratio, so the caller
    ///        only ever has to think in property-price terms, matching how
    ///        they'd naturally quote a floor (e.g. "protect me if the
    ///        property drops below X"), not in their own share-value terms.
    /// @param premium The USDX premium (pre-computed off-chain by the quant
    ///        engine) the holder pays for the hedge.
    /// @param duration Seconds until the hedge expires.
    function purchaseHedge(
        uint256 propertyId,
        uint256 shareAmount,
        uint256 propertyFloorLevel,
        uint256 premium,
        uint256 duration
    ) external returns (uint256 hedgeTokenId) {
        Property storage p = properties[propertyId];
        require(p.active, "Vault: unknown property");
        require(balanceOf(msg.sender, propertyId) >= shareAmount, "Vault: insufficient shares");
        require(
            balanceOf(msg.sender, propertyId) - lockedShares[msg.sender][propertyId] >= shareAmount,
            "Vault: shares already locked by another hedge"
        );

        // propertyFloorLevel is compared against p.currentValue -- both
        // are property-level figures, so this check is scale-correct 
        // by construction 
        require(propertyFloorLevel < p.currentValue, "Vault: floor must be below current property value");

        uint256 exposure = shareValue(propertyId, shareAmount);
        // Translate the property-level floor down to this position, at the
        // same proportional ratio -- e.g. shareAmount/totalShares of the
        // property's floor is this position's floor.
        uint256 protectedLevel = (propertyFloorLevel * shareAmount) / p.totalShares;

        require(usdx.transferFrom(msg.sender, address(this), premium), "Vault: premium transfer failed");

        hedgeNonce += 1;
        hedgeTokenId = HEDGE_OFFSET + hedgeNonce;

        hedgePositions[hedgeTokenId] = HedgePosition({
            propertyId: propertyId,
            holder: msg.sender,
            shareAmount: shareAmount,
            exposure: exposure,
            protectedLevel: protectedLevel,
            premiumPaid: premium,
            expiry: block.timestamp + duration,
            settled: false
        });

        lockedShares[msg.sender][propertyId] += shareAmount;

        _mint(msg.sender, hedgeTokenId, 1, "");

        emit HedgePurchased(hedgeTokenId, propertyId, msg.sender, exposure, protectedLevel, premium, hedgePositions[hedgeTokenId].expiry);
    }

    /// @notice Settle a hedge position at or after expiry, re-pricing THIS
    ///         position's exposure at the property's current value.
    function settleHedge(uint256 hedgeTokenId) external {
        HedgePosition storage h = hedgePositions[hedgeTokenId];
        require(h.holder != address(0), "Vault: unknown hedge");
        require(!h.settled, "Vault: already settled");
        require(block.timestamp >= h.expiry, "Vault: not yet expired");
        require(balanceOf(msg.sender, hedgeTokenId) == 1, "Vault: caller does not hold hedge token");

        Property storage p = properties[h.propertyId];

        // re-price the ORIGINAL share amount at the property's CURRENT
        // value, so it's comparable to h.protectedLevel (also a
        // position-level figure). The old code compared p.currentValue
        // (the whole property) directly against h.protectedLevel, which
        // meant a payout could practically never trigger .
        // i.e what i mentioned in the report in section 5.2.
        uint256 currentExposure = (p.currentValue * h.shareAmount) / p.totalShares;

        uint256 payout = 0;
        if (currentExposure < h.protectedLevel) {
            // Proportional payout: original exposure scaled by the shortfall
            // below the protected level, relative to the protected level.
            uint256 shortfall = h.protectedLevel - currentExposure;
            payout = (h.exposure * shortfall) / h.protectedLevel;

            uint256 available = usdx.balanceOf(address(this));
            if (payout > available) {
                payout = available;
            }
        }

        h.settled = true;
        lockedShares[h.holder][h.propertyId] -= h.shareAmount;
        _burn(msg.sender, hedgeTokenId, 1);

        if (payout > 0) {
            require(usdx.transfer(msg.sender, payout), "Vault: payout transfer failed");
        }

        emit HedgeSettled(hedgeTokenId, payout, currentExposure);
    }

    /// @notice Convenience view for the frontend / off-chain quant engine.
    /// i.e sections 4.3.10 & 5.7 & 5.8
    function getHedgePosition(uint256 hedgeTokenId) external view returns (HedgePosition memory) {
        return hedgePositions[hedgeTokenId];
    }

    function getProperty(uint256 propertyId) external view returns (Property memory) {
        return properties[propertyId];
    }
}
