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

1.  **Greater Capital Efficiency:** By routing trades through a V3 router, our contract can benefit from concentrated liquidity. This means we require less total capital to generate the same market impact and maintain stable exchange prices for users.
2.  **Superior Pricing for Users:** Transactions executed via the V3 architecture generally find optimal swap paths, ensuring the user receives the best possible rate with minimized slippage.
3.  **Standardization:** We are integrating with industry-standard contracts, making the protocol more compatible, trustworthy, and auditable.

In essence, we've upgraded from a standard engine to a turbocharged one, making the system faster, more robust, and more economical in terms of gas consumption (when considering the overall swap execution price).

## 2. 🛠️ Deployment and Interaction Instructions

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
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --chain-id 11155111 \
  --etherscan-api-key $ETHERSCAN_KEY \
  -vvvvv
