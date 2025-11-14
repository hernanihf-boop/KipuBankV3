// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol"; 
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

using SafeERC20 for IERC20;

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
        
        _allowances[from][msg.sender] = currentAllowance - amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        
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
    
    function WETH() external pure returns (address) { return address(MOCK_WETH_ADDRESS); } 
    function factory() external pure returns (address) { return address(0); }
    
    // --- Mocks for WETH Wrapping (ETH deposit) ---
    function deposit() external payable {
        // Mints WETH to the depositor (KipuBankV3)
        MockERC20(MOCK_WETH_ADDRESS).mint(msg.sender, msg.value);
    }

    // --- Mocks for ETH swaps (ETH -> WETH -> USDC) ---
    /**
     * @notice Logic for swapExactETHForTokens.
     */
    function swapExactETHForTokens(
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external payable returns (uint256[] memory) {
        require(path.length == 2, "Invalid ETH->USDC path length in mock");
        require(path[0] == MOCK_WETH_ADDRESS && path[1] == USDC_ADDRESS, "Invalid ETH->USDC path in mock");

        uint256 ethAmount = msg.value;
        // 1 ETH (18 dec) * 2000 (rate) / 10^12 = USDC (6 dec)
        uint256 usdcReceived = ethAmount * ETH_USDC_RATE / (10 ** 12); 

        MockERC20(USDC_ADDRESS).mint(to, usdcReceived);

        uint256[] memory amounts = new uint256[](path.length);
        amounts[0] = ethAmount; 
        amounts[path.length - 1] = usdcReceived;
        return amounts;
    }

    // --- Mocks for ERC20 swaps (WETH -> USDC, DAI -> WETH -> USDC, etc.) ---
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256 
    ) external returns (uint256[] memory) {
        
        require(path.length >= 2 && path[path.length - 1] == USDC_ADDRESS, "Invalid Path (Must end in USDC)");
        
        address tokenIn = path[0];
        uint256 usdcReceived;

        if (tokenIn == MOCK_WETH_ADDRESS) {
            // WETH -> USDC path (2 hops)
            require(path.length == 2, "Invalid WETH->USDC path length");
            // Rate: 1 WETH = 2000 USDC (WETH 18 dec, USDC 6 dec)
            usdcReceived = amountIn * ETH_USDC_RATE / (10 ** 12); 
            
        } else if (tokenIn == DAI_ADDRESS) { 
             // DAI -> WETH -> USDC path (3 hops)
             require(path.length == 3 && path[1] == MOCK_WETH_ADDRESS, "Invalid DAI->WETH->USDC path");
             // Rate: 1 DAI (18 dec) = 1 USDC (6 dec)
             usdcReceived = amountIn / (10 ** 12); 
        } else {
             revert("Unrecognized input token in the mock"); 
        }

        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(USDC_ADDRESS).mint(to, usdcReceived); 

        uint256[] memory amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = usdcReceived;
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

    uint256 public constant BANK_CAP_USD = 10_000;
    uint256 public constant BANK_CAP_USDC_DEC = BANK_CAP_USD * 1e6;
    uint256 public constant ETH_RATE = 2000;
    
    uint256 public constant USER1_ID = uint256(uint160(address(0xAA)));

    function setUp() public {
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        vm.label(address(weth), "MOCK_WETH");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        vm.label(address(dai), "DAI_MOCK"); 
        
        MockUniswapV2Router mockRouter = new MockUniswapV2Router(address(weth), address(usdc), address(dai));
        routerAddress = address(mockRouter);
        
        owner = address(this); 
        bank = new KipuBankV3(routerAddress, address(weth), address(usdc), BANK_CAP_USD);

        vm.deal(user1, 10 ether); 

        dai.mint(user1, 100 ether); 
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
        assertEq(bank.WETH_ADDRESS(), address(weth), "WETH address mismatch"); 
        assertEq(bank.getBankCap(), BANK_CAP_USDC_DEC, "Bank capacity mismatch");
    }

    function test_Constructor_RevertOnZeroCap() public {
        vm.expectRevert(KipuBankV3.InvalidBankCapValue.selector);
        new KipuBankV3(routerAddress, address(weth), address(usdc), 0);
    }
    
    // ====================================================================
    // DEPOSIT TESTS (Native ETH) - Covers 'receive' and 'depositNativeToken'
    // ====================================================================

    function test_DepositNativeToken_Success() public {
        uint256 ethAmount = 1 ether;
        uint256 expectedUsdc = ethAmount * ETH_RATE / (10 ** 12); 

        vm.prank(user1);
        
        vm.expectEmit(true, true, false, false, address(usdc)); 
        emit IERC20.Transfer(address(0), address(bank), expectedUsdc);

        vm.expectEmit(true, true, false, false, address(bank)); 
        emit KipuBankV3.DepositSwapped(user1, address(0), ethAmount, expectedUsdc);
        
        bank.depositNativeToken{value: ethAmount}(USER1_ID);

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
        bank.depositNativeToken{value: 0}(USER1_ID);
    }
    
    function test_DepositNativeToken_Revert_CapExceeded() public {
        uint256 initialBankBalanceUsdc = usdc.balanceOf(address(bank)); // Should be 0 initially
        
        vm.prank(user1);
        uint256 ethAmount = 6 ether; // 6 ETH = 12,000 USDC. Cap is 10,000 USDC.
        uint256 expectedUsdc = ethAmount * ETH_RATE / (10 ** 12); // 12,000 USDC

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.BankCapExceeded.selector, 
                initialBankBalanceUsdc + expectedUsdc, 
                expectedUsdc, 
                BANK_CAP_USDC_DEC
            )
        );
        bank.depositNativeToken{value: ethAmount}(USER1_ID);
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
        
        vm.expectEmit(true, true, false, false, address(usdc)); 
        emit IERC20.Transfer(user1, address(bank), usdcAmount); 
        
        vm.expectEmit(true, true, false, false, address(bank)); 
        emit KipuBankV3.DepositSwapped(user1, address(usdc), usdcAmount, usdcAmount); 

        bank.depositToken(address(usdc), usdcAmount, USER1_ID);

        assertEq(usdc.balanceOf(address(bank)), usdcAmount, "Bank did not receive the USDC");
        
        vm.prank(user1); 
        assertEq(bank.getUsdcBalance(), usdcAmount, "Incorrect user balance (USDC)");
    }
    
    function test_DepositToken_DAI_Success() public {
        uint256 daiAmount = 100 ether; 
        uint256 expectedUsdc = 100 * 1e6;

        vm.prank(user1);
        
        vm.expectEmit(true, true, false, false, address(dai)); 
        emit IERC20.Transfer(user1, address(bank), daiAmount); 
        
        vm.expectEmit(true, true, false, false, address(dai)); 
        emit IERC20.Transfer(address(bank), routerAddress, daiAmount);

        vm.expectEmit(true, true, false, false, address(usdc)); 
        emit IERC20.Transfer(address(0), address(bank), expectedUsdc);

        vm.expectEmit(true, true, false, false, address(bank)); 
        emit KipuBankV3.DepositSwapped(user1, address(dai), daiAmount, expectedUsdc);

        bank.depositToken(address(dai), daiAmount, USER1_ID);

        assertEq(dai.balanceOf(address(bank)), 0, "Bank should NOT hold DAI (it should be swapped)"); 
        
        vm.prank(user1); 
        assertEq(bank.getUsdcBalance(), expectedUsdc, "Incorrect user balance after DAI swap");
    }
    
    // ====================================================================
    // WITHDRAW TESTS
    // ====================================================================

    function test_Withdraw_Success() public {
        vm.prank(user1);
        bank.depositNativeToken{value: 1 ether}(USER1_ID); // Deposit 1 ETH = 2000 USDC.
        
        uint256 initialUserUsdcBalance = usdc.balanceOf(user1);
        uint256 withdrawAmount = 500 * 1e6; // 500 USDC

        vm.prank(user1);

        vm.expectEmit(true, true, false, false, address(usdc)); 
        emit IERC20.Transfer(address(bank), user1, withdrawAmount);

        vm.expectEmit(true, false, false, false, address(bank));
        emit KipuBankV3.WithdrawalSuccessful(user1, withdrawAmount);

        bank.withdraw(withdrawAmount);

        vm.prank(user1); 
        assertEq(bank.getUsdcBalance(), 1500 * 1e6, "User balance should be 1500 USDC"); // User balance should be 1500 USDC
        
        assertEq(usdc.balanceOf(user1), initialUserUsdcBalance + withdrawAmount, "USDC not transferred to user"); // USDC not transferred to user
        
        vm.prank(owner);
        assertEq(bank.getTotalBankValueUsdc(), 1500 * 1e6, "Total bank value should decrease"); // Total bank value should decrease
    }

    function test_Withdraw_Revert_InsufficientFunds() public {
        vm.prank(user1);
        bank.depositNativeToken{value: 0.05 ether}(USER1_ID); // Deposit a LOW amount (0.05 ETH = 100 USDC)
        
        vm.prank(user1);
        uint256 available = 100 * 1e6;
        uint256 requested = 101 * 1e6; // Request 101 USDC. This is < Limit (1000 USDC) but > Balance (100 USDC).
        
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
        vm.prank(user1);
        bank.depositNativeToken{value: 1 ether}(USER1_ID); // Setup: user1 deposits 1 ETH = 2000 USDC

        vm.prank(user1);
        uint256 requested = 10001 * 1e6; // Request 10001 USDC
        
        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.WithdrawalLimitExceeded.selector, 
                bank.MAX_WITHDRAWAL_USDC(), // Fetch the contract's actual limit (10000 * 1e6)
                requested
            )
        ) ;
        bank.withdraw(requested);
    }

    // ====================================================================
    // VIEW AND UTILITY TESTS
    // ====================================================================
    
    function test_UtilityViews_BeforeStateChange() public view {
        assertEq(bank.getTotalDepositsCount(), 0);
        assertEq(bank.getTotalWithdrawalsCount(), 0);
    }

    function test_UtilityViews_WithStateChange() public {
        vm.prank(user1);
        bank.depositNativeToken{value: 1 ether}(USER1_ID); // Setup: user1 deposits 1 ETH = 2000 USDC

        vm.prank(user1);
        bank.withdraw(500 * 1e6); // Withdrawal

        // Counter and view checks
        assertEq(bank.getTotalDepositsCount(), 1, "Total Deposits count mismatch");
        assertEq(bank.getTotalWithdrawalsCount(), 1, "Total Withdrawals count mismatch");
        
        vm.prank(owner); // getTotalBankValueUsdc is onlyOwner
        assertEq(bank.getTotalBankValueUsdc(), 1500 * 1e6, "Total bank value is not 1500 USDC");
    }
}
