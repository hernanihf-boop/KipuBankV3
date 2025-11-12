// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";

/**
 * @title KipuBankV3
 * @author Hernán Iannello
 * @notice Smart contract which allows users to deposit ETH or any ERC20 token 
 * (supported by Uniswap V2) and automatically swaps the deposit into USDC. 
 */
contract KipuBankV3 is ReentrancyGuard, Ownable {
    // ====================================================================
    // CONSTANTS & IMMUTABLES
    // ====================================================================

    /**
     * @dev We use the address(0) to represent the Native Token (ETH/Gas Token).
     */
    address private constant NATIVE_TOKEN_ADDRESS = address(0);

    /**
     * @dev Address of the Wrapped Native Token (WETH). Used in Uniswap paths.
     */
    address public immutable WETH_ADDRESS;

    /**
     * @dev Address of the USDC stablecoin (6 decimals).
     */
    address public immutable USDC_ADDRESS;

    /**
     * @dev Address of the Uniswap V2 Router.
     */
    IUniswapV2Router02 public immutable UNISWAP_ROUTER;

    /**
     * @dev Maximum limit of USDC that can be withdrawn in a single transaction (6 decimals).
     * Set to $1000 USD (1000 * 10**6).
     */
    uint256 public constant MAX_WITHDRAWAL_USDC = 1000 * 1e6;

    /**
     * @dev Total capacity of USDC the bank can hold (6 decimals).
     * Fixed in deployment to ensure capacity.
     */
    uint256 private immutable BANK_CAP_USDC;

    // ====================================================================
    // STATE & STORAGE
    // ====================================================================

    /**
     * @dev Mapping: userAddress => balance (in USDC, 6 decimals).
     */
    mapping(address => uint256) private balances;

    /**
     * @dev Total deposits counter.
     */
    uint256 private totalDeposits;

    /**
     * @dev Total withdeawal counter.
     */
    uint256 private totalWithdrawals;

    // ====================================================================
    // EVENTS
    // ====================================================================

    event DepositSwapped(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcReceived);
    event WithdrawalSuccessful(address indexed user, uint256 usdcAmount);
    
    // ====================================================================
    // CUSTOM ERRORS
    // ====================================================================

    error ZeroAmount();
    error BankCapExceeded(uint256 currentTotalUsdc, uint256 requestedUsdcAmount, uint256 bankCap); 
    error InvalidBankCapValue();
    error InsufficientFunds(uint256 available, uint256 requested);
    error WithdrawalLimitExceeded(uint256 limit, uint256 requested);
    error TransferFailed(address token);
    error UniswapSwapFailed();
    error ZeroUsdcReceived();
    error InvalidRouterAddress();
    error InvalidWethAddress();
    error InvalidUsdcAddress();

    // ====================================================================
    // CONSTRUCTOR
    // ====================================================================

    /**
    * @dev Constructor that initializes the contract.
    * @param _router Address of the Uniswap V2 Router.
    * @param _wethAddress Address of the WETH token.
    * @param _usdcAddress Address of the USDC token (assumed 6 decimals).
    * @param _bankCapUsd The total USDC limit the contract can handle/accept (in USD units).
    * @notice Sets the contract owner, the Uniswap Router, WETH address, USDC address, and the global deposit limit.
    */
    constructor(
        address _router,
        address _wethAddress, 
        address _usdcAddress, 
        uint256 _bankCapUsd
    ) Ownable(msg.sender) {
        if (_router == address(0)) revert InvalidRouterAddress();
        if (_wethAddress == address(0)) revert InvalidWethAddress();
        if (_usdcAddress == address(0) || _usdcAddress == NATIVE_TOKEN_ADDRESS) revert InvalidUsdcAddress();
        if (_bankCapUsd == 0) revert InvalidBankCapValue();

        UNISWAP_ROUTER = IUniswapV2Router02(_router);
        USDC_ADDRESS = _usdcAddress;
        WETH_ADDRESS = _wethAddress;
        BANK_CAP_USDC = _bankCapUsd * 1e6; 
    }

    // ====================================================================
    // FALLBACK / RECEIVE 
    // ====================================================================

    /**
    * @dev The 'receive' function is executed when someone sends the native token (ETH) to the contract.
    */
    receive() external payable {
        depositNativeToken();
    }

    // ====================================================================
    // PUBLIC DEPOSIT FUNCTIONS
    // ====================================================================

    /**
     * @notice Deposits native ETH and swaps it to USDC via Uniswap V2.
     * @dev The ETH amount is taken from `msg.value`. Reverts if no ETH is sent.
     * On failure, the ETH is refunded to the caller.
     */
    function depositNativeToken() public payable nonReentrant {
        uint256 amountIn = msg.value;
        address user = msg.sender;

        if (amountIn == 0) revert ZeroAmount();
        
        address[] memory path = new address[](2);
        path[0] = WETH_ADDRESS;
        path[1] = USDC_ADDRESS;

        uint256 usdcBefore = IERC20(USDC_ADDRESS).balanceOf(address(this));
        
        try UNISWAP_ROUTER.swapExactETHForTokens{value: amountIn}(
            0,
            path,
            address(this),
            block.timestamp
        ) {
            uint256 usdcAfter = IERC20(USDC_ADDRESS).balanceOf(address(this));
            uint256 usdcReceived = usdcAfter - usdcBefore;
            
            if (usdcReceived == 0) revert ZeroUsdcReceived();

            uint256 maxCap = BANK_CAP_USDC;
            if (usdcAfter > maxCap) {
                revert BankCapExceeded(usdcAfter, usdcReceived, maxCap);
            }
            
            balances[user] += usdcReceived;
            totalDeposits++;

            emit DepositSwapped(user, NATIVE_TOKEN_ADDRESS, amountIn, usdcReceived);
        } catch {
            (bool sent, ) = payable(user).call{value: amountIn}("");
            if (!sent) revert TransferFailed(NATIVE_TOKEN_ADDRESS);
            revert UniswapSwapFailed();
        }
    }

    /**
    * @notice Deposits any ERC20 token and automatically swaps it to USDC.
    * @param _token Address del ERC20 token IN.
    * @param _amount Amount to deposit (in token units).
    */
    function depositToken(
        address _token,
        uint256 _amount
    ) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_token == NATIVE_TOKEN_ADDRESS) revert TransferFailed(NATIVE_TOKEN_ADDRESS);

        address user = msg.sender;
        IERC20 tokenIn = IERC20(_token);
        uint256 usdcReceived;

        bool successTransferFrom = tokenIn.transferFrom(user, address(this), _amount);
        if (!successTransferFrom) revert TransferFailed(_token);
        
        if (_token == USDC_ADDRESS) {
            usdcReceived = _amount;
        } else {            
            bool successApprove = tokenIn.approve(address(UNISWAP_ROUTER), _amount);
            if (!successApprove) revert TransferFailed(_token);

            address[] memory path = new address[](2);
            path[0] = _token;
            path[1] = USDC_ADDRESS;

            uint256 usdcBeforeSwap = IERC20(USDC_ADDRESS).balanceOf(address(this));
            
            try UNISWAP_ROUTER.swapExactTokensForTokens(
                _amount,
                0,
                path,
                address(this),
                block.timestamp
            ) returns (uint[] memory) {
                uint256 usdcAfterSwap = IERC20(USDC_ADDRESS).balanceOf(address(this));
                usdcReceived = usdcAfterSwap - usdcBeforeSwap;
                
                if (usdcReceived == 0) revert ZeroUsdcReceived();
                
                bool successApproveZero = tokenIn.approve(address(UNISWAP_ROUTER), 0);
                if (!successApproveZero) revert TransferFailed(_token);
                
            } catch {
                revert UniswapSwapFailed();
            }
        }
        
        uint256 currentTotalUsdc = IERC20(USDC_ADDRESS).balanceOf(address(this));
        uint256 maxCap = BANK_CAP_USDC;
        if (currentTotalUsdc > maxCap) {
            revert BankCapExceeded(currentTotalUsdc, usdcReceived, maxCap);
        }

        balances[user] += usdcReceived;        
        totalDeposits++;
        
        emit DepositSwapped(user, _token, _amount, usdcReceived);
    }

    // ====================================================================
    // PUBLIC WITHDRAW FUNCTIONS
    // ====================================================================

    /**
     * @notice Withdraws USDC from the user's balance.
     * @dev Reverts if the amount exceeds MAX_WITHDRAWAL_USDC or the user's balance.
     * @param _usdcAmount The amount to withdraw, in USDC units.
     */
    function withdraw(uint256 _usdcAmount) external nonReentrant {
        if (_usdcAmount == 0) revert ZeroAmount();

        if (_usdcAmount > MAX_WITHDRAWAL_USDC) {
            revert WithdrawalLimitExceeded(MAX_WITHDRAWAL_USDC, _usdcAmount);
        }

        uint256 userUsdcBalance = balances[msg.sender];
        if (_usdcAmount > userUsdcBalance) {
            revert InsufficientFunds(userUsdcBalance, _usdcAmount);
        }

        unchecked {
            balances[msg.sender] = userUsdcBalance - _usdcAmount;
        }

        bool successTransfer = IERC20(USDC_ADDRESS).transfer(msg.sender, _usdcAmount);
        if (!successTransfer) revert TransferFailed(USDC_ADDRESS);
        totalWithdrawals++;

        emit WithdrawalSuccessful(msg.sender, _usdcAmount);
    }
    
    // ====================================================================
    // VIEW & UTILITY FUNCTIONS
    // ====================================================================

    /**
     * @notice Returns the total USDC held by the contract (6 decimals), including all reserves.
     * @dev Restricted to the contract owner. Includes both user deposits and any excess funds.
     * @return The total USDC balance of the contract.
     */
    function getTotalBankValueUsdc() external view onlyOwner returns (uint256) {
        return IERC20(USDC_ADDRESS).balanceOf(address(this)); 
    }

    /**
     * @notice Returns the caller's USDC balance in the contract (6 decimals).
     * @return The user's balance in USDC.
     */
    function getUsdcBalance() external view returns (uint256) {
        return balances[msg.sender];
    }
    
    /**
     * @notice Returns the total number of successful deposit operations.
     * @return totalDeposits The cumulative count of deposit transactions.
     */
    function getTotalDepositsCount() public view returns (uint256) {
        return totalDeposits;
    }

    /**
     * @notice Returns the total number of successful withdrawal operations.
     * @return totalWithdrawals The cumulative count of withdrawal transactions.
     */
    function getTotalWithdrawalsCount() public view returns (uint256) {
        return totalWithdrawals;
    }

    /**
     * @notice Returns the maximum USDC capacity the contract can hold (6 decimals, same as USDC).
     * @dev This value is set at deployment and cannot be modified.
     * @return The bank's capacity in USDC (e.g., 10_000_000 = 10,000 USDC).
     */
    function getBankCap() public view returns (uint256) {
        return BANK_CAP_USDC;
    }
}
