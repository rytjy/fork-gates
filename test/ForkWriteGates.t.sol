// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20W {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IVaultW {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function previewDeposit(uint256) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function cooldownShares(uint256) external returns (uint256);
    function cooldowns(address) external view returns (uint104 cooldownEnd, uint152 underlyingAmount);
    function unstake(address) external;
    function getUnvestedAmount() external view returns (uint256);
    function cooldownDuration() external view returns (uint256);
    function silo() external view returns (address);
    function feeRecipient() external view returns (address);
}

/// Fork write-path gates.
/// Everything here is grounded in the verified sources:
/// - StakedUSDeV2 disables ERC4626 redeem/withdraw while cooldown is on (ensureCooldownOff),
///   so the exit path is cooldownShares -> silo -> unstake.
/// - MetaMorpho mints fee shares inside accrueInterest, so totalSupply deltas on deposit
///   include curator fees and cannot be compared to the caller's shares alone.
contract ForkWriteGates is Test {
    uint256 constant FORK_BLOCK = 26441482;

    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant STEAK = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address actor = address(0xA11CE);
    address victim = address(0xB0B);
    address attacker = address(0xBAD);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"), FORK_BLOCK);
    }

    function _fund(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
        assertEq(IERC20W(token).balanceOf(to), amount, "deal did not take");
        vm.prank(to);
        IERC20W(token).approve(token == USDE ? SUSDE : STEAK, type(uint256).max);
    }

    /// W1: a real deposit mints exactly previewDeposit shares and moves totalAssets by assets
    function testW1SusdeDepositAccounting() public {
        uint256 amount = 1000e18;
        _fund(USDE, actor, amount);

        uint256 shares0 = IVaultW(SUSDE).balanceOf(actor);
        uint256 ts0 = IVaultW(SUSDE).totalSupply();
        uint256 ta0 = IVaultW(SUSDE).totalAssets();
        uint256 expected = IVaultW(SUSDE).previewDeposit(amount);

        vm.prank(actor);
        uint256 shares = IVaultW(SUSDE).deposit(amount, actor);

        emit log_named_uint("expected shares", expected);
        emit log_named_uint("minted shares", shares);
        assertEq(shares, expected, "deposit minted != previewDeposit");
        assertEq(IVaultW(SUSDE).balanceOf(actor) - shares0, shares, "share balance delta");
        assertEq(IVaultW(SUSDE).totalSupply() - ts0, shares, "totalSupply delta");
        assertEq(IVaultW(SUSDE).totalAssets() - ta0, amount, "totalAssets delta != assets");

        uint256 held = IERC20W(USDE).balanceOf(SUSDE);
        uint256 unvested = IVaultW(SUSDE).getUnvestedAmount();
        assertEq(IVaultW(SUSDE).totalAssets() + unvested, held, "post-deposit backing identity broken");
    }

    /// W2: the cooldown exit path — cooldownShares parks assets in the silo, unstake returns them
    function testW2SusdeCooldownExit() public {
        uint256 amount = 1000e18;
        _fund(USDE, actor, amount);
        vm.prank(actor);
        uint256 shares = IVaultW(SUSDE).deposit(amount, actor);

        address silo = IVaultW(SUSDE).silo();
        uint256 siloBefore = IERC20W(USDE).balanceOf(silo);

        vm.prank(actor);
        uint256 assets = IVaultW(SUSDE).cooldownShares(shares);

        (, uint152 pending) = IVaultW(SUSDE).cooldowns(actor);
        emit log_named_uint("cooldown assets", assets);
        emit log_named_uint("recorded underlying", pending);
        emit log_named_uint("silo delta", IERC20W(USDE).balanceOf(silo) - siloBefore);
        emit log_named_uint("actor usde during cooldown", IERC20W(USDE).balanceOf(actor));

        assertEq(IVaultW(SUSDE).balanceOf(actor), 0, "shares not burned");
        assertEq(uint256(pending), assets, "cooldown record != assets");
        assertEq(IERC20W(USDE).balanceOf(silo) - siloBefore, assets, "assets did not land in silo");
        assertEq(IERC20W(USDE).balanceOf(actor), 0, "assets released before cooldown ended");
        assertLe(assets, amount, "cooldown returned more than deposited");

        vm.warp(block.timestamp + IVaultW(SUSDE).cooldownDuration() + 1);
        vm.prank(actor);
        IVaultW(SUSDE).unstake(actor);

        uint256 back = IERC20W(USDE).balanceOf(actor);
        emit log_named_uint("actor usde after unstake", back);
        assertLe(back, amount, "round trip profited");
        assertGe(back, amount - 2, "round trip lost more than 2 wei");
    }

    /// W3: share transfers must not change totalSupply or totalAssets
    function testW3ShareTransferIsNeutral() public {
        uint256 amount = 1000e18;
        _fund(USDE, actor, amount);
        vm.prank(actor);
        uint256 shares = IVaultW(SUSDE).deposit(amount, actor);

        uint256 ts0 = IVaultW(SUSDE).totalSupply();
        uint256 ta0 = IVaultW(SUSDE).totalAssets();

        vm.prank(actor);
        IERC20W(SUSDE).transfer(victim, shares);

        assertEq(IVaultW(SUSDE).totalSupply(), ts0, "transfer changed totalSupply");
        assertEq(IVaultW(SUSDE).totalAssets(), ta0, "transfer changed totalAssets");
        assertEq(IVaultW(SUSDE).balanceOf(victim), shares, "receiver balance wrong");
    }

    /// W4: deposit then redeem on the live MetaMorpho vault must not profit.
    /// totalSupply delta = caller shares + fee shares minted by accrueInterest.
    function testW4SteakDepositRedeem() public {
        uint256 amount = 100e6;
        uint256 cap = IVaultW(STEAK).maxDeposit(actor);
        emit log_named_uint("maxDeposit", cap);
        assertGe(cap, amount, "vault at supply cap, cannot test write path");

        _fund(USDC, actor, amount);
        address feeTo = IVaultW(STEAK).feeRecipient();
        uint256 ts0 = IVaultW(STEAK).totalSupply();
        uint256 ta0 = IVaultW(STEAK).totalAssets();
        uint256 fee0 = IVaultW(STEAK).balanceOf(feeTo);
        uint256 expected = IVaultW(STEAK).previewDeposit(amount);

        vm.prank(actor);
        uint256 shares = IVaultW(STEAK).deposit(amount, actor);

        uint256 supplyDelta = IVaultW(STEAK).totalSupply() - ts0;
        uint256 feeDelta = IVaultW(STEAK).balanceOf(feeTo) - fee0;
        emit log_named_uint("shares", shares);
        emit log_named_uint("supply delta", supplyDelta);
        emit log_named_uint("fee shares minted", feeDelta);

        assertEq(shares, expected, "steak deposit minted != preview");
        assertEq(supplyDelta, shares + feeDelta, "supply delta != shares + fee shares");
        assertEq(IVaultW(STEAK).totalAssets() - ta0, amount, "steak totalAssets delta");

        vm.prank(actor);
        uint256 out = IVaultW(STEAK).redeem(shares, actor, actor);
        emit log_named_uint("redeem out", out);
        assertLe(out, amount, "steak round trip profited");
        assertGe(out, amount - 2, "steak round trip lost more than 2 units");
        assertEq(IERC20W(USDC).balanceOf(actor), out, "actor usdc mismatch");
    }

    /// W5: a donation to the vault must not let the donator profit from a later depositor
    function testW5DonationAttackDoesNotProfit() public {
        uint256 seed = 2;
        uint256 donation = 50_000e6;

        _fund(USDC, attacker, seed + donation);
        vm.prank(attacker);
        uint256 attackShares = IVaultW(STEAK).deposit(seed, attacker);
        assertGt(attackShares, 0, "seed deposit minted no shares");

        vm.prank(attacker);
        IERC20W(USDC).transfer(STEAK, donation);

        uint256 victimAmount = 100e6;
        _fund(USDC, victim, victimAmount);
        vm.prank(victim);
        uint256 victimShares = IVaultW(STEAK).deposit(victimAmount, victim);
        assertGt(victimShares, 0, "victim deposit minted no shares");

        vm.prank(attacker);
        uint256 attackerOut = IVaultW(STEAK).redeem(attackShares, attacker, attacker);
        vm.prank(victim);
        uint256 victimOut = IVaultW(STEAK).redeem(victimShares, victim, victim);

        emit log_named_uint("attacker in", seed + donation);
        emit log_named_uint("attacker out", attackerOut);
        emit log_named_uint("victim in", victimAmount);
        emit log_named_uint("victim out", victimOut);

        assertLe(attackerOut, seed + donation, "donation attack profited");
        assertGe(victimOut, victimAmount - 2, "victim lost value to the donation");
    }
}

