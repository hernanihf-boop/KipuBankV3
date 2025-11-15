# README: KipuBank V3 - An Architectural Upgrade

Welcome to the source code for KipuBank, now in its version 3!

This is the most advanced and capital-efficient version of our protocol, engineered to leverage the latest innovations in the decentralized ecosystem.

## 1. 🚀 High-Level Explanation and Rationale

The fundamental improvement in V3 lies in a paradigm shift concerning liquidity management and asset swapping mechanisms.

### What Was Implemented?

The core logic from V2 was migrated to an architecture that interacts with the established standards and routers of the most efficient on-chain exchange protocols (typically those utilizing **Concentrated Liquidity**).

### Why the Upgrade? (The Rationale for V3)

The previous version (V2) was prone to inefficiency under high trading volumes, resulting in high **slippage** and requiring massive, often underutilized, capital expenditure.

With V3, we achieve:

1.  **Greater Capital Efficiency:** By routing trades through a V2 router, our contract can benefit from concentrated liquidity. This means we require less total capital to generate the same market impact and maintain stable exchange prices for users.
2.  **Superior Pricing for Users:** Transactions executed via the V3 architecture generally find optimal swap paths, ensuring the user receives the best possible rate with minimized slippage.
3.  **Standardization:** We are integrating with industry-standard contracts, making the protocol more compatible, trustworthy, and auditable.

In essence, we've upgraded from a standard engine to a turbocharged one, making the system faster, more robust, and more economical in terms of gas consumption (when considering the overall swap execution price).

## 2. ⚙️ Key Interaction Functions

A. Deposit Native ETH (Swaps to USDC):

```
// ETH sent as value is swapped for USDC, added to the user's internal balance.
function depositNativeToken(uint256 minUsdcOut) public payable; 
```

B. Deposit ERC20 (Direct or Swap):

```
// If tokenIn is USDC, it is deposited directly. If not (e.g., USDT), it is swapped to USDC.
function depositToken(address tokenIn, uint256 amountIn, uint256 minUsdcOut) public;
```

Note: The user must call approve(KipuBankV3, amount) on the tokenIn address before calling this function.

C. Withdraw USDC:

```
// Transfers the requested amount of USDC from the bank reserve to the user.
function withdraw(uint256 amountUsdc) public;
```

## 3. 🎨 Design Decisions and Trade-offs

### Trade-off (Risk/Inefficiency)

1. **Single-Asset Reserve (USDC)**

**Concentration Risk:** All protocol liquidity is held in a single asset. While simple for accounting, a major failure (e.g., depeg or censorship) of USDC would directly impact the entire bank's solvency and all user funds.

2. **Permissioned Ownership (Ownable)**

**Centralization:** The contract uses the simple Ownable pattern. The owner retains the power to adjust the bankCap (if implemented) or update associated addresses (routers), requiring users to place significant trust in the governance of the owner key.

3. **No Yield Generation**

**Capital Inefficiency:** The bank's reserves sit idle. While safer than exposing funds to complex DeFi protocols, it generates no yield for depositors, potentially making the bank less competitive than yield-generating vaults.

## 4. 🔎 Threat Analysis Report

A. Protocol Weaknesses and Missing Steps for Maturity

The KipuBank V3 achieves basic functionality with a major risk mitigation layer (the Cap), but it still lacks features typical of a mature DeFi protocol:


1. No Emergency Pause/Halt

Implement Emergency Governance: Add a Pausable module (e.g., from OpenZeppelin) controlled by a multi-sig or governance DAO. This is essential to halt deposits/withdrawals immediately upon discovery of a critical bug or external market failure (e.g., USDC depeg).

2. No Fee/Sustainability Model

Introduce Fee Structure: The current protocol is unsustainable. Implement a small withdrawal fee or a performance fee on reserves to cover gas costs, fund audits, and reward governance.

3. Withdrawal Limits

Per-User Withdrawal Limits: Add a per-user or time-based withdrawal limit (e.g., maximum 10k USDC per day) to prevent a sudden bank run from draining the available liquidity quickly.

4. No External Audit

Full Audit: A comprehensive audit by a reputable third-party security firm is mandatory before production deployment.


## 5. 🧪 Coverage

![Alt text](/coverage.png)


## 6. 🛠️ Deployment and Interaction Instructions

We use **Foundry (Forge)** for the deployment process.

### A. Prerequisites (Required Environment Variables)

Before deploying, ensure you have the following environment variables defined to keep your private key secure:

1.  **`$SEPOLIA_RPC_URL`**: The URL endpoint for your Sepolia node (obtained from Alchemy, Infura, or QuickNode).
2.  **`$PRIVATE_KEY`**: The private key of the wallet funding the deployment gas (ensure it holds Sepolia ETH).
3.  **`$ETHERSCAN_KEY`**: Your Etherscan/SepoliaScan API Key (required for verification).

### B. Deployment Command

Execute the following command from your project root. The script `script/DeployKipuBankV3.s.sol:DeployKipuBankV3` should contain the deployment logic.

```bash
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 \
  --rpc-url  $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_KEY \
  --chain-id 11155111 \
  --private-key $PRIVATE_KEY
```

### C. Interaction

1. Setup: Required Approvals (for ERC20 Deposits ONLY)

If a user intends to deposit any ERC20 token (like USDT, DAI, or even USDC directly) into the bank, they must first approve the KipuBank V3 contract to move those tokens from their wallet. This step is NOT required for native ETH deposits.

2. Deposit

A. Depositing Native ETH (depositNativeToken)

This function is used for sending native Ether. It automatically handles the conversion to WETH and then the swap to USDC.

B. Depositing ERC20 (depositToken)

This function is used for already approved ERC20 tokens. If the token is not USDC, it is swapped for USDC.

3. Withdrawing USDC (withdraw)

Users can only withdraw up to their recorded internal balance in USDC.
