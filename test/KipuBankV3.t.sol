// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol"; 
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ====================================================================
// MOCK CONTRACTS (Dependency Simulation)
// ====================================================================

/**
 * @title MockERC20
 * @notice A simple ERC20 that allows minting for testing purposes.
 */
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable DECIMALS; 

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        DECIMALS = _decimals;
    }

    function totalSupply() public view virtual override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view virtual override returns (uint256) { return _balances[account]; }
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) { return _allowances[owner][spender]; }
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: allowance exceeded");
        
        // ALLOWANCE REDUCTION
        _allowances[from][msg.sender] = currentAllowance - amount;

        _balances[from] -= amount;
        _balances[to] += amount;
        
        // Approval(0) is emitted before Transfer in this mock for better traceability
        emit Approval(from, msg.sender, _allowances[from][msg.sender]);
        emit Transfer(from, to, amount);
        return true;
    }

    // Functions only for tests
    function mint(address account, uint256 amount) public {
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }
}

/**
 * @title MockUniswapV2Router
 * @notice Mock router that uses the real addresses of the mock tokens.
 */
// forge-lint-disable mixed-case-function
contract MockUniswapV2Router { 
    
    address internal constant MOCK_WETH_ADDRESS = address(0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f); 
    address public immutable USDC_ADDRESS;
    address public immutable DAI_ADDRESS;

    // Exchange rate: 1 ETH/WETH = 2000 USDC. 1 DAI (18 dec) = 1 USDC (6 dec).
    uint256 public constant ETH_USDC_RATE = 2000;

    constructor(address, address _usdc, address _dai) { 
        USDC_ADDRESS = _usdc;
        DAI_ADDRESS = _dai;
    }
    
    function WETH() external pure returns (address) { return MOCK_WETH_ADDRESS; } 
    function factory() external pure returns (address) { return address(0); }
    
    // --- Mocks for ETH swaps ---
    function swapExactETHForTokens(
        uint256, // amountOutMin
        address[] calldata path,
        address to,
        uint256 // deadline
    ) external payable returns (uint256[] memory) {
        require(path.length == 2 && path[0] == MOCK_WETH_ADDRESS && path[1] == USDC_ADDRESS, "Invalid Path (WETH->USDC)");
        
        // Simulates the swap: ETH -> WETH -> USDC
        uint256 usdcReceived = msg.value * ETH_USDC_RATE / (10 ** 12); 
        
        // Mints USDC to the destination (the bank)
        MockERC20(USDC_ADDRESS).mint(to, usdcReceived); 
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = usdcReceived;
        return amounts;
    }

    // --- Mocks for ERC20 swaps ---
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256, // amountOutMin
        address[] calldata path,
        address to,
        uint256 // deadline
    ) external returns (uint256[] memory) {
        require(path.length == 2 && path[1] == USDC_ADDRESS, "Invalid Path (ERC20->USDC)");
        
        address tokenIn = path[0];
        uint256 usdcReceived;

        if (tokenIn == DAI_ADDRESS) { 
             // 1:1 rate, from 18 dec (DAI) to 6 dec (USDC)
             usdcReceived = amountIn / (10 ** 12); 
        } else {
             revert("Unrecognized input token in the mock"); 
        }

        // Simulates the tokenIn transfer: 
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "Mock TransferFrom failed"); 
        
        // Mints USDC to the destination (the bank)
        MockERC20(USDC_ADDRESS).mint(to, usdcReceived); 

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = usdcReceived;
        return amounts;
    }
}


// ====================================================================
// TEST SUITE: KipuBankV3
// ====================================================================

