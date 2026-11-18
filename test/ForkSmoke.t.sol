// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC4626 {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function asset() external view returns (address);
}

contract ForkSmoke is Test {
    address constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant STEAK_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"));
    }

    function testForkReadsAllThree() public {
        uint256 ta1 = IERC4626(SDAI).totalAssets();
        uint256 ts1 = IERC4626(SDAI).totalSupply();
        assertGt(ta1, 0, "sDAI totalAssets is zero");
        assertGt(ts1, 0, "sDAI totalSupply is zero");
        emit log_named_uint("sDAI totalAssets", ta1);
        emit log_named_uint("sDAI totalSupply", ts1);

        uint256 ta2 = IERC4626(SUSDE).totalAssets();
        uint256 ts2 = IERC4626(SUSDE).totalSupply();
        assertGt(ta2, 0, "sUSDe totalAssets is zero");
        emit log_named_uint("sUSDe totalAssets", ta2);
        emit log_named_uint("sUSDe totalSupply", ts2);

        uint256 ta3 = IERC4626(STEAK_USDC).totalAssets();
        uint256 ts3 = IERC4626(STEAK_USDC).totalSupply();
        assertGt(ta3, 0, "steakUSDC totalAssets is zero");
        emit log_named_uint("steakUSDC totalAssets", ta3);
        emit log_named_uint("steakUSDC totalSupply", ts3);
    }

    /// share price must be computable and non-zero on all three
    function testForkSharePrice() public {
        uint256 p1 = IERC4626(SDAI).totalAssets() * 1e18 / IERC4626(SDAI).totalSupply();
        uint256 p2 = IERC4626(SUSDE).totalAssets() * 1e18 / IERC4626(SUSDE).totalSupply();
        uint256 p3 = IERC4626(STEAK_USDC).totalAssets() * 1e18 / IERC4626(STEAK_USDC).totalSupply();
        assertGt(p1, 0);
        assertGt(p2, 0);
        assertGt(p3, 0);
        emit log_named_uint("sDAI price 1e18", p1);
        emit log_named_uint("sUSDe price 1e18", p2);
        emit log_named_uint("steakUSDC price 1e18", p3);
    }
}
