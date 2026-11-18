// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Settlement pool with two switchable order defects.
/// @dev    orderBug : the denominator shrinks inside the settlement loop
///         carryBug : rounding dust is handed to the NEXT caller, not the earner
/// Compliant settlement pays every holder from a snapshot of the pot, so the
/// processing order cannot change anyone's entitlement.
contract MockPool {
    mapping(address => uint256) public balance;
    mapping(address => uint256) public entitlement;
    uint256 public totalDeposits;
    uint256 public pot;
    uint256 public potSnapshot;
    uint256 public dustCarry;
    bool public orderBug;
    bool public carryBug;

    function setBugs(bool o, bool c) external {
        orderBug = o;
        carryBug = c;
    }

    function deposit(uint256 amt) external {
        balance[msg.sender] += amt;
        totalDeposits += amt;
    }

    function fundPot(uint256 amt) external {
        pot += amt;
        potSnapshot += amt;
    }

    function settle(address[] memory users) public {
        uint256 denom = totalDeposits; // snapshot in the compliant path
        uint256 snapshot = potSnapshot;
        uint256 paid;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 amt = snapshot * balance[users[i]] / denom;
            entitlement[users[i]] += amt;
            paid += amt;
            if (orderBug) {
                denom -= balance[users[i]];
            }
        }
        pot = paid >= pot ? 0 : pot - paid;
    }

    function settleOne(address u) external {
        uint256 share = potSnapshot * balance[u] / totalDeposits;
        uint256 dust = (potSnapshot * balance[u]) % totalDeposits;
        uint256 payout = share;
        if (carryBug) {
            payout += dustCarry;
            dustCarry = dust;
        }
        entitlement[u] += payout;
        pot = payout >= pot ? 0 : pot - payout;
    }
}