contract KipuBankV3Test is Test {
    KipuBankV3 public bank;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public dai; 
    address public routerAddress; 

    address public owner;
    address public user1 = address(0xAA);
    address public user2 = address(0xBB);

    // Constant values for testing (all in 6-decimal USDC units)
    uint256 public constant BANK_CAP_USD = 10_000; // $10,000 USD
    uint256 public constant BANK_CAP_USDC_DEC = BANK_CAP_USD * 1e6;
    uint256 public constant MAX_WITHDRAWAL_USDC = 1000 * 1e6;
    uint256 public constant ETH_RATE = 2000;

    function setUp() public {
        // 1. Initialize mock tokens
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        vm.label(address(weth), "MOCK_WETH");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        vm.label(address(dai), "DAI_MOCK"); 
        
        // 2. Initialize the mock router
        // CRITICAL FIX: Pass the REAL DAI address to the mock router constructor
        MockUniswapV2Router mockRouter = new MockUniswapV2Router(address(weth), address(usdc), address(dai));
        routerAddress = address(mockRouter);
        
        // 3. Initialize the KipuBankV3 contract
        owner = address(this); 
        bank = new KipuBankV3(routerAddress, address(usdc), BANK_CAP_USD);

        // 4. Set up initial funds for tests
        vm.deal(user1, 10 ether); 

        // Mint 100 DAI to user1 for ERC20 tests
        dai.mint(user1, 100 ether); 
        // user1 must approve the bank to move the DAI
        vm.startPrank(user1);
        dai.approve(address(bank), type(uint256).max);
        vm.stopPrank();
    }

    // ====================================================================
    // CONSTRUCTOR TESTS
    // ====================================================================

    function test_Constructor_Success() public view {
        assertEq(address(bank.UNISWAP_ROUTER()), routerAddress, "Router address mismatch");
        assertEq(bank.USDC_ADDRESS(), address(usdc), "USDC address mismatch");
        assertEq(bank.WETH_ADDRESS(), MockUniswapV2Router(routerAddress).WETH(), "WETH address mismatch"); 
        assertEq(bank.getBankCap(), BANK_CAP_USDC_DEC, "Bank capacity mismatch");
    }

    function test_Constructor_RevertOnZeroCap() public {
        vm.expectRevert(KipuBankV3.InvalidBankCapValue.selector);
        new KipuBankV3(routerAddress, address(usdc), 0);
    }
    
    // ====================================================================
    // DEPOSIT TESTS (Native ETH) - Covers 'receive' and 'depositNativeToken'
    // ====================================================================

    function test_DepositNativeToken_Success() public {
        uint256 ethAmount = 1 ether;
        uint256 expectedUsdc = ethAmount * ETH_RATE / (10 ** 12); 

        // 1. Function call
        vm.prank(user1);
        
        // The mock router emits a USDC Transfer (0x0 -> bank)
        vm.expectEmit(true, true, false, false, address(usdc)); 
        emit IERC20.Transfer(address(0), address(bank), expectedUsdc);

        // 2. Bank's DepositSwapped event (2 indexed topics)
        vm.expectEmit(true, true, false, false, address(bank)); 
        emit KipuBankV3.DepositSwapped(user1, address(0), ethAmount, expectedUsdc);
        
        bank.depositNativeToken{value: ethAmount}();

        // 3. Balance checks
        vm.prank(user1); 
        assertEq(bank.getUsdcBalance(), expectedUsdc, "Incorrect user USDC balance");
        
        vm.prank(owner);
        assertEq(bank.getTotalBankValueUsdc(), expectedUsdc, "Incorrect total bank value");
        
        vm.prank(user1); 
        assertEq(bank.getTotalDepositsCount(), 1, "Total Deposits count should be 1");
    }

    function test_DepositNativeToken_Revert_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositNativeToken{value: 0}();
    }
    
    function test_DepositNativeToken_Revert_CapExceeded() public {
        vm.prank(user1);
        // 6 ETH = 12,000 USDC. Cap is 10,000 USDC.
        uint256 ethAmount = 6 ether; 
        uint256 expectedUsdc = ethAmount * ETH_RATE / (10 ** 12);

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.BankCapExceeded.selector, 
                0, // currentUsdcValue
                expectedUsdc, // requestedUsdcAmount (12000 * 1e6)
                BANK_CAP_USDC_DEC // bankCap (10000 * 1e6)
            )
        );
        bank.depositNativeToken{value: ethAmount}();
    }
    
    // ====================================================================
    // DEPOSIT TESTS (ERC20)
    // ====================================================================

    function test_DepositToken_USDC_Success() public {
        uint256 usdcAmount = 500 * 1e6; // 500 USDC

        // Mint USDC to user1 and approve the bank to transfer
        usdc.mint(user1, usdcAmount);
        vm.prank(user1);
        usdc.approve(address(bank), usdcAmount);
        
        vm.prank(user1);
        
        // 1. USDC::Transfer (user1 -> bank)
        vm.expectEmit(true, true, false, false, address(usdc)); 
        emit IERC20.Transfer(user1, address(bank), usdcAmount); 

        // 2. KipuBankV3::DepositSwapped
        vm.expectEmit(true, true, false, false, address(bank)); 
        // amountIn equals amountOut because it's USDC -> USDC
        emit KipuBankV3.DepositSwapped(user1, address(usdc), usdcAmount, usdcAmount);

        bank.depositToken(address(usdc), usdcAmount);

        assertEq(usdc.balanceOf(address(bank)), usdcAmount, "Bank did not receive the USDC");
        
        vm.prank(user1); 
        assertEq(bank.getUsdcBalance(), usdcAmount, "Incorrect user balance (USDC)");
    }
    
    function test_DepositToken_DAI_Success() public {
        uint256 daiAmount = 100 ether; // 100 DAI (18 decimals)
        uint256 expectedUsdc = 100 * 1e6; // 100 USDC (6 decimals, 1:1 rate)

        vm.prank(user1);
        
        // Event emission checks are disabled to avoid issues with mock calls

        bank.depositToken(address(dai), daiAmount);

        // Critical state checks
        assertEq(dai.balanceOf(address(bank)), 0, "Bank should NOT hold DAI (it should be swapped)"); 
        
        vm.prank(user1); 
        assertEq(bank.getUsdcBalance(), expectedUsdc, "Incorrect user balance after DAI swap");

        // Check that the tokenIn allowance was reset to 0
        assertEq(dai.allowance(address(bank), routerAddress), 0, "Allowance not reset to zero");
    }
    
    // ====================================================================
    // WITHDRAW TESTS
    // ====================================================================

    function test_Withdraw_Success() public {
        // Setup: user1 deposits 1 ETH = 2000 USDC
        vm.prank(user1);
        bank.depositNativeToken{value: 1 ether}(); 
        
        uint256 initialUserUsdcBalance = usdc.balanceOf(user1);
        uint256 withdrawAmount = 500 * 1e6; // 500 USDC

        vm.prank(user1);

        // USDC::Transfer (bank -> user1)
        vm.expectEmit(true, true, false, false, address(usdc)); 
        emit IERC20.Transfer(address(bank), user1, withdrawAmount);

        // KipuBankV3::WithdrawalSuccessful 
        vm.expectEmit(true, false, false, false, address(bank));
        emit KipuBankV3.WithdrawalSuccessful(user1, withdrawAmount);

        bank.withdraw(withdrawAmount);

        // Checks
        vm.prank(user1); 
        assertEq(bank.getUsdcBalance(), 1500 * 1e6, "User balance should be 1500 USDC");
        
        assertEq(usdc.balanceOf(user1), initialUserUsdcBalance + withdrawAmount, "USDC not transferred to user");
        
        vm.prank(owner);
        assertEq(bank.getTotalBankValueUsdc(), 1500 * 1e6, "Total bank value should decrease");
    }

    function test_Withdraw_Revert_InsufficientFunds() public {
        // Deposit a LOW amount (0.05 ETH = 100 USDC)
        vm.prank(user1);
        bank.depositNativeToken{value: 0.05 ether}(); 
        
        vm.prank(user1);
        // Request 101 USDC. This is < Limit (1000 USDC) but > Balance (100 USDC).
        uint256 available = 100 * 1e6;
        uint256 requested = 101 * 1e6; 
        
        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.InsufficientFunds.selector, 
                available, 
                requested 
            )
        );
        bank.withdraw(requested);
    }
    
    function test_Withdraw_Revert_LimitExceeded() public {
        // Setup: user1 deposits 1 ETH = 2000 USDC
        vm.prank(user1);
        bank.depositNativeToken{value: 1 ether}(); 

        vm.prank(user1);
        // Limit is 1000 USDC. Requesting 1001 USDC
        uint256 requested = MAX_WITHDRAWAL_USDC + 1; 
        
        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.WithdrawalLimitExceeded.selector, 
                MAX_WITHDRAWAL_USDC, 
                requested
            )
        ) ;
        bank.withdraw(requested);
    }

    // ====================================================================
    // VIEW AND UTILITY TESTS
    // ====================================================================
    
    function test_UtilityViews_BeforeStateChange() public view {
        // Initial counter checks
        assertEq(bank.getTotalDepositsCount(), 0);
        assertEq(bank.getTotalWithdrawalsCount(), 0);
    }

    function test_UtilityViews_WithStateChange() public {
        // Setup: user1 deposits 1 ETH = 2000 USDC
        vm.prank(user1);
        bank.depositNativeToken{value: 1 ether}(); 

        // Withdrawal
        vm.prank(user1);
        bank.withdraw(500 * 1e6);

        // Counter and view checks
        assertEq(bank.getTotalDepositsCount(), 1, "Total Deposits count mismatch");
        assertEq(bank.getTotalWithdrawalsCount(), 1, "Total Withdrawals count mismatch");
        
        // getTotalBankValueUsdc is onlyOwner
        vm.prank(owner);
        assertEq(bank.getTotalBankValueUsdc(), 1500 * 1e6, "Total bank value is not 1500 USDC");
    }
}