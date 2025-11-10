// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

// *******************************************************************
// 1. IMPORTACIONES
// *******************************************************************
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol"; // Importación oficial de Uniswap

/**
 * @title KipuBankV3
 * @author Hernán Iannello
 * @notice Smart contract which allows users to deposit ETH or any ERC20 token 
 * (supported by Uniswap V2) and automatically swaps the deposit into USDC. 
 * Balances are tracked internally in USDC.
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
     * @dev Address of the USDC stablecoin. All internal balances are denominated in USDC (6 decimals).
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
     * @dev Tracks the current total value of all reserves in USDC (6 decimals).
     */
    uint256 private currentBankValueUsdc;

    /**
     * @dev Mapping: userAddress => balance (in USDC, 6 decimals).
     * All tokens are swapped to USDC, so we simplify the balance tracking.
     */
    mapping(address => uint256) private balances;

    // Mantenemos los contadores para cumplir con la V2, aunque solo se usen con USDC.
    mapping(address => uint256) private totalDeposits;
    mapping(address => uint256) private totalWithdrawals;

    // ====================================================================
    // EVENTS
    // ====================================================================

    event DepositSwapped(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcReceived);
    event WithdrawalSuccessful(address indexed user, uint256 usdcAmount);
    
    // ====================================================================
    // CUSTOM ERRORS
    // ====================================================================

    error ZeroAmount();
    error BankCapExceeded(uint256 currentUsdcValue, uint256 requestedUsdcAmount, uint256 bankCap);
    error InvalidBankCapValue();
    error InsufficientFunds(uint256 available, uint256 requested);
    error WithdrawalLimitExceeded(uint256 limit, uint256 requested);
    error TransferFailed(address token);
    error UniswapSwapFailed();
    error ZeroUsdcReceived();
    error InvalidRouterAddress();
    error InvalidUsdcAddress();

    // ====================================================================
    // CONSTRUCTOR
    // ====================================================================

    /**
    * @dev Constructor that initializes the contract.
    * @param _router Address of the Uniswap V2 Router.
    * @param _usdc Address of the USDC token (assumed 6 decimals).
    * @param _bankCapUsd The total USDC limit the contract can handle/accept (in USD units).
    * @notice Sets the contract owner, the Uniswap Router, USDC address, and the global deposit limit.
    */
    constructor(
        address _router, 
        address _usdc, 
        uint256 _bankCapUsd
    ) Ownable(msg.sender) {
        if (_router == address(0)) revert InvalidRouterAddress();
        if (_usdc == address(0) || _usdc == NATIVE_TOKEN_ADDRESS) revert InvalidUsdcAddress();
        if (_bankCapUsd == 0) revert InvalidBankCapValue();

        UNISWAP_ROUTER = IUniswapV2Router02(_router);
        USDC_ADDRESS = _usdc;
        
        // Inicializa WETH (necesario para el ruteo)
        WETH_ADDRESS = UNISWAP_ROUTER.WETH();
        
        // BANK_CAP_USDC se convierte a 6 decimales, asumiendo que _bankCapUsd viene en unidades.
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
    * @notice Allows any user to deposit the native token (ETH) and automatically swaps it to USDC.
    */
    function depositNativeToken() public payable nonReentrant {
        uint256 amountIn = msg.value;
        address user = msg.sender;

        if (amountIn == 0) revert ZeroAmount();
        
        // 1. Swap ETH -> USDC
        // Path: ETH (via WETH) -> USDC
        address[] memory path = new address[](2);
        path[0] = WETH_ADDRESS;
        path[1] = USDC_ADDRESS;

        // Necesitamos saber cuánto USDC vamos a recibir para el chequeo del Cap
        // En este caso sí necesitamos usdcBefore porque swapExactETHForTokens NO devuelve la cantidad recibida.
        uint256 usdcBefore = IERC20(USDC_ADDRESS).balanceOf(address(this));
        
        // La transacción de swap envía ETH y recibe USDC directamente.
        try UNISWAP_ROUTER.swapExactETHForTokens{value: amountIn}(
            0, // amountOutMin: 0 for simplicity, tests should use a higher amountOutMin
            path,
            address(this), // Recibe el contrato
            block.timestamp
        ) {
            // Check if the bank has enough capacity.
            uint256 usdcReceived = IERC20(USDC_ADDRESS).balanceOf(address(this)) - usdcBefore;
            
            if (usdcReceived == 0) revert ZeroUsdcReceived();

            // Optimización: Cacheo para doble lectura de estado.
            uint256 currentUsdc = currentBankValueUsdc;
            uint256 maxCap = BANK_CAP_USDC;

            if (currentUsdc + usdcReceived > maxCap) {
                revert BankCapExceeded(currentUsdc, usdcReceived, maxCap);
            }
            
            // 2. Effects
            balances[user] += usdcReceived;
            currentBankValueUsdc = currentUsdc + usdcReceived;
            totalDeposits[USDC_ADDRESS]++; // Cuenta el depósito de ETH como un depósito de USDC

            // 3. Event
            emit DepositSwapped(user, NATIVE_TOKEN_ADDRESS, amountIn, usdcReceived);

        } catch {
            // Reembolsa el ETH si el swap falla.
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
        if (_token == NATIVE_TOKEN_ADDRESS) revert TransferFailed(NATIVE_TOKEN_ADDRESS); // Usar depositNativeToken

        address user = msg.sender;
        
        // 3. DEFINICIÓN DEL TOKEN COMO IERC20
        IERC20 tokenIn = IERC20(_token);
        
        // 1. Transferencia y Aprobación
        // Usamos la función estándar de IERC20: transferFrom
        bool successTransferFrom = tokenIn.transferFrom(user, address(this), _amount);
        if (!successTransferFrom) revert TransferFailed(_token);
        
        // Aprobación (Approve)
        // Usamos la función estándar de IERC20
        bool successApprove = tokenIn.approve(address(UNISWAP_ROUTER), _amount);
        if (!successApprove) revert TransferFailed(_token);


        // 2. Swap Token -> USDC
        address[] memory path;
        
        if (_token == USDC_ADDRESS) {
            // Si el token es USDC, no se necesita swap.
            path = new address[](0); 
        } else {
            // Path: Token In -> USDC
            path = new address[](2);
            path[0] = _token;
            path[1] = USDC_ADDRESS;
        }

        uint256 usdcReceived;
        
        if (_token == USDC_ADDRESS) {
            usdcReceived = _amount;
        } else {
            // NOTA: Se eliminó la línea 'uint256 usdcBefore = ...' 
            // porque 'swapExactTokensForTokens' devuelve directamente el monto recibido.

            // Swap
            try UNISWAP_ROUTER.swapExactTokensForTokens(
                _amount,
                0, // amountOutMin: 0 for simplicity
                path,
                address(this),
                block.timestamp
            ) returns (uint[] memory amounts) {
                // El resultado del try (amounts[amounts.length - 1]) es el USDC recibido.
                usdcReceived = amounts[amounts.length - 1]; 
                if (usdcReceived == 0) revert ZeroUsdcReceived();
                
                // Desaprobar para seguir buenas prácticas
                // Usamos la función estándar de IERC20
                bool successApproveZero = tokenIn.approve(address(UNISWAP_ROUTER), 0);
                if (!successApproveZero) revert TransferFailed(_token);
                
            } catch {
                // Si el swap falla, queda el token IN en el contrato. No se revierte al usuario.
                revert UniswapSwapFailed();
            }
        }

        // 3. Chequeo del Bank Cap
        // Optimización: Cacheo para doble lectura de estado.
        uint256 currentUsdc = currentBankValueUsdc;
        uint256 maxCap = BANK_CAP_USDC;
        
        if (currentUsdc + usdcReceived > maxCap) {
            revert BankCapExceeded(currentUsdc, usdcReceived, maxCap);
        }

        // 4. Effects
        balances[user] += usdcReceived;
        currentBankValueUsdc = currentUsdc + usdcReceived;
        totalDeposits[USDC_ADDRESS]++; // Solo contamos depósitos en el token de balance
        
        // 5. Event
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

        // 1. Chequeos (Checks)
        if (_usdcAmount > MAX_WITHDRAWAL_USDC) {
            revert WithdrawalLimitExceeded(MAX_WITHDRAWAL_USDC, _usdcAmount);
        }

        // Optimización: Cacheo de balance
        uint256 userUsdcBalance = balances[msg.sender];
        if (_usdcAmount > userUsdcBalance) {
            revert InsufficientFunds(userUsdcBalance, _usdcAmount);
        }

        // 2. Efectos (Effects)
        // Optimización: Cacheo de valor total
        uint256 currentUsdc = currentBankValueUsdc;
        
        unchecked {
            balances[msg.sender] = userUsdcBalance - _usdcAmount;
            currentBankValueUsdc = currentUsdc - _usdcAmount;
        }

        totalWithdrawals[USDC_ADDRESS]++;

        // 3. Interacción (Interaction)
        // Usamos la función estándar 'transfer' de IERC20.
        bool successTransfer = IERC20(USDC_ADDRESS).transfer(msg.sender, _usdcAmount);
        if (!successTransfer) revert TransferFailed(USDC_ADDRESS);

        // 4. Event
        emit WithdrawalSuccessful(msg.sender, _usdcAmount);
    }
    
    // ====================================================================
    // VIEW & UTILITY FUNCTIONS (Preserving V2 Functionality)
    // ====================================================================

    /**
     * @notice Retrieves the total value of the reserves in USDC (6 decimals).
     * @return The total value of the bank vault/reserves in USDC.
     */
    function getTotalBankValueUsdc() external view onlyOwner returns (uint256) {
        return currentBankValueUsdc; 
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
        return totalDeposits[USDC_ADDRESS];
    }

    /**
    * @notice Returns the total number of withdrawals that have been made from the USDC balance.
    * @return The total withdrawal count.
    */
    function getTotalWithdrawalsCount() public view returns (uint256) {
        return totalWithdrawals[USDC_ADDRESS];
    }

    /**
    * @notice Returns the contract's bank capacity (in 6 decimals).
    * @return The contract's bank capacity.
    */
    function getBankCap() public view returns (uint256) {
        return BANK_CAP_USDC;
    }
}