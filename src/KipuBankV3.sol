// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";

/**
 * @title KipuBankV3
 * @author Hernán Iannello
 * @notice Smart contract that allows users to deposit ETH or any ERC20 token 
 * (supported by Uniswap V2) and automatically swaps the deposit into USDC.
 */
contract KipuBankV3 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

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
     * Set to $10000 USD (10000 * 10**6).
     */
    uint256 public constant MAX_WITHDRAWAL_USDC = 10000 * 1e6;

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
     * @dev Total withdrawal counter.
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
    error BankCapExceeded(uint256 currentTotalUsdc, uint256 receivedUsdcAmount, uint256 bankCap); 
    error InvalidBankCapValue();
    error InsufficientFunds(uint256 available, uint256 requested);
    error WithdrawalLimitExceeded(uint256 limit, uint256 requested);
    error TransferFailed(address token);
    error UniswapSwapFailed();
    error ZeroUsdcReceived();
    error InvalidAddress();
    error InvalidRouterAddress();
    error InvalidWethAddress();
    error InvalidUsdcAddress();
    error InvalidRecipientAddress();

    // ====================================================================
    // CONSTRUCTOR
    // ====================================================================

    /**
    * @dev Constructor that initializes the contract.
    * @param _router Address of the Uniswap V2 Router.
    * @param _wethAddress Address of the WETH token.
    * @param _usdcAddress Address of the USDC token (assumed 6 decimals).
    * @param _bankCapUsdc The total USDC limit the contract can handle/accept.
    * @notice Sets the contract owner, the Uniswap Router, WETH address, USDC address, and the global deposit limit.
    */
    constructor(
        address _router,
        address _wethAddress, 
        address _usdcAddress, 
        uint256 _bankCapUsdc
    ) Ownable(msg.sender) {
        if (_router == address(0)) revert InvalidRouterAddress();
        if (_wethAddress == address(0)) revert InvalidWethAddress();
        if (_usdcAddress == address(0) || _usdcAddress == NATIVE_TOKEN_ADDRESS) revert InvalidUsdcAddress();
        if (_bankCapUsdc == 0) revert InvalidBankCapValue();

        UNISWAP_ROUTER = IUniswapV2Router02(_router);
        USDC_ADDRESS = _usdcAddress;
        WETH_ADDRESS = _wethAddress;
        BANK_CAP_USDC = _bankCapUsdc * 1e6; // Convert to 6 decimals
    }

    // ====================================================================
    // FALLBACK / RECEIVE 
    // ====================================================================

    /**
    * @dev The 'receive' function is executed when someone sends the native token (ETH) to the contract.
    * It immediately calls the deposit function.
    */
    receive() external payable {
        depositNativeToken(0);
    }
    
    // ====================================================================
    // PUBLIC DEPOSIT FUNCTIONS
    // ====================================================================

    /**
    * @notice Allows any user to deposit the native token (ETH) and automatically swaps it to USDC.
    * @param _minUsdcOut The minimum amount of USDC expected, set by the user (slippage protection).
    */
    function depositNativeToken(uint256 _minUsdcOut) public payable nonReentrant {
        uint256 amountIn = msg.value;
        address user = msg.sender;

        if (amountIn == 0) revert ZeroAmount();
        
        address[] memory path = new address[](2);
        path[0] = WETH_ADDRESS;
        path[1] = USDC_ADDRESS;

        uint256 usdcReceived;
        try UNISWAP_ROUTER.swapExactETHForTokens{value: amountIn}(
            _minUsdcOut,
            path,
            address(this),
            block.timestamp + 1
        ) returns (uint[] memory amounts) {
            usdcReceived = amounts[amounts.length - 1];

            if (usdcReceived == 0) revert ZeroUsdcReceived();

        } catch {
            revert UniswapSwapFailed();
        }
        
        uint256 currentTotalUsdc = IERC20(USDC_ADDRESS).balanceOf(address(this));
        uint256 maxCap = BANK_CAP_USDC;
        
        if (currentTotalUsdc > maxCap) {
            revert BankCapExceeded(currentTotalUsdc, usdcReceived, maxCap);
        }
        
        balances[user] += usdcReceived;
        totalDeposits++; 

        emit DepositSwapped(user, NATIVE_TOKEN_ADDRESS, amountIn, usdcReceived);
    }

    /**
    * @notice Deposits any ERC20 token and automatically swaps it to USDC.
    * @param _token Address of the ERC20 token IN.
    * @param _amount Amount to deposit (in token units).
    * @param _minUsdcOut The minimum amount of USDC expected, set by the user (slippage protection).
    */
    function depositToken(
        address _token,
        uint256 _amount,
        uint256 _minUsdcOut
    ) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_token == NATIVE_TOKEN_ADDRESS) revert InvalidAddress();

        address user = msg.sender;
        IERC20(_token).safeTransferFrom(user, address(this), _amount);
        uint256 usdcReceived = _swapToUsdc(_token, _amount, address(this), _minUsdcOut);
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
    * @notice Allows the user to withdraw their USDC balance.
    * @param _usdcAmount Amount of USDC (in 6 decimals) the user wishes to withdraw.
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

        IERC20(USDC_ADDRESS).safeTransfer(msg.sender, _usdcAmount);
        totalWithdrawals++;

        emit WithdrawalSuccessful(msg.sender, _usdcAmount);
    }

    // ====================================================================
    // SWAP FUNCTIONS
    // ====================================================================

    /**
     * @notice Performs the swap of any token (or WETH if _tokenIn is WETH) to USDC.
     * This function encapsulates the core trading logic using the standard Uniswap V2 function: 
     * `swapExactTokensForTokens`.
     * @param _tokenIn Address of the ERC20 token in the contract.
     * @param _amountIn Amount of _tokenIn to swap.
     * @param _recipient The address that receives the USDC.
     * @param _minUsdcOut The minimum amount of USDC expected, set by the user (slippage protection).
     * @return usdcReceived The amount of USDC received.
     */
    function _swapToUsdc(
        address _tokenIn,
        uint256 _amountIn,
        address _recipient,
        uint256 _minUsdcOut
    ) private returns (uint256 usdcReceived) {
        if (_amountIn == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert InvalidRecipientAddress();
        
        if (_tokenIn == USDC_ADDRESS) {
            return _amountIn; 
        }

        if (IERC20(_tokenIn).allowance(address(this), address(UNISWAP_ROUTER)) < _amountIn) {
            IERC20(_tokenIn).safeIncreaseAllowance(address(UNISWAP_ROUTER), type(uint256).max);
        }

        address[] memory path;
        if (_tokenIn == WETH_ADDRESS) {
            path = new address[](2);
            path[0] = WETH_ADDRESS;
            path[1] = USDC_ADDRESS;
        } else {
            path = new address[](3);
            path[0] = _tokenIn;
            path[1] = WETH_ADDRESS;
            path[2] = USDC_ADDRESS;
        }

        try UNISWAP_ROUTER.swapExactTokensForTokens(
            _amountIn,
            _minUsdcOut,
            path,
            _recipient,
            block.timestamp + 1
        ) returns (uint256[] memory amounts) {
            usdcReceived = amounts[amounts.length - 1];
            if (usdcReceived == 0) revert ZeroUsdcReceived();
        } catch {
            revert UniswapSwapFailed();
        }
    }
    
    // ====================================================================
    // VIEW & UTILITY FUNCTIONS
    // ====================================================================

    /**
     * @notice Retrieves the total value of the reserves in USDC (6 decimals).
     * @return The total value of the bank vault/reserves in USDC.
     */
    function getTotalBankValueUsdc() external view onlyOwner returns (uint256) {
        return IERC20(USDC_ADDRESS).balanceOf(address(this)); 
    }

    /**
    * @notice Returns the user balance in USDC (6 decimals).
    * @return The user balance.
    */
    function getUsdcBalance() external view returns (uint256) {
        return balances[msg.sender];
    }
    
    /**
    * @notice Returns the total number of deposits that have been made to the USDC balance.
    * @return The total deposit count.
    */
    function getTotalDepositsCount() public view returns (uint256) {
        return totalDeposits;
    }

    /**
    * @notice Returns the total number of withdrawals that have been made from the USDC balance.
    * @return The total withdrawal count.
    */
    function getTotalWithdrawalsCount() public view returns (uint256) {
        return totalWithdrawals;
    }

    /**
    * @notice Returns the contract's bank capacity (in 6 decimals).
    * @return The contract's bank capacity.
    */
    function getBankCap() public view returns (uint256) {
        return BANK_CAP_USDC;
    }
}
