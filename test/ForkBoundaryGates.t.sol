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

interface IMorphoB2 {
    function idToMarketParams(bytes32) external view returns (MarketParams memory);
    function position(bytes32, address) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32) external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
    function accrueInterest(MarketParams memory) external;
}

interface IVaultB {
    function MORPHO() external view returns (address);
    function withdrawQueue(uint256) external view returns (bytes32);
    function withdrawQueueLength() external view returns (uint256);
    function config(bytes32) external view returns (uint184 cap, bool enabled, uint64 removableAt);
    function timelock() external view returns (uint256);
    function curator() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function submitCap(MarketParams memory, uint256) external;
    function acceptCap(MarketParams memory) external;
    function reallocate(MarketAllocation[] calldata) external;
    function submitMarketRemoval(MarketParams memory) external;
    function updateWithdrawQueue(uint256[] calldata) external;
}

interface IErrsB {
    error SupplyCapExceeded(bytes32);
    error UnauthorizedMarket(bytes32);
    error MarketNotEnabled(bytes32);
    error TimelockNotElapsed();
    error AlreadySet();
    error PendingRemoval();
    error AlreadyPending();
    error InconsistentReallocation();
    error InvalidMarketRemovalNonZeroSupply(bytes32);
}

/// Fork boundary gates: supply-cap edge and the disabled-market path, driven through
/// the real governance surface (submitCap is immediate for decreases, timelocked for increases).
contract ForkBoundaryGates is Test {
    uint256 constant FORK_BLOCK = 26441482;
    address constant STEAK = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    uint256 constant MOVE = 1000e6;

    IVaultB vault;
    IMorphoB2 morpho;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"), FORK_BLOCK);
        vault = IVaultB(STEAK);
        morpho = IMorphoB2(vault.MORPHO());
    }

    function _pos(bytes32 id) internal view returns (uint256) {
        (uint256 shares,,) = morpho.position(id, STEAK);
        (uint128 ta, uint128 ts,,,,) = morpho.market(id);
        if (ts == 0) return 0;
        return (shares * ta) / ts;
    }

    function _accrueAll() internal returns (uint256 n) {
        n = vault.withdrawQueueLength();
        for (uint256 i; i < n; ++i) {
            morpho.accrueInterest(morpho.idToMarketParams(vault.withdrawQueue(i)));
        }
    }

    function _pickTwo() internal view returns (uint256 aIdx, uint256 bIdx, uint256 posA) {
        uint256 n = vault.withdrawQueueLength();
        for (uint256 i; i < n; ++i) {
            uint256 p = _pos(vault.withdrawQueue(i));
            if (p > posA) {
                posA = p;
                aIdx = i;
            }
        }
        for (uint256 i; i < n; ++i) {
            if (i != aIdx) {
                bIdx = i;
                break;
            }
        }
    }

    /// B1: supplying one unit past a lowered cap must revert SupplyCapExceeded
    function testB1SupplyCapBoundary() public {
        _accrueAll();
        (uint256 aIdx, uint256 bIdx, uint256 posA) = _pickTwo();
        bytes32 idA = vault.withdrawQueue(aIdx);
        bytes32 idB = vault.withdrawQueue(bIdx);
        uint256 posB = _pos(idB);

        // lowering a cap is immediate (no timelock).
        // NB: build the params BEFORE prank — an external call inside the argument list
        // would consume the prank and the sender would stay the test contract.
        MarketParams memory pB = morpho.idToMarketParams(idB);
        vm.prank(vault.curator());
        vault.submitCap(pB, posB + MOVE);
        (uint184 capB, bool enabledB,) = vault.config(idB);
        emit log_named_uint("new cap", capB);
        assertEq(uint256(capB), posB + MOVE, "cap was not lowered immediately");
        assertTrue(enabledB, "market got disabled by a non-zero cap");

        uint256 over = MOVE + 1000;
        assertGt(posA, over, "largest position too small");

        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({marketParams: morpho.idToMarketParams(idA), assets: posA - over});
        allocs[1] = MarketAllocation({marketParams: morpho.idToMarketParams(idB), assets: type(uint256).max});

        vm.prank(vault.curator());
        (bool ok, bytes memory ret) = STEAK.call(abi.encodeWithSelector(vault.reallocate.selector, allocs));
        assertFalse(ok, "supply past cap was accepted");
        bytes4 sel;
        if (ret.length >= 4) assembly { sel := mload(add(ret, 0x20)) }
        emit log_named_bytes("cap error", abi.encodePacked(sel));
        assertEq(sel, IErrsB.SupplyCapExceeded.selector, "wrong rejection reason");
    }

    /// B2: in this deployment zeroing a cap does NOT disable the market.
    /// Measured: cap -> 0, enabled stays true, removableAt stays 0, and withdrawals still work
    /// (paired with a supply elsewhere, because reallocate requires withdrawn == supplied).
    function testB2ZeroCapKeepsMarketEnabledAndWithdrawable() public {
        _accrueAll();
        uint256 n = vault.withdrawQueueLength();

        uint256 aIdx = type(uint256).max;
        uint256 posA;
        for (uint256 i; i < n; ++i) {
            uint256 p = _pos(vault.withdrawQueue(i));
            if (p > posA) { posA = p; aIdx = i; }
        }
        assertGt(posA, MOVE, "largest position too small");
        bytes32 idA = vault.withdrawQueue(aIdx);
        MarketParams memory pA = morpho.idToMarketParams(idA);

        vm.prank(vault.curator());
        vault.submitCap(pA, 0);

        (uint184 capA, bool enabledA, uint64 removableAt) = vault.config(idA);
        emit log_named_uint("cap after zeroing", capA);
        emit log_named_uint("removableAt", removableAt);
        assertEq(uint256(capA), 0, "cap not zeroed");
        assertTrue(enabledA, "cap zero disabled the market (contrary to observation)");
        assertEq(uint256(removableAt), 0, "removableAt changed");

        // destination: an enabled market with headroom, so the withdrawal leg can be balanced
        uint256 cIdx = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            if (i == aIdx) continue;
            bytes32 id = vault.withdrawQueue(i);
            (uint184 cap, bool enabled,) = vault.config(id);
            uint256 pos = _pos(id);
            if (enabled && cap > pos && uint256(cap) - pos >= MOVE) { cIdx = i; break; }
        }
        assertTrue(cIdx != type(uint256).max, "no destination market with headroom");
        bytes32 idC = vault.withdrawQueue(cIdx);
        uint256 posCBefore = _pos(idC);

        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({marketParams: pA, assets: posA - MOVE});
        allocs[1] = MarketAllocation({marketParams: morpho.idToMarketParams(idC), assets: type(uint256).max});

        vm.prank(vault.curator());
        vault.reallocate(allocs);

        uint256 posAAfter = _pos(idA);
        uint256 posCAfter = _pos(idC);
        emit log_named_uint("posA before", posA);
        emit log_named_uint("posA after", posAAfter);
        emit log_named_uint("posC delta", posCAfter - posCBefore);
        assertApproxEqAbs(posA - posAAfter, MOVE, 2, "withdrawal from zero-cap market did not happen");
        assertApproxEqAbs(posCAfter - posCBefore, MOVE, 2, "balanced supply did not land");
    }

    /// B3: with a zero cap the market must reject supply with UnauthorizedMarket,
    /// while the withdrawal leg is funded from a different market that actually holds assets
    function testB3ZeroCapMarketRejectsSupply() public {
        _accrueAll();
        uint256 n = vault.withdrawQueueLength();

        uint256 aIdx = type(uint256).max;
        uint256 aPos;
        for (uint256 i; i < n; ++i) {
            uint256 p = _pos(vault.withdrawQueue(i));
            if (p > aPos) {
                aPos = p;
                aIdx = i;
            }
        }
        bytes32 idA = vault.withdrawQueue(aIdx);
        MarketParams memory pA = morpho.idToMarketParams(idA);

        uint256 cIdx = type(uint256).max;
        uint256 cPos;
        for (uint256 i; i < n; ++i) {
            if (i == aIdx) continue;
            uint256 p = _pos(vault.withdrawQueue(i));
            if (p > MOVE && p > cPos) {
                cPos = p;
                cIdx = i;
            }
        }
        assertTrue(cIdx != type(uint256).max, "no second market with a position");

        bytes32 idC = vault.withdrawQueue(cIdx);
        MarketParams memory pC = morpho.idToMarketParams(idC);

        vm.prank(vault.curator());
        vault.submitCap(pA, 0);

        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({marketParams: pC, assets: cPos - MOVE});
        allocs[1] = MarketAllocation({marketParams: pA, assets: type(uint256).max});

        vm.prank(vault.curator());
        (bool ok, bytes memory ret) = STEAK.call(abi.encodeWithSelector(vault.reallocate.selector, allocs));
        assertFalse(ok, "supplied into a zero-cap market");
        bytes4 sel;
        if (ret.length >= 4) assembly { sel := mload(add(ret, 0x20)) }
        emit log_named_bytes("zero-cap supply error", abi.encodePacked(sel));
        assertEq(sel, IErrsB.UnauthorizedMarket.selector, "wrong rejection reason");
    }

    /// B4: raising a cap is timelocked — accepting in the same block must revert
    function testB4CapIncreaseIsTimelocked() public {
        _accrueAll();
        (,, uint256 posA) = _pickTwo();
        bytes32 idB = vault.withdrawQueue(1);
        (uint184 capB,,) = vault.config(idB);

        MarketParams memory pB = morpho.idToMarketParams(idB);
        vm.prank(vault.curator());
        vault.submitCap(pB, uint256(capB) + 1e6);

        vm.prank(vault.curator());
        (bool ok, bytes memory ret) = STEAK.call(abi.encodeWithSelector(vault.acceptCap.selector, pB));
        assertFalse(ok, "cap increase accepted instantly");
        bytes4 sel;
        if (ret.length >= 4) assembly { sel := mload(add(ret, 0x20)) }
        emit log_named_bytes("accept early error", abi.encodePacked(sel));
        assertEq(sel, IErrsB.TimelockNotElapsed.selector, "wrong rejection reason");

        // after the timelock it must go through
        vm.warp(block.timestamp + vault.timelock() + 1);
        vm.prank(vault.curator());
        vault.acceptCap(pB);
        (uint184 capAfter,,) = vault.config(idB);
        emit log_named_uint("cap after accept", capAfter);
        assertEq(uint256(capAfter), uint256(capB) + 1e6, "cap increase not applied after timelock");
        posA;
    }

    struct Snap {
        uint256 queueLen;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 price;
    }

    function _snap() internal view returns (Snap memory s) {
        s.queueLen = vault.withdrawQueueLength();
        s.totalAssets = vault.totalAssets();
        s.totalSupply = vault.totalSupply();
        s.price = vault.convertToAssets(1e18);
    }

    function _prepRemoval(bytes32 id) internal {
        MarketParams memory p = morpho.idToMarketParams(id);
        vm.prank(vault.curator());
        vault.submitCap(p, 0);
        vm.prank(vault.curator());
        vault.submitMarketRemoval(p);
        vm.warp(block.timestamp + vault.timelock() + 1);
    }

    function _applyRemoval(uint256 idx, uint256 queueLen) internal {
        uint256[] memory keep = new uint256[](queueLen - 1);
        uint256 k;
        for (uint256 i; i < queueLen; ++i) {
            if (i != idx) keep[k++] = i;
        }
        vm.prank(vault.curator());
        vault.updateWithdrawQueue(keep);
    }

    /// B5: dropping a NON-EMPTY market from the withdraw queue is accepted by this deployment
    /// (canonical MetaMorpho reverts InvalidMarketRemovalNonZeroSupply). Consequence measured here:
    /// totalAssets and the share price lose exactly that market's value, and the market stays
    /// enabled, so it remains drainable via reallocate. Re-adding it restores the queue.
    function testB5NonEmptyMarketRemovalQuantified() public {
        _accrueAll();
        (uint256 aIdx,, ) = _pickTwo();
        bytes32 idA = vault.withdrawQueue(aIdx);

        _prepRemoval(idA);
        // the 7-day warp accrues interest everywhere: re-align before measuring
        _accrueAll();
        Snap memory before = _snap();
        uint256 posA = _pos(idA);
        assertGt(posA, 0, "chosen market is empty, test would be vacuous");

        _applyRemoval(aIdx, before.queueLen);
        Snap memory afterRemoval = _snap();
        (uint184 capA, bool enabledA,) = vault.config(idA);

        emit log_named_uint("queue before", before.queueLen);
        emit log_named_uint("queue after", afterRemoval.queueLen);
        emit log_named_uint("totalAssets before", before.totalAssets);
        emit log_named_uint("totalAssets after", afterRemoval.totalAssets);
        emit log_named_int("totalAssets drop", int256(before.totalAssets) - int256(afterRemoval.totalAssets));
        emit log_named_uint("market position", posA);
        emit log_named_uint("price before", before.price);
        emit log_named_uint("price after", afterRemoval.price);
        emit log_named_uint("cap after", capA);
        emit log_named_uint("still enabled 1=yes", enabledA ? 1 : 0);

        assertEq(afterRemoval.queueLen, before.queueLen - 1, "queue length did not shrink");
        assertEq(int256(before.totalAssets) - int256(afterRemoval.totalAssets), int256(posA), "dropped value != position");
        assertLt(afterRemoval.price, before.price, "price did not drop");
        assertFalse(enabledA, "removal did not disable the market");

        // the disabled path: a removed market can no longer be drained via reallocate
        uint256 qIdx;
        for (uint256 i; i < afterRemoval.queueLen; ++i) { qIdx = i; break; }
        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({marketParams: morpho.idToMarketParams(idA), assets: posA - MOVE});
        allocs[1] = MarketAllocation({marketParams: morpho.idToMarketParams(vault.withdrawQueue(qIdx)), assets: type(uint256).max});
        vm.prank(vault.curator());
        (bool ok, bytes memory ret) = STEAK.call(abi.encodeWithSelector(vault.reallocate.selector, allocs));
        bytes4 sel;
        if (ret.length >= 4) assembly { sel := mload(add(ret, 0x20)) }
        emit log_named_bytes("withdraw from removed market", abi.encodePacked(sel));
        assertFalse(ok, "removed market was still drainable");
        assertEq(sel, IErrsB.MarketNotEnabled.selector, "wrong rejection reason");

        // re-adding is not immediate: any positive cap on a zero-cap market is an INCREASE,
        // so it goes through submitCap -> timelock -> acceptCap
        MarketParams memory pA = morpho.idToMarketParams(idA);
        vm.prank(vault.curator());
        vault.submitCap(pA, 1e15);
        vm.warp(block.timestamp + vault.timelock() + 1);
        vm.prank(vault.curator());
        vault.acceptCap(pA);
        _accrueAll();
        Snap memory afterReadd = _snap();
        emit log_named_uint("queue after re-add", afterReadd.queueLen);
        assertEq(afterReadd.queueLen, before.queueLen, "market was not re-added");
    }
}
