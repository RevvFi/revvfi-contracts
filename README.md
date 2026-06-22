# RevvFi Protocol

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.33-363636?logo=solidity&logoColor=white)](https://docs.soliditylang.org/)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C?logo=ethereum&logoColor=black)](https://book.getfoundry.sh/)
[![Network: Sepolia](https://img.shields.io/badge/Network-Sepolia-7CA1F6?logo=ethereum&logoColor=white)](https://sepolia.etherscan.io/)
[![Network: Polygon](https://img.shields.io/badge/Network-Polygon-8247E5?logo=polygon&logoColor=white)](https://polygonscan.com/)

A decentralized lending protocol enabling peer-to-peer loan matching with variable interest rates, collateralized borrowing, and reputation-based risk assessment on the blockchain.

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [System Architecture](#system-architecture)
- [Core Concepts](#core-concepts)
- [Smart Contracts](#smart-contracts)
- [Deployed Contracts](#deployed-contracts)
- [How It Works](#how-it-works)
- [Getting Started](#getting-started)
- [Testing](#testing)
- [Security Considerations](#security-considerations)
- [License](#license)

## Overview

RevvFi is a sophisticated decentralized lending protocol that facilitates peer-to-peer lending with dynamic interest rate discovery through competitive offer mechanisms. The protocol is designed to support multiple independent lending markets, each with its own borrower, collateral requirements, and lender communities.

### Protocol Highlights

- **Dynamic Market Creation**: Borrowers can deploy custom lending markets with configurable collateral types and parameters
- **Flexible Interest Rate Discovery**: Lenders submit competitive offers with varying APRs, allowing automatic price discovery
- **Collateral Management**: Secure collateral escrow with oracle-based valuation and health monitoring
- **Advanced Liquidation**: Dutch auction-based liquidation mechanism for efficient collateral recovery
- **Reputation Scoring**: On-chain reputation system tracking borrower performance across all markets
- **Position NFTs**: Lender positions are represented as transferable ERC721 tokens
- **Withdrawal Queue**: Epoch-based withdrawal system preventing bank runs and ensuring orderly liquidity management
- **Tiered Lending**: Support for senior and junior lending positions with different risk/reward profiles

## Key Features

### 1. Multi-Market Architecture

Each borrower controls an independent lending market where they can secure loans. Markets are isolated, allowing borrowers to manage reputation and collateral separately.

### 2. Competitive Offer Matching

Lenders submit offers with custom APRs and seniority levels. The protocol matches borrow requests with the most favorable offers, with senior offers prioritized.

### 3. Collateral Escrow & Health Monitoring

Collateral is held in a dedicated escrow contract with continuous health monitoring:

- **Min Collateral Ratio**: Minimum required collateral value vs. debt
- **Liquidation Threshold**: Ratio at which position becomes liquidatable
- **Oracle Integration**: Chainlink price feeds for real-time collateral valuation

### 4. Interest Accrual Engine

- Per-position APR tracking
- Automatic compound interest calculation
- Synchronized accrual across all active positions
- Real-time interest updates during borrowing and repayment

### 5. Dutch Auction Liquidation

When positions become undercollateralized, collateral is auctioned:

- **Starting price**: 100% of debt
- **Decreasing price**: Configurable step-based price reductions
- **Reserve price**: 80% of debt ensures minimum recovery
- **Bid-time auction extension**: Late bids extend auction window

### 6. Reputation & Risk Rating

Borrowers earn reputation scores (0-1000) based on:

- **Starting Score**: 500 for new borrowers
- **Success Bonus**: +1 point per successful loan repayment
- **Default Penalty**: -50 points per default
- **Risk Labels**: AAA (900+), AA (800-899), A (700-799), B (500-699), C (300-499), D (<300)

### 7. Position NFTs

Lender positions are ERC721 NFTs encoding:

- Principal amount
- APR and seniority level
- Market association
- Creation timestamp
- Active/settled status

### 8. Liquidity Queue Management

Epoch-based withdrawal system:

- Requests queued for specific epochs
- Position NFTs locked during withdrawal requests
- Proportional fulfillment based on available liquidity
- Prevents bank-run scenarios

## System Architecture

### Component Relationship Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    RevvFiFactory                                 │
│  (Deployment & Configuration Manager)                           │
└────────────────┬────────────────────────────────────────────────┘
                 │
    ┌────────────┼────────────┬──────────────┬──────────────┐
    │            │            │              │              │
    v            v            v              v              v
┌────────┐ ┌──────────┐ ┌─────────────┐ ┌──────────┐ ┌──────────┐
│RevvFi  │ │Reputation│ │Position NFT │ │Liquidator│ │ArchCntrl │
│Market  │ │Registry  │ │             │ │          │ │          │
└────┬───┘ └──────────┘ └─────────────┘ └──────────┘ └──────────┘
     │
┌────┴────────────────────┬─────────────────────┐
│                         │                     │
v                         v                     v
┌──────────────────┐ ┌──────────────┐ ┌────────────────┐
│Collateral Escrow │ │Offer Book    │ │Liquidity Queue │
│                  │ │              │ │                │
│- Deposit         │ │- Withdraw    │ │- Withdrawal    │
│- Withdraw        │ │  Offers      │ │  Requests      │
│- Collateral      │ │- Cancel      │ │- Epoch         │
│  Valuation       │ │  Offers      │ │  Processing    │
└──────────────────┘ └──────────────┘ └────────────────┘
```

## Core Concepts

### Collateral Ratio

```
Collateral Ratio = (Collateral Value in Borrow Asset) / Total Debt × 100%
```

A ratio of 150% means borrower has $1.50 in collateral for every $1 owed.

### Interest Accrual

```
Interest = Principal × APR (bps) × Time Elapsed (seconds) / (365 days × 10,000 bps)
```

Interest is accrued per position based on individual APRs and is automatically updated before each market operation.

### Seniority Levels

- **Senior (0)**: First priority in repayment, lower default risk
- **Junior (1)**: Subordinate claims, higher risk but potentially higher returns

During liquidation, senior lenders are paid first from auction proceeds.

### Liquidation Process

1. **Health Check**: System monitors collateral ratio relative to liquidation threshold
2. **Trigger**: When ratio falls below threshold, position enters liquidation
3. **Auction**: Dutch auction begins with collateral offered for sale
4. **Bidding**: Participants bid increasing amounts in borrow asset
5. **Settlement**: Highest bidder receives collateral; proceeds distributed to lenders per seniority
6. **Bad Debt**: If proceeds insufficient, remaining loss allocated proportionally to junior lenders

### Withdrawal Epochs

The protocol uses 7-day epochs to manage lender withdrawals:

1. Lender requests withdrawal of their position
2. Request queued for next epoch
3. Position NFT becomes locked (non-transferable)
4. At epoch end, available liquidity proportionally distributed
5. Lender claims their fulfilled amount
6. Remaining balance returns to position (if any)

## Smart Contracts

### Core Contracts

#### RevvFiFactory

The deployment hub that initializes all protocol components.

**Key Functions:**
- `deployMarket()` - Creates new lending market with all sub-contracts
- `setDeploymentFee()` - Updates deployment fee amount
- `registerWithArchController()` - Registers factory with governance

**Manages:**
- Market deployment and registration
- Central Position NFT contract
- Liquidator contract
- Reputation Registry
- Arch Controller integration

#### RevvFiArchController

Central permission and registry management system.

**Key Functions:**
- `registerBorrower()` - Approves new borrower to create markets
- `registerMarket()` - Registers new market in protocol
- `registerController()` - Approves controller contracts

**Maintains:**
- Approved borrower whitelist
- Registered market list
- Controller permissions
- Asset blacklist

#### RevvFiMarket

Core lending market contract managing borrowing, repayment, and interest.

**Key Functions:**
- `depositCollateral()` - Borrower deposits collateral
- `withdrawCollateral()` - Borrower withdraws collateral (if healthy)
- `borrow()` - Matches borrow request with available offers
- `repay()` - Borrower repays principal and interest
- `claimRepayment()` - Lender claims their portion of repayments
- `liquidate()` - Initiates liquidation for unhealthy positions

**Manages:**
- Debt accounting per lender position
- Interest accrual and APR tracking
- Position lifecycle (active → settled)
- Collateral health monitoring
- Market state (open/closed/paused)

#### RevvFiCollateralEscrow

Secure collateral custody and valuation.

**Key Functions:**
- `depositCollateral()` - Add collateral to escrow
- `withdrawCollateral()` - Withdraw collateral (with health check)
- `getCollateralValue()` - Calculate collateral value via oracle
- `checkHealth()` - Evaluate collateral ratio status

**Features:**
- Chainlink oracle integration
- Decimal handling for token mismatches
- Stale price detection (2-hour threshold)
- Health status enumeration (Healthy/Warning/Liquidatable)

#### RevvFiOfferBook

Lending offer management and matching engine.

**Key Functions:**
- `submitOffer()` - Lender submits lending offer
- `cancelOffer()` - Lender cancels unmatched offer
- `getOffers()` - Query active offers by criteria
- `getLowestAprOffers()` - Get best available rates

**Features:**
- Priority matching (lowest APR first)
- Offer expiration mechanism
- Per-lender offer limits (max 20)
- Global offer cap (max 500)
- Seniority-level support
- Expired offer cleanup

#### RevvFiPositionNFT

ERC721 representation of lender positions.

**Key Functions:**
- `mintPosition()` - Create position NFT for new lender
- `redeemPosition()` - Burn NFT when position fully settled
- `getLenderByTokenId()` - Query position owner

**Data Encoded:**
- Principal amount
- Interest rate (APR)
- Seniority level
- Market address
- Creation timestamp
- Active status

#### RevvFiLiquidator

Auction-based liquidation mechanism.

**Key Functions:**
- `createAuction()` - Initiate Dutch auction for collateral
- `getCurrentPrice()` - Calculate current auction price
- `placeBid()` - Submit bid on active auction
- `settleAuction()` - Finalize auction and distribute proceeds

**Auction Mechanics:**
- Duration: 3 days
- Price Decay: 5% per hour
- Reserve Price: 80% of debt
- Bid Increment: 1% minimum
- Extension Window: 15 minutes (extended when bids placed near end)

#### RevvFiLiquidityQueue

Withdrawal request management with epoch-based processing.

**Key Functions:**
- `requestWithdrawal()` - Queue position for withdrawal
- `cancelWithdrawalRequest()` - Cancel pending request
- `processEpoch()` - Calculate and distribute withdrawals
- `claimWithdrawal()` - Lender claims fulfilled amount

**Configuration:**
- Epoch Duration: 7 days
- Max Requests Per Epoch: 500
- Position Locking: During active withdrawal request

#### ReputationRegistry

On-chain borrower performance tracking and scoring.

**Key Functions:**
- `registerBorrower()` - Create borrower profile (starting score: 500)
- `recordBorrowActivity()` - Log new loan origination
- `recordSuccessfulRepayment()` - Update after successful repayment
- `recordDefault()` - Penalize borrower for defaults
- `getRiskLabel()` - Get letter rating (AAA-D) for borrower

**Scoring Algorithm:**
```
Score = (Successful Loans / Total Loans × 1000) - (Defaults × 50)
Range: 0-1000
```

## Deployed Contracts

RevvFi is currently live on the following networks. Addresses below reflect the most recent deployment logs. Always cross-check against the linked block explorer and the project's `broadcast/` artifacts before interacting with any contract.

### Sepolia Testnet

[![Network: Sepolia](https://img.shields.io/badge/Network-Sepolia-7CA1F6?logo=ethereum&logoColor=white)](https://sepolia.etherscan.io/)

| Network | Chain ID | RPC |
|---|---|---|
| Sepolia | 11155111 | `https://sepolia.infura.io/v3/YOUR_KEY` |

**Protocol Contracts**

| Contract | Address | Explorer |
|---|---|---|
| ArchController | `0x03Fb4beFaF8Ec0AC0D91CfE78ee5A65559CBDE68` | [View](https://sepolia.etherscan.io/address/0x03Fb4beFaF8Ec0AC0D91CfE78ee5A65559CBDE68) |
| Factory | `0x040Da0AB6abF40d1c175AB9f11265D2825e9730c` | [View](https://sepolia.etherscan.io/address/0x040Da0AB6abF40d1c175AB9f11265D2825e9730c) |
| PositionNFT | `0xc685f0F5472304D73964bDf8980652F7d023c485` | [View](https://sepolia.etherscan.io/address/0xc685f0F5472304D73964bDf8980652F7d023c485) |
| Liquidator | `0x6bf84c9aa29c28f70C9c5DbC837310DB8fEaDF7f` | [View](https://sepolia.etherscan.io/address/0x6bf84c9aa29c28f70C9c5DbC837310DB8fEaDF7f) |
| ReputationRegistry | `0x3895D539D8E09aa6809274e0F881490b2fC25B3C` | [View](https://sepolia.etherscan.io/address/0x3895D539D8E09aa6809274e0F881490b2fC25B3C) |

**Implementation Contracts**

| Contract | Address | Explorer |
|---|---|---|
| Market Implementation | `0xd5b86aA515d121197e29DE353c5BF11A4578bd5a` | [View](https://sepolia.etherscan.io/address/0xd5b86aA515d121197e29DE353c5BF11A4578bd5a) |
| Escrow Implementation | `0x6247D163A0e1b2cfdD5ECAecbc6648D18192728e` | [View](https://sepolia.etherscan.io/address/0x6247D163A0e1b2cfdD5ECAecbc6648D18192728e) |
| OfferBook Implementation | `0xF51101c98bcDE6a9ccad65a7Df538f558Af907D4` | [View](https://sepolia.etherscan.io/address/0xF51101c98bcDE6a9ccad65a7Df538f558Af907D4) |
| LiquidityQueue Implementation | `0x29D187421416B260530034A662A79712d7f7c97b` | [View](https://sepolia.etherscan.io/address/0x29D187421416B260530034A662A79712d7f7c97b) |

**Example Market**

| Contract | Address | Explorer |
|---|---|---|
| Market (WETH/USDC) | `0x44978cff4366A4c0C412dD3d16103247e19e4e2d` | [View](https://sepolia.etherscan.io/address/0x44978cff4366A4c0C412dD3d16103247e19e4e2d) |

**Mock Tokens & Oracle** (testnet only — not used in production)

| Contract | Address | Explorer |
|---|---|---|
| Mock USDC | `0xaB72BDdD3aa47A23b1F4D821C8018826Eb505528` | [View](https://sepolia.etherscan.io/address/0xaB72BDdD3aa47A23b1F4D821C8018826Eb505528) |
| Mock WETH | `0xA8d016492488F3116f5bB3f1E86009690C740E78` | [View](https://sepolia.etherscan.io/address/0xA8d016492488F3116f5bB3f1E86009690C740E78) |
| Chainlink Oracle (WETH/USD) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | [View](https://sepolia.etherscan.io/address/0x694AA1769357215DE4FAC081bf1f309aDC325306) |

**Roles**

| Role | Address |
|---|---|
| Admin (Deployer) | `0x6cCf36a79BE659b4caF703A07E043FC1b15a9e29` |
| Borrower | `0xDFe588a31E4CC6da86f10d86275883ac70B2667E` |

### Polygon Mainnet

[![Network: Polygon](https://img.shields.io/badge/Network-Polygon-8247E5?logo=polygon&logoColor=white)](https://polygonscan.com/)


RevvFi is live on Polygon mainnet. This is a production deployment using real assets — always verify addresses against Polygonscan before interacting with any contract.
 
| Network | Chain ID | RPC |
|---|---|---|
| Polygon | 137 | `https://polygon-rpc.com` |
 
**Protocol Contracts**
 
| Contract | Address | Explorer |
|---|---|---|
| ArchController | `0x29D187421416B260530034A662A79712d7f7c97b` | [View](https://polygonscan.com/address/0x29D187421416B260530034A662A79712d7f7c97b) |
| Factory | `0xF51101c98bcDE6a9ccad65a7Df538f558Af907D4` | [View](https://polygonscan.com/address/0xF51101c98bcDE6a9ccad65a7Df538f558Af907D4) |
| PositionNFT | `0xc685f0F5472304D73964bDf8980652F7d023c485` | [View](https://polygonscan.com/address/0xc685f0F5472304D73964bDf8980652F7d023c485) |
| Liquidator | `0x6bf84c9aa29c28f70C9c5DbC837310DB8fEaDF7f` | [View](https://polygonscan.com/address/0x6bf84c9aa29c28f70C9c5DbC837310DB8fEaDF7f) |
| ReputationRegistry | `0x3895D539D8E09aa6809274e0F881490b2fC25B3C` | [View](https://polygonscan.com/address/0x3895D539D8E09aa6809274e0F881490b2fC25B3C) |
 
**Implementation Contracts**
 
| Contract | Address | Explorer |
|---|---|---|
| Market Implementation | `0xaB72BDdD3aa47A23b1F4D821C8018826Eb505528` | [View](https://polygonscan.com/address/0xaB72BDdD3aa47A23b1F4D821C8018826Eb505528) |
| Escrow Implementation | `0xA8d016492488F3116f5bB3f1E86009690C740E78` | [View](https://polygonscan.com/address/0xA8d016492488F3116f5bB3f1E86009690C740E78) |
| OfferBook Implementation | `0xd5b86aA515d121197e29DE353c5BF11A4578bd5a` | [View](https://polygonscan.com/address/0xd5b86aA515d121197e29DE353c5BF11A4578bd5a) |
| LiquidityQueue Implementation | `0x6247D163A0e1b2cfdD5ECAecbc6648D18192728e` | [View](https://polygonscan.com/address/0x6247D163A0e1b2cfdD5ECAecbc6648D18192728e) |
 
**Example Market**
 
| Contract | Address | Explorer |
|---|---|---|
| Market (WETH/USDC) | `0x7CDA02daB71dfC6340319cf64310e2BB463a3C82` | [View](https://polygonscan.com/address/0x7CDA02daB71dfC6340319cf64310e2BB463a3C82) |
 
**External Contracts** (native Polygon mainnet assets — not deployed by RevvFi)
 
| Contract | Address | Explorer |
|---|---|---|
| USDC (native) | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | [View](https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359) |
| WETH | `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619` | [View](https://polygonscan.com/address/0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619) |
| Oracle (ETH/USD) | `0xF9680D99D6C9589e2a93a78A04A279e509205945` | [View](https://polygonscan.com/address/0xF9680D99D6C9589e2a93a78A04A279e509205945) |
 
**Roles**
 
| Role | Address |
|---|---|
| Admin (Deployer) | `0x6cCf36a79BE659b4caF703A07E043FC1b15a9e29` |
| Fee Recipient | `0x6cCf36a79BE659b4caF703A07E043FC1b15a9e29` |
| Borrower | `0xDFe588a31E4CC6da86f10d86275883ac70B2667E` |

## How It Works

### Scenario: Complete Lending Cycle

#### Step 1: Borrower Deploys Market

```
1. Borrower registers with ArchController
2. Borrower calls Factory.deployMarket() with:
   - Borrow asset (e.g., USDC)
   - Collateral asset (e.g., WETH)
   - Collateral oracle (Chainlink WETH/USD)
   - Min collateral ratio (e.g., 150%)
   - Liquidation threshold (e.g., 130%)
3. Factory deploys:
   - RevvFiMarket instance
   - RevvFiCollateralEscrow instance
   - RevvFiOfferBook instance
   - RevvFiLiquidityQueue instance
4. All components interconnected and registered
5. Borrower receives market address
```

#### Step 2: Lenders Submit Offers

```
1. Lender approves OfferBook to spend borrow asset
2. Lender calls OfferBook.submitOffer():
   - Amount: 100,000 USDC
   - APR: 500 bps (5%)
   - Seniority: 0 (Senior)
   - Duration: 30 days
3. OfferBook transfers funds and creates offer entry
4. Offer added to active list, tracked by APR
```

#### Step 3: Borrower Deposits Collateral

```
1. Borrower approves Market to spend collateral (WETH)
2. Borrower calls Market.depositCollateral(10 WETH):
3. Market transfers WETH to CollateralEscrow
4. Escrow records 10 WETH @ 150% ratio requirement
5. Maximum borrowable: 10 WETH × $2000/WETH / 1.5 = $13,333 USDC
```

#### Step 4: Borrower Borrows

```
1. Borrower calls Market.borrow(50,000 USDC, false, 600 bps):
   - Amount: 50,000 USDC
   - Only senior offers: false
   - Max APR: 600 bps
2. Market.borrow() calls OfferBook.matchOffers()
3. Offers matched in order of lowest APR:
   - Lender 1: 50,000 @ 500 bps → Position 1 created, NFT minted
4. Interest accrual triggered
5. Borrowed funds transferred to borrower
```

#### Step 5: Interest Accrues

```
1. Every 7 days:
   Interest = 50,000 × 500 bps × 604,800s / (31,536,000s × 10,000)
            = 50,000 × 0.05 × (7/365)
            = 479.45 USDC
2. Lender's accrued interest tracked
3. Borrower's debt increases: 50,000 → 50,479.45
```

#### Step 6: Borrower Repays

```
1. Borrower approves Market to spend 50,500 USDC (principal + interest)
2. Borrower calls Market.repay(50,500):
3. Market distributes:
   - Lender 1: 50,000 principal + accrued interest
4. Position marked as settled
5. Reputation score improves
```

#### Step 7: Lender Withdraws

```
1. Lender calls LiquidityQueue.requestWithdrawal(tokenId=1, amount=50500):
2. Withdrawal queued for next epoch
3. Position NFT locked
4. At epoch end, Factory.processEpoch():
5. Liquidity calculated and distributed
6. Lender calls LiquidityQueue.claimWithdrawal()
7. USDC transferred to lender's wallet
```

### Alternative: Liquidation Scenario

If WETH price drops to $1500:

```
Ratio = 10 × $1500 / $50,500 = 29.7% < 130% threshold

1. Market.liquidate() called
2. CollateralEscrow marks position for liquidation
3. Liquidator.createAuction(10 WETH for ~$50,500 USDC):
   - Start Price: $50,500
   - Decrement: 5% per hour
   - Reserve: $40,400
4. Bidders place offers to purchase 10 WETH
5. After 3 days or winning bid:
   - Liquidator.settleAuction()
   - Proceeds distributed to lenders (senior first)
   - Remaining collateral returned to borrower (if any)
```

## Getting Started

### Prerequisites

- Node.js 16.x or higher
- Foundry (for Solidity development and testing)
  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ```
- Git

### Installation

Clone the repository:

```bash
git clone https://github.com/your-org/revvfi-contracts.git
cd revvfi-contracts
```

Install dependencies:

```bash
forge install
```

Build contracts:

```bash
forge build
```

### Environment Setup

Create a `.env` file in the root directory:

```bash
# Network RPC endpoints
SEPOLIA_RPC=https://sepolia.infura.io/v3/YOUR_KEY
POLYGON_RPC=https://polygon-rpc.com

# Private keys for deployment
DEPLOYER_PRIVATE_KEY=0x...
ORACLE_SIGNER_PRIVATE_KEY=0x...
```

### Deployment

To deploy:

```bash
# Load environment variables
source .env

# Deploy to Sepolia testnet
forge script script/DeployRevvFi.s.sol --rpc-url $SEPOLIA_RPC --private-key $DEPLOYER_PRIVATE_KEY --broadcast

# Deploy to Polygon mainnet
forge script script/DeployRevvFi.s.sol --rpc-url $POLYGON_RPC --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify
```

> **Mainnet caution:** Polygon deployment above uses real funds and is irreversible once broadcast. Run the full test suite, double-check constructor arguments, and confirm the deployer wallet/private key before running this against `$POLYGON_RPC`. The `--verify` flag submits source code to Polygonscan so the contract is publicly verifiable.

## Testing

### Run All Tests

```bash
forge test
```

### Run Specific Test Suite

```bash
# Unit tests
forge test --match-path "test/unit/*"

# Integration tests
forge test --match-path "test/integration/*"

# Specific contract tests
forge test --match-contract "RevvFiMarketTest"
```

### Run Tests with Gas Reports

```bash
forge test --gas-report
```

### Run Tests with Coverage

```bash
forge coverage --report lcov
```

### Test Structure

```
test/
├── unit/                          # Individual contract tests
│   ├── RevvFiMarket.t.sol
│   ├── RevvFiCollateralEscrow.t.sol
│   ├── RevvFiOfferBook.t.sol
│   ├── RevvFiPositionNFT.t.sol
│   └── RevvFiArchController.t.sol
├── integration/                   # Multi-contract interaction tests
│   ├── FullLoanLifecycle.t.sol
│   ├── LiquidationLifeCycle.sol
│   └── EdgeCaseIntegrationTest.sol
├── mocks/                         # Mock tokens and oracles
│   ├── MockERC20.sol
│   ├── MockOracle.sol
│   └── MockPositionNFT.sol
└── utils/                         # Test utilities
    └── testUtils.sol
```

### Key Test Areas

- **Collateral Management**: Deposit, withdraw, health checks
- **Offer Matching**: APR discovery, seniority handling
- **Interest Accrual**: Timing, rounding, multiple positions
- **Liquidation**: Dutch auction mechanics, bid handling
- **Reputation**: Score calculation, penalty application
- **Edge Cases**: Price oracle failures, rounding errors, reentrancy

## Security Considerations

### Reentrancy Protection

All external functions use OpenZeppelin's `ReentrancyGuard` to prevent reentrancy attacks.

### Oracle Risk

- **Implementation**: Chainlink price feeds with configurable staleness threshold (2 hours)
- **Mitigation**:
  - Staleness checks before using prices
  - Liquidation reserve price ensures recovery even with price volatility
  - Liquidation threshold provides safety margin

### Arithmetic Safety

- **Solidity 0.8.33**: Native overflow/underflow protection
- **SafeERC20**: Used for all token transfers with revert on failure
- **Decimal Handling**: Careful calculation of collateral value across token decimals

### Access Control

- **Role-Based**: Factory, market, and escrow contracts enforce caller validation
- **Timelock**: Arch controller updates require 2-day timelock delay
- **Owner Functions**: Critical configuration changes only via owner calls

### Liquidation Safeguards

- **Reserve Price**: Ensures minimum recovery at 80% of debt
- **Auction Duration**: 3 days allows market participation
- **Price Decay**: Gradual decline encourages competitive bidding
- **Bid Extension**: Late bids extend auction to prevent sniping

### Withdrawal Queue Safety

- **Epoch-Based**: Prevents flash loan attacks and bank runs
- **Position Locking**: NFTs locked during withdrawal to prevent double-spending
- **Proportional Fulfillment**: Available liquidity distributed fairly

### Known Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Stale Oracle Price | 2-hour staleness check; liquidation reserve ensures safety |
| Flash Loan Attack | Epoch-based withdrawals; position locking |
| Bad Debt Spiral | Junior position subordination; reputation penalties |
| Liquidation Cascade | Gradual price decay in Dutch auction; 3-day duration |
| Reentrancy | ReentrancyGuard on all state-changing functions |

### Audit Recommendations

- [ ] Third-party smart contract audit
- [ ] Formal verification of critical paths (interest accrual, liquidation)
- [ ] Economic simulation of edge cases
- [ ] Long-term oracle reliability assessment

## Contract Specifications

### Solidity Version

- **Target**: Solidity 0.8.33
- **Compiler**: With optimizations enabled (200 runs)

### Dependencies

- **OpenZeppelin Contracts**: 4.9+
- **Chainlink Contracts**: Latest stable
- **Foundry/Forge-std**: Latest

### Key Constants

| Parameter | Value | Purpose |
|---|---|---|
| `MAX_APR_BPS` | 5000 (50%) | Upper limit on interest rates |
| `MAX_ACTIVE_POSITIONS` | 100 | Maximum concurrent lender positions per market |
| `EPOCH_DURATION` | 7 days | Withdrawal processing interval |
| `TIMELOCK_DURATION` | 2 days | Arch controller change delay |
| `AUCTION_DURATION` | 3 days | Liquidation auction window |
| `DUTCH_DECREMENT` | 500 bps (5%) | Hourly price decrease |

### State Variables

All state variables are carefully chosen to balance:

- **Gas Efficiency**: Minimal storage operations
- **Security**: Prevention of manipulation
- **Transparency**: Full on-chain state visibility
- **Upgradeability**: Design allows future improvements via new implementations

## Development & Contribution

### Code Style

- Follow Solidity style guide (4-space indents)
- Use descriptive variable names
- Add NatSpec comments for public functions
- Organize functions: external, public, internal, private

### Testing Requirements

- Minimum 90% code coverage
- All state changes tested
- Edge cases documented
- Integration tests for contract interactions

### Common Development Tasks

**Formatting:**

```bash
forge fmt
```

**Linting:**

```bash
solhint 'src/**/*.sol'
```

**Gas Optimization:**

```bash
forge build --optimize --optimizer-runs 200
```

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

This project is licensed under the MIT License — see the [LICENSE](./LICENSE) file for details.

## Additional Resources

- [Foundry Documentation](https://book.getfoundry.sh/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Chainlink Oracle Integration](https://docs.chain.link/)
- [ERC721 Standard](https://eips.ethereum.org/EIPS/eip-721)
- [Solidity Documentation](https://docs.soliditylang.org/)

## Support

For questions, issues, or contributions, please open an issue on GitHub or reach out to the development team.

---

**Authors**: Preet Singh
**Protocol Version**: 1.0
**Last Updated**: June 2026
