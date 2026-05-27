// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiOfferBook {
    struct Offer {
        uint256 id;
        address lender;
        uint256 amount;
        uint256 remainingAmount;
        uint256 apr;
        uint8 seniority;
        uint256 expiry;
        bool active;
        bool isSenior;
    }

    // Initialization function (only callable by factory)
    function initialize(address _factory, address _market, address _borrowAsset) external;

    // Core functions
    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration) external returns (uint256);
    function cancelOffer(uint256 offerId) external;
    function modifyOffer(uint256 offerId, uint256 newAmount, uint256 newApr, uint256 newDuration) external;
    function executeDrawdown(uint256 amount, bool useSeniorOnly)
        external
        returns (Offer[] memory filledOffers, uint256 weightedApr);

    // View functions
    function getBestOffers(uint256 amount, bool useSeniorOnly) external view returns (Offer[] memory, uint256, uint256);
    function getOffer(uint256 offerId) external view returns (Offer memory);
    function getTotalLiquidityAvailable() external view returns (uint256);
    function getActiveOfferCount() external view returns (uint256);
    function getLenderOffers(address lender) external view returns (Offer[] memory);

    // Utility functions
    function cleanupExpiredOffers(uint256 maxCleanup) external;
}
