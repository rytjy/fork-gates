// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20B {
    function balanceOf(address) external view returns (uint256);
}

interface IERC4626B {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function convertToShares(uint256) external view returns (uint256);
    function previewDeposit(uint256) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
}

interface IVesting {
    function getUnvestedAmount() external view returns (uint256);
}

interface IACL {
    function owner() external view returns (address);
    function curator() external view returns (address);
    function guardian() external view returns (address);
    function fee() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function isAllocator(address) external view returns (bool);
    function setCurator(address) external;
    function setFee(uint256) external;
    function setFeeRecipient(address) external;
    function setIsAllocator(address, bool) external;
    function submitTimelock(uint256) external;
    function revokePendingTimelock() external;
    function submitGuardian(address) external;
    function setSupplyQueue(bytes32[] calldata) external;
    function updateWithdrawQueue(uint256[] calldata) external;
}

/// Errors declared by the deployed contract (from its verified ABI).
interface IErrs {
    error OwnableUnauthorizedAccount(address);
    error NotGuardianRole();
    error NotAllocatorRole();
    error AlreadySet();
    error InvalidMarketRemovalNonZeroCap(bytes32);
}

/// Fork-layer gates.
/// C-2: sUSDe share accounting on real state.
/// Auth: steakUSDC access control on real state, asserting the SPECIFIC error selector.
/// Exact-selector matching is deliberate: an earlier draft asserted "any revert", which
/// silently passed on two entry points whose selectors did not exist on this contract.
contract ForkGates is Test {
    uint256 constant FORK_BLOCK = 26441482;

    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant STEAK = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    address constant STEAK_OWNER = 0x0A0e559bc3b0950a7e448F0d4894db195b9cf8DD;
    address constant STEAK_CURATOR = 0x827e86072B06674a077f592A531dcE4590aDeCdB;
    address constant STEAK_GUARDIAN = 0xaa0500198B4425DfC4E272FbE42C8E64E21fc03d;
    address constant NOBODY = address(0xBAD);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"), FORK_BLOCK);
    }

    function _sel(address who, bytes memory data) internal returns (bool ok, bytes4 sel) {
        vm.prank(who);
        bytes memory ret;
        (ok, ret) = STEAK.call(data);
        if (!ok && ret.length >= 4) {
            assembly { sel := mload(add(ret, 0x20)) }
        }
    }

    function _expectDenied(address who, bytes memory data, bytes4 expected, string memory label) internal {
        (bool ok, bytes4 sel) = _sel(who, data);
        emit log_named_bytes(label, abi.encodePacked(sel));
        assertFalse(ok, string.concat(label, ": call was allowed"));
        assertEq(sel, expected, string.concat(label, ": unexpected error"));
    }

    // ---------------- C-2: sUSDe accounting ----------------

    /// F1: held == totalAssets + unvested. Ethena defines totalAssets() = balance - getUnvestedAmount().
    function testF1TotalAssetsIsBacked() public {
        address a = IERC4626B(SUSDE).asset();
        uint256 held = IERC20B(a).balanceOf(SUSDE);
        uint256 reported = IERC4626B(SUSDE).totalAssets();
        uint256 unvested = IVesting(SUSDE).getUnvestedAmount();
        emit log_named_uint("held", held);
        emit log_named_uint("reported", reported);
        emit log_named_uint("unvested", unvested);
        assertEq(reported + unvested, held, "C-2: held != totalAssets + unvested");
        assertLe(unvested, held / 100, "C-2: unvested rewards exceed 1% of holdings");
    }

    /// F2: an immediate deposit->redeem round trip must never profit
    function testF2RoundTripNoProfit() public {
        uint256[5] memory xs = [uint256(1), 1e6, 1e12, 1e18, 1e21];
        for (uint256 i = 0; i < 5; i++) {
            uint256 shares = IERC4626B(SUSDE).previewDeposit(xs[i]);
            uint256 back = IERC4626B(SUSDE).previewRedeem(shares);
            emit log_named_uint("in", xs[i]);
            emit log_named_uint("out", back);
            assertLe(back, xs[i], "C-2: round trip returned more than put in");
        }
    }

    /// F3: redeeming the entire supply must not claim more than totalAssets
    function testF3FullRedeemNotOverPromised() public {
        uint256 ts = IERC4626B(SUSDE).totalSupply();
        uint256 ta = IERC4626B(SUSDE).totalAssets();
        uint256 claim = IERC4626B(SUSDE).previewRedeem(ts);
        emit log_named_uint("totalSupply", ts);
        emit log_named_uint("claim", claim);
        assertLe(claim, ta, "C-2: full supply redeem exceeds totalAssets");
    }

    /// F4: share price stays inside a sane band (no silent redenomination)
    function testF4SharePriceBand() public {
        uint256 p = IERC4626B(SUSDE).convertToAssets(1e18);
        emit log_named_uint("sUSDe price 1e18", p);
        assertGe(p, 1e18, "C-2: share worth less than 1 asset");
        assertLe(p, 10e18, "C-2: share price above 10x band");
    }

    /// F5: converting all assets back to shares must not mint more than supply
    function testF5InversionRounding() public {
        uint256 ta = IERC4626B(SUSDE).totalAssets();
        uint256 ts = IERC4626B(SUSDE).totalSupply();
        uint256 sharesBack = IERC4626B(SUSDE).convertToShares(ta);
        emit log_named_uint("sharesBack", sharesBack);
        emit log_named_uint("totalSupply", ts);
        assertLe(sharesBack, ts, "C-2: converting all assets mints more than supply");
    }

    // ---------------- Auth: steakUSDC ----------------

    /// A1: unprivileged caller hits the exact ACL error on every owner-only entry
    function testA1NobodyDeniedOnOwnerSurface() public {
        IACL v = IACL(STEAK);
        bytes4 own = IErrs.OwnableUnauthorizedAccount.selector;
        _expectDenied(NOBODY, abi.encodeWithSelector(v.setCurator.selector, NOBODY), own, "nobody:setCurator");
        _expectDenied(NOBODY, abi.encodeWithSelector(v.setFee.selector, uint256(1)), own, "nobody:setFee");
        _expectDenied(NOBODY, abi.encodeWithSelector(v.setFeeRecipient.selector, NOBODY), own, "nobody:setFeeRecipient");
        _expectDenied(NOBODY, abi.encodeWithSelector(v.setIsAllocator.selector, NOBODY, true), own, "nobody:setIsAllocator");
        _expectDenied(NOBODY, abi.encodeWithSelector(v.submitGuardian.selector, NOBODY), own, "nobody:submitGuardian");
        _expectDenied(NOBODY, abi.encodeWithSelector(v.submitTimelock.selector, uint256(0)), own, "nobody:submitTimelock");
    }

    /// A2: the allocator surface rejects guardian and unprivileged callers
    function testA2AllocatorSurfaceDenied() public {
        IACL v = IACL(STEAK);
        bytes4 notAlloc = IErrs.NotAllocatorRole.selector;
        _expectDenied(NOBODY, abi.encodeWithSelector(v.setSupplyQueue.selector, new bytes32[](0)), notAlloc, "nobody:setSupplyQueue");
        _expectDenied(STEAK_GUARDIAN, abi.encodeWithSelector(v.setSupplyQueue.selector, new bytes32[](0)), notAlloc, "guardian:setSupplyQueue");
        _expectDenied(NOBODY, abi.encodeWithSelector(v.updateWithdrawQueue.selector, new uint256[](0)), notAlloc, "nobody:updateWithdrawQueue");
        _expectDenied(STEAK_GUARDIAN, abi.encodeWithSelector(v.updateWithdrawQueue.selector, new uint256[](0)), notAlloc, "guardian:updateWithdrawQueue");
    }

    /// A3: doctor the guardian-only surface — guardian passes, curator and nobody do not
    function testA3GuardianSurfaceIsExclusive() public {
        IACL v = IACL(STEAK);
        bytes4 notGuardian = IErrs.NotGuardianRole.selector;
        _expectDenied(STEAK_CURATOR, abi.encodeWithSelector(v.revokePendingTimelock.selector), notGuardian, "curator:revokePendingTimelock");
        _expectDenied(NOBODY, abi.encodeWithSelector(v.revokePendingTimelock.selector), notGuardian, "nobody:revokePendingTimelock");

        vm.prank(STEAK_GUARDIAN);
        (bool ok,) = STEAK.call(abi.encodeWithSelector(v.revokePendingTimelock.selector));
        assertTrue(ok, "guardian was denied on its own surface");
    }

    /// A4: the owner passes every role check (error becomes AlreadySet, reachable only after auth)
    function testA4OwnerPassesRoleChecks() public {
        IACL v = IACL(STEAK);
        assertEq(v.owner(), STEAK_OWNER, "owner moved");
        assertEq(v.curator(), STEAK_CURATOR, "curator moved");
        assertEq(v.guardian(), STEAK_GUARDIAN, "guardian moved");
        assertFalse(v.isAllocator(NOBODY), "arbitrary address is allocator");

        bytes4 set = IErrs.AlreadySet.selector;
        _expectDenied(STEAK_OWNER, abi.encodeWithSelector(v.setFeeRecipient.selector, v.feeRecipient()), set, "owner:setFeeRecipient(same)");
        _expectDenied(STEAK_OWNER, abi.encodeWithSelector(v.setCurator.selector, STEAK_CURATOR), set, "owner:setCurator(same)");
        _expectDenied(STEAK_OWNER, abi.encodeWithSelector(v.submitGuardian.selector, STEAK_GUARDIAN), set, "owner:submitGuardian(same)");
        _expectDenied(STEAK_OWNER, abi.encodeWithSelector(v.setFee.selector, v.fee()), set, "owner:setFee(same)");
    }

    /// A5: the curator passes auth on the allocator surface but is stopped by validation,
    /// proving the curator (not just allocators) reaches that code path
    function testA5CuratorReachesAllocatorSurface() public {
        IACL v = IACL(STEAK);
        (bool ok, bytes4 sel) = _sel(STEAK_CURATOR, abi.encodeWithSelector(v.updateWithdrawQueue.selector, new uint256[](0)));
        emit log_named_bytes("curator:updateWithdrawQueue", abi.encodePacked(sel));
        assertFalse(ok, "curator emptied the withdraw queue");
        assertEq(sel, IErrs.InvalidMarketRemovalNonZeroCap.selector, "curator stopped by ACL, not validation");
    }
}

