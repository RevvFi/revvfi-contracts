// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiBootstrapper {
    function initialize(
        address _creator,
        address _revvToken,
        address _weth,
        address _uniswapRouter,
        uint256 _liquidityAllocation,
        uint256 _targetLiquidityETH,
        uint256 _hardCapETH,
        uint256 _raiseWindowDuration,
        uint256 _lockDuration,
        uint256 _creatorVestingAmount,
        uint256 _treasuryAmount,
        uint256 _strategicReserveAmount,
        uint256 _rewardsAmount,
        uint256 _creatorCliffDuration,
        uint256 _creatorVestingDuration,
        address _platformFeeRecipient,
        uint256 _keeperReward,
        address _creatorVestingVault,
        address _treasuryVault,
        address _strategicReserveVault,
        address _rewardsDistributor,
        address _governanceModule,
        uint256 _launchId,
        address _centralAuthority
    ) external;

    function shares(address user) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function launched() external view returns (bool);
    function failed() external view returns (bool);
    function creator() external view returns (address);
    function emergencyPause() external;
    function depositETH() external payable;
    function launch() external;
    function claimRefund() external;
    function withdrawAsAssets(uint256 shareAmount) external;
}
