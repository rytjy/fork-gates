// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IACL2 {
    function owner() external view returns (address);
    function curator() external view returns (address);
    function guardian() external view returns (address);
    function fee() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function timelock() external view returns (uint256);
    function pendingTimelock() external view returns (uint256);
    function setCurator(address) external;
    function setFee(uint256) external;
    function setFeeRecipient(address) external;
    function setIsAllocator(address, bool) external;
    function submitTimelock(uint256) external;
    function acceptTimelock() external;
    function revokePendingTimelock() external;
    function submitGuardian(address) external;
    function acceptGuardian() external;
    function setSupplyQueue(bytes32[] calldata) external;
    function updateWithdrawQueue(uint256[] calldata) external;
}

contract ForkACLDiag2 is Test {
    address constant STEAK = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"), 26441482);
    }

    function _t(string memory label, address who, bytes memory data) internal {
        vm.prank(who);
        (bool ok, bytes memory ret) = STEAK.call(data);
        if (ok) {
            emit log_named_string(label, "OK");
        } else if (ret.length >= 4) {
            bytes4 sel;
            assembly { sel := mload(add(ret, 0x20)) }
            emit log_named_bytes(label, abi.encodePacked(sel));
        } else {
            emit log_named_string(label, "EMPTY_REVERT(no such selector)");
        }
    }

    function testMatrix2() public {
        IACL2 v = IACL2(STEAK);
        address[4] memory who = [v.owner(), v.curator(), v.guardian(), address(0xBAD)];
        string[4] memory tag = ["owner", "curator", "guardian", "nobody"];
        uint256 tl = v.timelock();
        uint256 f = v.fee();
        address fr = v.feeRecipient();
        address c = v.curator();
        address g = v.guardian();

        for (uint256 i = 0; i < 4; i++) {
            _t(string.concat(tag[i], ":setCurator"), who[i], abi.encodeWithSelector(v.setCurator.selector, c));
            _t(string.concat(tag[i], ":setFee"), who[i], abi.encodeWithSelector(v.setFee.selector, f));
            _t(string.concat(tag[i], ":setFeeRecipient"), who[i], abi.encodeWithSelector(v.setFeeRecipient.selector, fr));
            _t(string.concat(tag[i], ":setIsAllocator(false)"), who[i], abi.encodeWithSelector(v.setIsAllocator.selector, address(0xBAD), false));
            _t(string.concat(tag[i], ":submitGuardian"), who[i], abi.encodeWithSelector(v.submitGuardian.selector, g));
            _t(string.concat(tag[i], ":submitTimelock"), who[i], abi.encodeWithSelector(v.submitTimelock.selector, tl + 1));
            _t(string.concat(tag[i], ":setSupplyQueue"), who[i], abi.encodeWithSelector(v.setSupplyQueue.selector, new bytes32[](0)));
            _t(string.concat(tag[i], ":updateWithdrawQueue"), who[i], abi.encodeWithSelector(v.updateWithdrawQueue.selector, new uint256[](0)));
            _t(string.concat(tag[i], ":revokePendingTimelock"), who[i], abi.encodeWithSelector(v.revokePendingTimelock.selector));
            _t(string.concat(tag[i], ":acceptTimelock"), who[i], abi.encodeWithSelector(v.acceptTimelock.selector));
            _t(string.concat(tag[i], ":acceptGuardian"), who[i], abi.encodeWithSelector(v.acceptGuardian.selector));
        }

        emit log_named_uint("pendingTimelock after loop", v.pendingTimelock());
        emit log_named_uint("timelock now", v.timelock());
    }
}

