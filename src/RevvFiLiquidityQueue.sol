// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiPositionNFT.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiLiquidityQueue
 * @notice Manages epoch-based withdrawal requests to prevent bank runs
 * @dev Each epoch lasts EPOCH_DURATION. Withdrawals requested in epoch N are processed at epoch end.
 * @dev Positions are locked during withdrawal request to prevent double-spending.
 */
contract RevvFiLiquidityQueue is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct WithdrawalRequest {
        uint256 requestId;
        address lender;
        uint256 positionId;
        uint256 requestedAmount;
        uint256 fulfilledAmount;
        uint256 remainingAmount;
        uint256 requestedEpoch;
        bool processed;
        bool claimed;
        bool positionLocked;
    }

    struct Epoch {
        uint256 epochNumber;
        uint256 startTime;
        uint256 endTime;
        uint256 totalRequested;
        uint256 totalAvailable;
        bool processed;
        uint256[] requestIds;
    }

    address public immutable market;
    address public immutable factory;
    IRevvFiPositionNFT public positionNFT;

    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant MAX_REQUESTS_PER_EPOCH = 500;

    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;
    mapping(uint256 => Epoch) public epochs;
    mapping(address => uint256[]) public lenderRequests;
    mapping(uint256 => bool) public positionWithdrawalLocked;

    uint256 public nextRequestId = 1;
    uint256 public currentEpoch = 1;
    uint256 public epochStartTime;

    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    event WithdrawalRequested(
        uint256 indexed requestId, address indexed lender, uint256 positionId, uint256 amount, uint256 epoch
    );
    event EpochProcessed(uint256 indexed epochNumber, uint256 totalRequested, uint256 totalProcessed);
    event WithdrawalClaimed(uint256 indexed requestId, address indexed lender, uint256 amount);
    event WithdrawalCancelled(uint256 indexed requestId, address indexed lender, uint256 amount);
    event PositionUnlocked(uint256 indexed positionId);

    constructor(address _market, address _factory, address _positionNFT) {
        if (_market == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_positionNFT == address(0)) revert RevvFiErrors.ZeroAddress();

        market = _market;
        factory = _factory;
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        epochStartTime = block.timestamp;

        epochs[1] = Epoch({
            epochNumber: 1,
            startTime: block.timestamp,
            endTime: block.timestamp + EPOCH_DURATION,
            totalRequested: 0,
            totalAvailable: 0,
            processed: false,
            requestIds: new uint256[](0)
        });
    }

    /**
     * @dev Request withdrawal during current epoch
     * Locks the position NFT to prevent transfer during withdrawal process
     */
    function requestWithdrawal(address lender, uint256 positionId, uint256 amount)
        external
        onlyMarket
        nonReentrant
        returns (uint256 requestId)
    {
        if (lender == address(0)) revert RevvFiErrors.ZeroAddress();
        if (amount == 0) revert RevvFiErrors.ZeroAmount();
        if (positionWithdrawalLocked[positionId]) revert RevvFiErrors.PositionAlreadyRedeemed();

        // Verify lender owns the position
        if (positionNFT.ownerOf(positionId) != lender) revert RevvFiErrors.UnauthorizedCaller();

        // Move to next epoch if current one has ended
        _advanceEpochIfNeeded();

        // Check epoch capacity
        Epoch storage epoch = epochs[currentEpoch];
        if (epoch.requestIds.length >= MAX_REQUESTS_PER_EPOCH) {
            revert RevvFiErrors.MaxOffersExceeded();
        }

        requestId = nextRequestId++;

        WithdrawalRequest storage request = withdrawalRequests[requestId];
        request.requestId = requestId;
        request.lender = lender;
        request.positionId = positionId;
        request.requestedAmount = amount;
        request.fulfilledAmount = 0;
        request.remainingAmount = amount;
        request.requestedEpoch = currentEpoch;
        request.processed = false;
        request.claimed = false;
        request.positionLocked = true;

        // Lock the position
        positionWithdrawalLocked[positionId] = true;

        epoch.totalRequested += amount;
        epoch.requestIds.push(requestId);

        lenderRequests[lender].push(requestId);

        emit WithdrawalRequested(requestId, lender, positionId, amount, currentEpoch);

        return requestId;
    }

    /**
     * @dev Process all withdrawal requests for an epoch
     * Distributes available funds proportionally if insufficient liquidity
     */
    function processEpoch(uint256 epochNumber, uint256 availableLiquidity) external onlyFactory nonReentrant {
        Epoch storage epoch = epochs[epochNumber];
        if (epoch.processed) revert RevvFiErrors.EpochNotComplete();
        if (block.timestamp < epoch.endTime) revert RevvFiErrors.WithdrawalTooEarly();

        epoch.totalAvailable = availableLiquidity;
        epoch.processed = true;

        if (epoch.totalRequested > 0 && epoch.requestIds.length > 0) {
            uint256 fulfillmentRatio;
            if (availableLiquidity >= epoch.totalRequested) {
                fulfillmentRatio = 1e18;
            } else {
                fulfillmentRatio = (availableLiquidity * 1e18) / epoch.totalRequested;
            }

            for (uint256 i = 0; i < epoch.requestIds.length; i++) {
                uint256 requestId = epoch.requestIds[i];
                WithdrawalRequest storage request = withdrawalRequests[requestId];

                uint256 payout = (request.requestedAmount * fulfillmentRatio) / 1e18;
                request.fulfilledAmount = payout;
                request.remainingAmount = request.requestedAmount - payout;
                request.processed = true;
            }
        }

        emit EpochProcessed(epochNumber, epoch.totalRequested, epoch.totalAvailable);
    }

    /**
     * @dev Claim processed withdrawal
     * Unlocks position after full withdrawal
     */
    function claimWithdrawal(uint256 requestId, uint256 amount) external onlyMarket nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (!request.processed) revert RevvFiErrors.EpochNotComplete();
        if (request.claimed) revert RevvFiErrors.PositionAlreadyRedeemed();
        if (request.fulfilledAmount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 claimAmount = request.fulfilledAmount;
        request.claimed = true;

        // Unlock position
        if (request.positionLocked) {
            positionWithdrawalLocked[request.positionId] = false;
            request.positionLocked = false;
            emit PositionUnlocked(request.positionId);
        }

        emit WithdrawalClaimed(requestId, msg.sender, claimAmount);
    }

    /**
     * @dev Cancel withdrawal request before epoch is processed
     */
    function cancelWithdrawal(uint256 requestId) external nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (request.processed) revert RevvFiErrors.WithdrawalTooEarly();
        if (request.remainingAmount == 0) revert RevvFiErrors.ZeroAmount();

        Epoch storage epoch = epochs[request.requestedEpoch];
        epoch.totalRequested -= request.remainingAmount;

        // Unlock position
        if (request.positionLocked) {
            positionWithdrawalLocked[request.positionId] = false;
            request.positionLocked = false;
            emit PositionUnlocked(request.positionId);
        }

        uint256 amount = request.remainingAmount;
        request.remainingAmount = 0;

        emit WithdrawalCancelled(requestId, msg.sender, amount);
    }

    /**
     * @dev Advance to next epoch if current one has ended
     */
    function _advanceEpochIfNeeded() internal {
        Epoch storage currentEpochData = epochs[currentEpoch];

        while (block.timestamp >= currentEpochData.endTime) {
            currentEpoch++;

            Epoch storage nextEpoch = epochs[currentEpoch];
            if (nextEpoch.startTime == 0) {
                nextEpoch.epochNumber = currentEpoch;
                nextEpoch.startTime = block.timestamp;
                nextEpoch.endTime = block.timestamp + EPOCH_DURATION;
                nextEpoch.totalRequested = 0;
                nextEpoch.totalAvailable = 0;
                nextEpoch.processed = false;
                nextEpoch.requestIds = new uint256[](0);
            }

            currentEpochData = epochs[currentEpoch];
        }
    }

    function getCurrentEpoch() external view returns (uint256) {
        Epoch storage epochData = epochs[currentEpoch];
        if (block.timestamp >= epochData.endTime) {
            return currentEpoch + 1;
        }
        return currentEpoch;
    }

    function getEpoch(uint256 epochNumber) external view returns (Epoch memory) {
        return epochs[epochNumber];
    }

    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return withdrawalRequests[requestId];
    }

    function getLenderRequests(address lender) external view returns (uint256[] memory) {
        return lenderRequests[lender];
    }

    function getEpochRequests(uint256 epochNumber) external view returns (uint256[] memory) {
        return epochs[epochNumber].requestIds;
    }

    function isWithdrawalReady(uint256 requestId) external view returns (bool) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (!request.processed || request.claimed) return false;
        return request.fulfilledAmount > 0;
    }

    function timeUntilEpochEnd() external view returns (uint256) {
        Epoch storage epochData = epochs[currentEpoch];
        if (block.timestamp >= epochData.endTime) return 0;
        return epochData.endTime - block.timestamp;
    }
}
