// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IRevvFiPositionNFT.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiLiquidityQueue
 * @author Preet Singh
 * @notice Manages withdrawal requests and liquidity processing for RevvFi protocol
 * @dev Handles epoch-based withdrawal requests, liquidity allocation, and claim processing
 */
contract RevvFiLiquidityQueue is ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    /**
     * @dev Structure representing a withdrawal request
     * @param requestId Unique identifier for the withdrawal request
     * @param lender Address of the lender requesting withdrawal
     * @param positionId ID of the NFT position being withdrawn from
     * @param requestedAmount Original amount requested for withdrawal
     * @param fulfilledAmount Amount that was fulfilled when epoch was processed
     * @param remainingAmount Amount remaining to be withdrawn (requested - fulfilled)
     * @param requestedEpoch Epoch number when this request was made
     * @param processed Whether the request has been processed in an epoch
     * @param claimed Whether the fulfilled amount has been claimed
     * @param positionLocked Whether the position is locked from new withdrawal requests
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
     * @dev Structure representing an epoch for withdrawal processing
     * @param epochNumber Sequential identifier for the epoch
     * @param startTime Timestamp when epoch begins
     * @param endTime Timestamp when epoch ends and processing can begin
     * @param totalRequested Total withdrawal amount requested in this epoch
     * @param totalAvailable Total liquidity available for fulfilling requests
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

    address public market;                     // Market contract address authorized to interact
    address public factory;                    // Factory contract address for epoch processing
    IRevvFiPositionNFT public positionNFT;     // NFT contract for position ownership verification

    uint256 public constant EPOCH_DURATION = 7 days;      // Duration of each epoch
    uint256 public constant MAX_REQUESTS_PER_EPOCH = 500; // Maximum withdrawal requests per epoch

    mapping(uint256 => WithdrawalRequest) public withdrawalRequests; // Request ID => Request details
    mapping(uint256 => Epoch) public epochs;                         // Epoch number => Epoch details
    mapping(address => uint256[]) public lenderRequests;             // Lender address => Array of request IDs
    mapping(uint256 => bool) public positionWithdrawalLocked;        // Position ID => Lock status

    uint256 public nextRequestId;    // Next available request ID
    uint256 public currentEpoch;     // Current active epoch number
    uint256 public epochStartTime;   // Start time of the current epoch

    /**
     * @dev Modifier to restrict access to market contract only
     */
    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Modifier to restrict access to factory contract only
     */
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Constructor that disables initializers for implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract (replaces constructor for upgradeable pattern)
     * @param _factory Address of the factory contract
     * @param _market Address of the market contract
     * @param _positionNFT Address of the PositionNFT contract
     */
    function initialize(address _factory, address _market, address _positionNFT) external initializer {
        if (_factory == address(0) || _market == address(0) || _positionNFT == address(0)) {
            revert RevvFiErrors.ZeroAddress();
        }

        factory = _factory;
        market = _market;
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        nextRequestId = 1;
        currentEpoch = 1;
        epochStartTime = block.timestamp;

        // Initialize the first epoch
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
     * @dev Requests a withdrawal for a lender from a specific position
     * @param lender Address of the lender requesting withdrawal
     * @param positionId ID of the position to withdraw from
     * @param amount Amount to withdraw
     * @return requestId Unique identifier for the withdrawal request
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
        if (positionNFT.ownerOf(positionId) != lender) revert RevvFiErrors.UnauthorizedCaller();

        _advanceEpochIfNeeded();

        Epoch storage epoch = epochs[currentEpoch];
        if (epoch.requestIds.length >= MAX_REQUESTS_PER_EPOCH) {
            revert RevvFiErrors.MaxOffersExceeded();
        }

        requestId = nextRequestId++;

        // Create new withdrawal request
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

        // Update state mappings
        positionWithdrawalLocked[positionId] = true;
        epoch.totalRequested += amount;
        epoch.requestIds.push(requestId);
        lenderRequests[lender].push(requestId);

        emit WithdrawalRequested(requestId, lender, positionId, amount, currentEpoch);

        return requestId;
    }

    /**
     * @dev Processes an epoch by allocating available liquidity to withdrawal requests
     * @param epochNumber Epoch number to process
     * @param availableLiquidity Total liquidity available for fulfilling withdrawal requests
     */
    function processEpoch(uint256 epochNumber, uint256 availableLiquidity) external onlyFactory nonReentrant {
        Epoch storage epoch = epochs[epochNumber];
        if (epoch.processed) revert RevvFiErrors.EpochNotComplete();
        if (block.timestamp < epoch.endTime) revert RevvFiErrors.WithdrawalTooEarly();

        epoch.totalAvailable = availableLiquidity;
        epoch.processed = true;

        // Calculate and apply fulfillment ratio if there are pending requests
        if (epoch.totalRequested > 0 && epoch.requestIds.length > 0) {
            uint256 fulfillmentRatio;
            if (availableLiquidity >= epoch.totalRequested) {
                fulfillmentRatio = 1e18; // 100% fulfillment ratio (1e18 = 100%)
            } else {
                // Calculate pro-rata fulfillment ratio based on available liquidity
                fulfillmentRatio = (availableLiquidity * 1e18) / epoch.totalRequested;
            }

            // Process each withdrawal request in the epoch
            for (uint256 i = 0; i < epoch.requestIds.length; i++) {
                uint256 requestId = epoch.requestIds[i];
                WithdrawalRequest storage request = withdrawalRequests[requestId];

                // Calculate payout based on fulfillment ratio
                uint256 payout = (request.requestedAmount * fulfillmentRatio) / 1e18;
                request.fulfilledAmount = payout;
                request.remainingAmount = request.requestedAmount - payout;
                request.processed = true;
            }
        }

        emit EpochProcessed(epochNumber, epoch.totalRequested, epoch.totalAvailable);
    }

    /**
     * @dev Claims fulfilled withdrawal amount for a processed request
     * @param requestId ID of the withdrawal request to claim
     * @param amount Amount to claim (unused parameter, claims full fulfilled amount)
     */
    function claimWithdrawal(uint256 requestId, uint256 amount) external onlyMarket nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (!request.processed) revert RevvFiErrors.EpochNotComplete();
        if (request.claimed) revert RevvFiErrors.PositionAlreadyRedeemed();
        if (request.fulfilledAmount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 claimAmount = request.fulfilledAmount;
        request.claimed = true;

        // Unlock position if it was locked by this request
        if (request.positionLocked) {
            positionWithdrawalLocked[request.positionId] = false;
            request.positionLocked = false;
            emit PositionUnlocked(request.positionId);
        }

        emit WithdrawalClaimed(requestId, msg.sender, claimAmount);
    }

    /**
     * @dev Cancels a pending withdrawal request before epoch processing
     * @param requestId ID of the withdrawal request to cancel
     */
    function cancelWithdrawal(uint256 requestId) external nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (request.processed) revert RevvFiErrors.WithdrawalTooEarly();
        if (request.remainingAmount == 0) revert RevvFiErrors.ZeroAmount();

        Epoch storage epoch = epochs[request.requestedEpoch];
        epoch.totalRequested -= request.remainingAmount;

        // Unlock position if it was locked by this request
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
     * @dev Advances to the next epoch if the current epoch has ended
     * @notice Creates new epochs as needed when moving past uninitialized epochs
     */
    function _advanceEpochIfNeeded() internal {
        Epoch storage currentEpochData = epochs[currentEpoch];

        // Keep advancing epochs while current epoch has ended
        while (block.timestamp >= currentEpochData.endTime) {
            currentEpoch++;

            Epoch storage nextEpoch = epochs[currentEpoch];
            // Initialize new epoch if it doesn't exist
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
     * @return Current epoch number (or next if current has ended)
     */
    function getCurrentEpoch() external view returns (uint256) {
        Epoch storage epochData = epochs[currentEpoch];
        if (block.timestamp >= epochData.endTime) {
            return currentEpoch + 1;
        }
        return currentEpoch;
    }

    /**
     * @dev Returns details of a specific epoch
     * @param epochNumber Epoch number to query
     * @return Epoch structure containing epoch details
     */
    function getEpoch(uint256 epochNumber) external view returns (Epoch memory) {
        return epochs[epochNumber];
    }

    /**
     * @dev Returns details of a specific withdrawal request
     * @param requestId Request ID to query
     * @return WithdrawalRequest structure containing request details
     */
    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return withdrawalRequests[requestId];
    }

    /**
     * @dev Returns all withdrawal request IDs for a specific lender
     * @param lender Address of the lender
     * @return Array of request IDs belonging to the lender
     */
    function getLenderRequests(address lender) external view returns (uint256[] memory) {
        return lenderRequests[lender];
    }

    /**
     * @dev Returns all withdrawal request IDs for a specific epoch
     * @param epochNumber Epoch number to query
     * @return Array of request IDs in the epoch
     */
    function getEpochRequests(uint256 epochNumber) external view returns (uint256[] memory) {
        return epochs[epochNumber].requestIds;
    }

    /**
     * @dev Checks if a withdrawal request is ready to be claimed
     * @param requestId Request ID to check
     * @return True if request is processed, unclaimed, and has positive fulfilled amount
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

    // Events
    event WithdrawalRequested(
        uint256 indexed requestId, address indexed lender, uint256 positionId, uint256 amount, uint256 epoch
    );
    event EpochProcessed(uint256 indexed epochNumber, uint256 totalRequested, uint256 totalProcessed);
    event WithdrawalClaimed(uint256 indexed requestId, address indexed lender, uint256 amount);
    event WithdrawalCancelled(uint256 indexed requestId, address indexed lender, uint256 amount);
    event PositionUnlocked(uint256 indexed positionId);
}