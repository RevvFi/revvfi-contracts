// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiPositionNFT.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiLiquidityQueue
 * @author Preet Singh
 * @notice Manages epoch-based withdrawal requests to prevent bank runs
 * @dev Lenders request withdrawals in epochs, which are processed at epoch boundaries
 * @dev Positions are locked during withdrawal request to prevent double-spending
 */
contract RevvFiLiquidityQueue is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @dev Individual withdrawal request details
     * @param requestId Unique identifier for the request
     * @param lender Address requesting withdrawal
     * @param positionId NFT position being withdrawn from
     * @param requestedAmount Amount requested for withdrawal
     * @param fulfilledAmount Amount that can be fulfilled
     * @param remainingAmount Amount still pending (requested - fulfilled)
     * @param requestedEpoch Epoch when request was made
     * @param processed Whether the request has been processed
     * @param claimed Whether the fulfilled amount has been claimed
     * @param positionLocked Whether position NFT is locked
     */
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

    /**
     * @dev Epoch configuration and aggregated request data
     * @param epochNumber Sequential epoch identifier
     * @param startTime Timestamp when epoch began
     * @param endTime Timestamp when epoch ends
     * @param totalRequested Total amount requested in this epoch
     * @param totalAvailable Total liquidity available for this epoch
     * @param processed Whether this epoch has been processed
     * @param requestIds Array of withdrawal request IDs in this epoch
     */
    struct Epoch {
        uint256 epochNumber;
        uint256 startTime;
        uint256 endTime;
        uint256 totalRequested;
        uint256 totalAvailable;
        bool processed;
        uint256[] requestIds;
    }

    /// @dev Market contract that can create withdrawal requests
    address public immutable market;

    /// @dev Factory contract that can process epochs
    address public immutable factory;

    /// @dev NFT contract representing lender positions
    IRevvFiPositionNFT public positionNFT;

    /// @dev Duration of each epoch in seconds (7 days)
    uint256 public constant EPOCH_DURATION = 7 days;

    /// @dev Maximum number of withdrawal requests per epoch
    uint256 public constant MAX_REQUESTS_PER_EPOCH = 500;

    /// @dev Mapping from request ID to withdrawal request details
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    /// @dev Mapping from epoch number to epoch data
    mapping(uint256 => Epoch) public epochs;

    /// @dev Mapping from lender address to list of their request IDs
    mapping(address => uint256[]) public lenderRequests;

    /// @dev Tracks whether a position NFT is locked during withdrawal
    mapping(uint256 => bool) public positionWithdrawalLocked;

    /// @dev Next available withdrawal request ID
    uint256 public nextRequestId = 1;

    /// @dev Current epoch number
    uint256 public currentEpoch = 1;

    /// @dev Timestamp when the current epoch started
    uint256 public epochStartTime;

    /// @dev Restricts function calls to the associated market
    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts function calls to the factory contract
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

    /**
     * @dev Initializes liquidity queue for a specific market
     * @param _market Address of the lending market
     * @param _factory Address of the RevvFiFactory
     * @param _positionNFT Address of the Position NFT contract
     */
    constructor(address _market, address _factory, address _positionNFT) {
        if (_market == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_positionNFT == address(0)) revert RevvFiErrors.ZeroAddress();

        market = _market;
        factory = _factory;
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        epochStartTime = block.timestamp;

        // Initialize first epoch
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
     * @dev Creates a withdrawal request for the current epoch
     * @param lender Address of the lender requesting withdrawal
     * @param positionId ID of the position to withdraw from
     * @param amount Amount to withdraw
     * @return requestId Unique identifier for the request
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

        // Verify the lender actually owns this position
        if (positionNFT.ownerOf(positionId) != lender) revert RevvFiErrors.UnauthorizedCaller();

        // Move to next epoch if current one is complete
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

        // Lock the position to prevent transfers
        positionWithdrawalLocked[positionId] = true;

        epoch.totalRequested += amount;
        epoch.requestIds.push(requestId);

        lenderRequests[lender].push(requestId);

        emit WithdrawalRequested(requestId, lender, positionId, amount, currentEpoch);

        return requestId;
    }

    /**
     * @dev Processes all withdrawal requests for an epoch (factory only)
     * @param epochNumber Epoch to process
     * @param availableLiquidity Total liquidity available for distribution
     */
    function processEpoch(uint256 epochNumber, uint256 availableLiquidity) external onlyFactory nonReentrant {
        Epoch storage epoch = epochs[epochNumber];
        if (epoch.processed) revert RevvFiErrors.EpochNotComplete();
        if (block.timestamp < epoch.endTime) revert RevvFiErrors.WithdrawalTooEarly();

        epoch.totalAvailable = availableLiquidity;
        epoch.processed = true;

        if (epoch.totalRequested > 0 && epoch.requestIds.length > 0) {
            // Calculate proportion of requests that can be fulfilled
            uint256 fulfillmentRatio;
            if (availableLiquidity >= epoch.totalRequested) {
                fulfillmentRatio = 1e18; // 100% fulfilled
            } else {
                fulfillmentRatio = (availableLiquidity * 1e18) / epoch.totalRequested;
            }

            // Distribute available liquidity proportionally
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
     * @dev Claims processed withdrawal amount (called by market during redemption)
     * @param requestId ID of the withdrawal request
     * @param amount Amount to claim (must match fulfilled amount)
     */
    function claimWithdrawal(uint256 requestId, uint256 amount) external onlyMarket nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (!request.processed) revert RevvFiErrors.EpochNotComplete();
        if (request.claimed) revert RevvFiErrors.PositionAlreadyRedeemed();
        if (request.fulfilledAmount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 claimAmount = request.fulfilledAmount;
        request.claimed = true;

        // Unlock the position NFT
        if (request.positionLocked) {
            positionWithdrawalLocked[request.positionId] = false;
            request.positionLocked = false;
            emit PositionUnlocked(request.positionId);
        }

        emit WithdrawalClaimed(requestId, msg.sender, claimAmount);
    }

    /**
     * @dev Cancels a withdrawal request before epoch is processed
     * @param requestId ID of the withdrawal request
     */
    function cancelWithdrawal(uint256 requestId) external nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (request.processed) revert RevvFiErrors.WithdrawalTooEarly();
        if (request.remainingAmount == 0) revert RevvFiErrors.ZeroAmount();

        Epoch storage epoch = epochs[request.requestedEpoch];
        epoch.totalRequested -= request.remainingAmount;

        // Unlock the position NFT
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
     * @dev Advances to the next epoch if current one has ended
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

    /**
     * @dev Returns the current active epoch number
     * @return Current epoch (may be next epoch if current has ended)
     */
    function getCurrentEpoch() external view returns (uint256) {
        Epoch storage epochData = epochs[currentEpoch];
        if (block.timestamp >= epochData.endTime) {
            return currentEpoch + 1;
        }
        return currentEpoch;
    }

    /**
     * @dev Returns complete epoch data
     * @param epochNumber Epoch to query
     * @return Epoch struct with all data
     */
    function getEpoch(uint256 epochNumber) external view returns (Epoch memory) {
        return epochs[epochNumber];
    }

    /**
     * @dev Returns withdrawal request details
     * @param requestId Request to query
     * @return WithdrawalRequest struct with all data
     */
    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return withdrawalRequests[requestId];
    }

    /**
     * @dev Returns all request IDs for a specific lender
     * @param lender Address of the lender
     * @return Array of request IDs
     */
    function getLenderRequests(address lender) external view returns (uint256[] memory) {
        return lenderRequests[lender];
    }

    /**
     * @dev Returns all request IDs for a specific epoch
     * @param epochNumber Epoch to query
     * @return Array of request IDs
     */
    function getEpochRequests(uint256 epochNumber) external view returns (uint256[] memory) {
        return epochs[epochNumber].requestIds;
    }

    /**
     * @dev Checks if a withdrawal is ready to be claimed
     * @param requestId Request to check
     * @return True if processed, not claimed, and has fulfilled amount
     */
    function isWithdrawalReady(uint256 requestId) external view returns (bool) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (!request.processed || request.claimed) return false;
        return request.fulfilledAmount > 0;
    }

    /**
     * @dev Returns time remaining until current epoch ends
     * @return Seconds remaining, or 0 if epoch has ended
     */
    function timeUntilEpochEnd() external view returns (uint256) {
        Epoch storage epochData = epochs[currentEpoch];
        if (block.timestamp >= epochData.endTime) return 0;
        return epochData.endTime - block.timestamp;
    }
}
