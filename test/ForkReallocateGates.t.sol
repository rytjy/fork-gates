// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MarketAllocation {
    MarketParams marketParams;
    uint256 assets;
}

interface IMorphoB {
    function idToMarketParams(bytes32) external view returns (MarketParams memory);
    function position(bytes32, address) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32) external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
    function accrueInterest(MarketParams memory) external;
}

interface IVaultR {
    function MORPHO() external view returns (address);
    function withdrawQueue(uint256) external view returns (bytes32);
    function withdrawQueueLength() external view returns (uint256);
    function supplyQueueLength() external view returns (uint256);
    function config(bytes32) external view returns (uint184 cap, bool enabled, uint64 removableAt);
    function totalAssets() external view returns (uint256);
    function curator() external view returns (address);
    function owner() external view returns (address);
    function isAllocator(address) external view returns (bool);
    function reallocate(MarketAllocation[] calldata) external;
}

interface IErrsR {
    error NotAllocatorRole();
    error InconsistentReallocation();
    error MarketNotEnabled(bytes32);
    error SupplyCapExceeded(bytes32);
}

/// Fork reallocate gates: the only path that changes real market positions.
/// Accounting hypothesis taken from the verified source: totalAssets() == sum over
/// withdrawQueue of MORPHO.expectedSupplyAssets(vault); idle balance is NOT counted.
contract ForkReallocateGates is Test {
    uint256 constant FORK_BLOCK = 26441482;
    address constant STEAK = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address constant NOBODY = address(0xBAD);
    uint256 constant MOVE = 1000e6;

    IVaultR vault;
    IMorphoB morpho;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"), FORK_BLOCK);
        vault = IVaultR(STEAK);
        morpho = IMorphoB(vault.MORPHO());
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets_, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * totalAssets_ + totalShares - 1) / totalShares;
    }

    function _accrueAll() internal returns (uint256 n) {
        n = vault.withdrawQueueLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = vault.withdrawQueue(i);
            morpho.accrueInterest(morpho.idToMarketParams(id));
        }
    }

    function _toAssetsDown(uint256 shares, uint256 totalAssets_, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * totalAssets_) / totalShares;
    }

    function _posAssets(bytes32 id) internal view returns (uint256) {
        (uint256 shares,,) = morpho.position(id, STEAK);
        (uint128 ta, uint128 ts,,,,) = morpho.market(id);
        return _toAssetsUp(shares, ta, ts);
    }

    /// R1: the reallocate path is closed to unprivileged callers
    function testR1ReallocateDeniedToNobody() public {
        MarketAllocation[] memory allocs = new MarketAllocation[](0);
        vm.prank(NOBODY);
        (bool ok, bytes memory ret) = STEAK.call(abi.encodeWithSelector(vault.reallocate.selector, allocs));
        assertFalse(ok, "nobody reallocate succeeded");
        bytes4 sel;
        if (ret.length >= 4) assembly { sel := mload(add(ret, 0x20)) }
        emit log_named_bytes("nobody reallocate error", abi.encodePacked(sel));
        assertEq(sel, IErrsR.NotAllocatorRole.selector, "wrong denial reason");
    }

    /// R2: totalAssets must equal the sum of the vault's positions in its withdraw queue.
    /// Markets are accrued first so the comparison is at a single timestamp.
    function testR2TotalAssetsEqualsMarketPositions() public {
        uint256 n = _accrueAll();
        uint256 sumUp;
        uint256 sumDown;
        for (uint256 i; i < n; ++i) {
            bytes32 id = vault.withdrawQueue(i);
            (uint256 shares,,) = morpho.position(id, STEAK);
            (uint128 ta, uint128 ts,,,,) = morpho.market(id);
            sumUp += _toAssetsUp(shares, ta, ts);
            sumDown += _toAssetsDown(shares, ta, ts);
        }
        uint256 reported = vault.totalAssets();
        uint256 idle = IERC20B2(STEAK).balanceOf(STEAK);
        emit log_named_uint("queue length", n);
        emit log_named_uint("sum rounded up", sumUp);
        emit log_named_uint("sum rounded down", sumDown);
        emit log_named_uint("reported totalAssets", reported);
        emit log_named_uint("idle asset balance", idle);
        emit log_named_int("reported - sumUp", int256(reported) - int256(sumUp));
        emit log_named_int("reported - sumDown", int256(reported) - int256(sumDown));
        // hypothesis under test: the vault values positions with floor rounding
        assertEq(reported, sumDown, "totalAssets != sum of positions (floor)");
        // and idle balances are not part of totalAssets
        assertEq(reported, sumDown, "idle was counted");
    }

    /// R3: a real reallocation moves MOVE between two markets and changes nothing else
    function testR3ReallocateMovesAssetsBetweenMarkets() public {
        uint256 n = _accrueAll();
        assertGt(n, 1, "need at least two markets");

        // A = the market where the vault holds the most; B = first enabled market with cap headroom
        uint256 bestIdx;
        uint256 bestPos;
        for (uint256 i; i < n; ++i) {
            uint256 p = _posAssets(vault.withdrawQueue(i));
            if (p > bestPos) {
                bestPos = p;
                bestIdx = i;
            }
        }
        assertGt(bestPos, MOVE, "largest position too small to move");

        uint256 bIdx = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            if (i == bestIdx) continue;
            bytes32 id = vault.withdrawQueue(i);
            (uint184 cap, bool enabled,) = vault.config(id);
            uint256 p = _posAssets(id);
            if (enabled && cap > p && uint256(cap) - p >= MOVE) {
                bIdx = i;
                break;
            }
        }
        assertTrue(bIdx != type(uint256).max, "no market with cap headroom");

        bytes32 idA = vault.withdrawQueue(bestIdx);
        bytes32 idB = vault.withdrawQueue(bIdx);
        uint256 posABefore = _posAssets(idA);
        uint256 posBBefore = _posAssets(idB);
        uint256 totalBefore = vault.totalAssets();

        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({marketParams: morpho.idToMarketParams(idA), assets: posABefore - MOVE});
        allocs[1] = MarketAllocation({marketParams: morpho.idToMarketParams(idB), assets: type(uint256).max});

        vm.prank(vault.curator());
        vault.reallocate(allocs);

        uint256 posAAfter = _posAssets(idA);
        uint256 posBAfter = _posAssets(idB);
        uint256 totalAfter = vault.totalAssets();

        emit log_named_uint("posA before", posABefore);
        emit log_named_uint("posA after", posAAfter);
        emit log_named_uint("posB before", posBBefore);
        emit log_named_uint("posB after", posBAfter);
        emit log_named_uint("total before", totalBefore);
        emit log_named_uint("total after", totalAfter);

        assertApproxEqAbs(posABefore - posAAfter, MOVE, 2, "withdraw from A not equal to MOVE");
        assertApproxEqAbs(posBAfter - posBBefore, MOVE, 2, "supply to B not equal to MOVE");
        assertApproxEqAbs(totalAfter, totalBefore, 2, "reallocation changed totalAssets");
    }

    /// R4: a reallocation whose withdraw and supply amounts differ must be rejected
    function testR4InconsistentReallocationReverts() public {
        uint256 n = _accrueAll();
        uint256 bestIdx;
        uint256 bestPos;
        for (uint256 i; i < n; ++i) {
            uint256 p = _posAssets(vault.withdrawQueue(i));
            if (p > bestPos) {
                bestPos = p;
                bestIdx = i;
            }
        }
        bytes32 idA = vault.withdrawQueue(bestIdx);
        uint256 bIdx;
        for (uint256 i; i < n; ++i) {
            if (i != bestIdx) {
                bIdx = i;
                break;
            }
        }

        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({marketParams: morpho.idToMarketParams(idA), assets: bestPos - MOVE});
        allocs[1] = MarketAllocation({marketParams: morpho.idToMarketParams(vault.withdrawQueue(bIdx)), assets: 1});

        vm.prank(vault.curator());
        (bool ok, bytes memory ret) = STEAK.call(abi.encodeWithSelector(vault.reallocate.selector, allocs));
        assertFalse(ok, "inconsistent reallocation was accepted");
        bytes4 sel;
        if (ret.length >= 4) assembly { sel := mload(add(ret, 0x20)) }
        emit log_named_bytes("inconsistent error", abi.encodePacked(sel));
        assertEq(sel, IErrsR.InconsistentReallocation.selector, "wrong rejection reason");
    }
}

interface IERC20B2 {
    function balanceOf(address) external view returns (uint256);
}

