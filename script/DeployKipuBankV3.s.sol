// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {
        
    address internal immutable UNISWAP_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; 
    address internal immutable USDC_ADDRESS = 0x96152E6180E085FA57c7708e18AF8F05e37B479D; 

    uint256 internal constant BANK_CAP_USD = 1000;
    
    function run() external returns (KipuBankV3) {
        uint256 _bankCapUsdScaled = BANK_CAP_USD * 10**6;

        vm.startBroadcast();
        KipuBankV3 kipuBankV3 = new KipuBankV3(
            UNISWAP_ROUTER,
            USDC_ADDRESS,
            _bankCapUsdScaled
        );
        vm.stopBroadcast();
        
        console.log("-----------------------------------------");
        console.log("KipuBankV3 Deployed!");
        console.log("Network: Sepolia");
        console.log("Router:", UNISWAP_ROUTER);
        console.log("USDC Address:", USDC_ADDRESS);
        console.log("Smart contract address:", address(kipuBankV3));
        console.log("-----------------------------------------");

        return kipuBankV3;
    }
}
