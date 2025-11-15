// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; 

using SafeERC20 for IERC20;

// ====================================================================
// TEST SUITE: KipuBankV3 (FORKING SEPOLIA)
// ====================================================================

contract KipuBankV3Test is Test {
    KipuBankV3 public bank;

    address internal constant ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3; 
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; 
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; 
    address internal constant USDT = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;

    address internal constant USDT_WHALE = 0xc94b1BEe63A3e101FE5F71C80F912b4F4b055925;

    uint256 public constant BANK_CAP_USD = 1_000_000;
    uint256 public constant BANK_CAP_USDC_DEC = BANK_CAP_USD * 1e6;
    uint256 public constant MAX_WITHDRAWAL_USDC = 10000 * 1e6; 


    address public owner;
    address public user1 = address(0xAA);
    address public user2 = address(0xBB);

    IERC20 internal usdc;
    IERC20 internal usdt;
    IERC20 internal weth;

    function setUp() public {
        string memory rpcUrl = vm.envString("SEPOLIA_RPC_URL");
        vm.createSelectFork(rpcUrl);

        usdc = IERC20(USDC);
        usdt = IERC20(USDT);
        weth = IERC20(WETH);

        vm.deal(user1, 35 ether); 
        vm.deal(user2, 35 ether);
        vm.deal(USDT_WHALE, 1 ether);

        // Inject USDT to the whale
        deal(address(usdt), USDT_WHALE, 10000 ether); 

        owner = address(this);
        bank = new KipuBankV3(
            ROUTER,
            WETH,
            USDC,
            BANK_CAP_USD
        );

        uint256 tokenToGive = 1000 * 1e6;
        deal(address(usdc), user1, tokenToGive);
        
        uint256 usdtToGive = 1000 ether;
        deal(address(usdt), user1, usdtToGive);
        
        vm.startPrank(user1);
        usdt.approve(address(bank), type(uint256).max);
        usdc.approve(address(bank), type(uint256).max);
        vm.stopPrank();
    }

    // ====================================================================
    // CONSTRUCTOR TESTS
    // ====================================================================

    function testConstructorSuccess() public view {
        assertEq(address(bank.UNISWAP_ROUTER()), ROUTER, "Router address mismatch");
        assertEq(bank.USDC_ADDRESS(), USDC, "USDC address mismatch");
        assertEq(bank.WETH_ADDRESS(), WETH, "WETH address mismatch");
        assertEq(bank.getBankCap(), BANK_CAP_USDC_DEC, "Bank capacity mismatch");
    }

    // ====================================================================
    // DEPOSIT TESTS (Native ETH)
    // ====================================================================

    function testDepositNativeTokenSuccess() public {
        uint256 ethAmount = 0.1 ether; 

        uint256 initialBankUsdc = usdc.balanceOf(address(bank));

        vm.prank(user1);
        bank.depositNativeToken{value: ethAmount}(1);

        uint256 finalBankUsdc = usdc.balanceOf(address(bank));
        uint256 usdcReceived = finalBankUsdc - initialBankUsdc;

        assertTrue(usdcReceived > 0, "No USDC received from the real swap");
        
        vm.prank(user1); 
        assertEq(bank.getUsdcBalance(), usdcReceived, "Incorrect user USDC balance");
        assertEq(bank.getTotalDepositsCount(), 1, "Total Deposits count should be 1");
    }

    // ====================================================================
    // DEPOSIT TESTS (ERC20)
    // ====================================================================

    function testDepositTokenUSDCSuccess() public {
        uint256 usdcAmount = 500 * 1e6;

        vm.startPrank(user1);

        uint256 initialBankUsdc = usdc.balanceOf(address(bank));

        bank.depositToken(address(usdc), usdcAmount, 0);

        assertEq(usdc.balanceOf(address(bank)), initialBankUsdc + usdcAmount, "Bank did not receive the USDC");
        assertEq(bank.getUsdcBalance(), usdcAmount, "Incorrect user balance (USDC)");
        vm.stopPrank();
    }

    function testDepositTokenUSDTSuccess() public {
        uint256 usdtAmount = 100 ether;

        vm.startPrank(user1);
        uint256 initialBankUsdc = usdc.balanceOf(address(bank));

        bank.depositToken(address(usdt), usdtAmount, 1); 

        uint256 finalBankUsdc = usdc.balanceOf(address(bank));
        uint256 usdcReceived = finalBankUsdc - initialBankUsdc;

        assertTrue(usdcReceived > 0, "No USDC received from the real swap (USDT)");
        assertEq(bank.getUsdcBalance(), usdcReceived, "Incorrect user balance after USDT swap");
        vm.stopPrank();
    }

    function testDepositTokenRevertNoApproval() public {
        uint256 usdtAmount = 10 ether; 
        address unapprovedUser = user2;

        vm.startPrank(USDT_WHALE);
        usdt.transfer(unapprovedUser, usdtAmount); 
        vm.stopPrank();

        vm.startPrank(unapprovedUser);
        vm.expectRevert("ERC20: transfer amount exceeds allowance"); 
        bank.depositToken(USDT, 1 ether, 1);
        vm.stopPrank();
    }

    // ====================================================================
    // WITHDRAW TESTS
    // ====================================================================

    function testWithdrawSuccess() public {
        uint256 usdcDeposit = 500 * 1e6; 
        
        uint256 initialBankUsdcBalance = usdc.balanceOf(address(bank));

        vm.startPrank(user1); 

        bank.depositToken(address(usdc), usdcDeposit, 0); 
        
        assertEq(usdc.balanceOf(address(bank)), initialBankUsdcBalance + usdcDeposit, "Bank did not receive the USDC deposit.");

        uint256 userBalanceBefore = bank.getUsdcBalance();
        assertTrue(userBalanceBefore > 0, "User internal balance should be greater than zero after deposit.");

        uint256 withdrawAmount = userBalanceBefore / 2;
        if (withdrawAmount == 0) {
            withdrawAmount = 1;
        }

        uint256 initialUserUsdcBalance = usdc.balanceOf(user1);

        bank.withdraw(withdrawAmount);

        assertApproxEqAbs(bank.getUsdcBalance(), userBalanceBefore - withdrawAmount, 1, "User balance should decrease");
        assertApproxEqAbs(usdc.balanceOf(user1), initialUserUsdcBalance + withdrawAmount, 1, "USDC not transferred to user");
        
        vm.stopPrank(); 
    }

    function testWithdrawRevertInsufficientFunds() public {
        uint256 usdcDeposit = 500 * 1e6; 
        vm.prank(user1);
        bank.depositToken(address(usdc), usdcDeposit, 0); 
        
        address userWithZeroBalance = user2;
        uint256 available = 0; 
        uint256 requested = 500 * 1e6 + 1;

        vm.prank(userWithZeroBalance);
        vm.expectRevert(abi.encodeWithSelector(
            KipuBankV3.InsufficientFunds.selector,
            available,
            requested
        ));
        bank.withdraw(requested);
    }

    // ====================================================================
    // VIEW AND UTILITY TESTS
    // ====================================================================

    function testUtilityViewsWithStateChange() public {
        vm.prank(user1);
        bank.depositNativeToken{value: 0.1 ether}(1);

        vm.prank(user1);
        uint256 initialUsdcBalance = bank.getUsdcBalance();

        vm.prank(user1);
        uint256 withdrawAmount = 1 * 1e6; 
        if (initialUsdcBalance >= withdrawAmount) {
             bank.withdraw(withdrawAmount);
        }

        assertEq(bank.getTotalDepositsCount(), 1, "Total Deposits count mismatch");
        assertEq(bank.getTotalWithdrawalsCount(), initialUsdcBalance >= withdrawAmount ? 1 : 0, "Total Withdrawals count mismatch");

        vm.prank(owner); 
        assertEq(bank.getTotalBankValueUsdc(), usdc.balanceOf(address(bank)), "Total bank value mismatch");
    }
}
