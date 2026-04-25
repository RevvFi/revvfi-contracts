# RevvFi Protocol

RevvFi is a decentralized fair-launch platform and liquidity bootstrapping protocol deployed on **Polygon**. It enables creators to launch tokens with built-in investor protections, automated liquidity provisioning, and LP-governed treasuries—all without a native platform token.

## 🚀 Overview

RevvFi implements a unique "Per-Token Contract Isolation" model. Every launch generates a dedicated ecosystem of smart contracts, ensuring security and independent governance for every community.

### Key Features
- **Zero-Token Governance:** LP shares act as direct voting power; no separate REVV token required.
- **Investor Protection:** Mandatory `TreasuryVault` controlled exclusively by LPs to mitigate losses.
- **Fair Launch Logic:** Automated Uniswap V2 liquidity deployment or proportional ETH refunds if targets aren't met.
- **Anti-Spam:** 0.1 ETH `LAUNCH_FEE` to ensure high-quality project listings.

---

## 🏗 Architecture

RevvFi utilizes a factory pattern to deploy a suite of isolated contracts for each project:

* **RevvFiFactory:** The entry point. Manages the registry and enforces protocol fees.
* **RevvFiBootstrapper:** The orchestrator. Handles deposits, liquidity locks, and withdrawals.
* **Vault System:**
    * `CreatorVestingVault`: Cliff + linear vesting for creators.
    * `TreasuryVault`: 100% LP-controlled funds for project stability.
    * `StrategicReserveVault`: Strict, timelocked reserves for long-term growth.
---

## 🔧 Technical Specifications

### Maturity Logic
Withdrawals are governed by a strictly enforced maturity timestamp:
`maturityTime = raiseEndTime + lockDuration`
* **Min Lock:** 30 Days
* **Max Lock:** 730 Days

### Governance Thresholds
| Proposal Type | Target | Approval | Timelock |
| :--- | :--- | :--- | :--- |
| **Treasury Release** | TreasuryVault | 60% | 7 Days |
| **Strategic Release** | StrategicReserve | 66% | 14 Days |
| **Lock Reduction** | Bootstrapper | 75% + Creator | 14 Days |

---

## 💻 Development & Deployment

### Prerequisites
- Foundry 
- Alchemy/Infura API Key (Polygon)

### Deployment Fees
Creators must provide a **0.1 ETH** launch fee when calling `createLaunch`. This fee is non-refundable and is transferred to the platform treasury to prevent Sybil attacks.

### Target Networks
1. **Polygon** (Primary)
2. **Ethereum Mainnet** (Secondary)

---

## 🛡 Security

- **Isolation:** Funds for Project A cannot be affected by Project B.
- **Immutable Tokens:** Tokens are deployed via audited templates with no mint/pause functions.
- **Guardian Multisig:** A platform-level multisig can pause new launches in the event of an emergency.

---

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

© 2026 RevvFi Protocol.