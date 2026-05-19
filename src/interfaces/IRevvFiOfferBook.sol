// SPDX-License-Identifier: Apache-2.0
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

    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration) external returns (uint256);
    function cancelOffer(uint256 offerId) external;
    function executeDrawdown(uint256 amount, bool useSeniorOnly)
        external
        returns (Offer[] memory filledOffers, uint256 weightedApr);
    function getBestOffers(uint256 amount, bool useSeniorOnly) external view returns (Offer[] memory, uint256, uint256);
    function getOffer(uint256 offerId) external view returns (Offer memory);
    function getTotalLiquidityAvailable() external view returns (uint256);
}
