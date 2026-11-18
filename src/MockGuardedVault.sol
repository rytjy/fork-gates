// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal vault with privileged entry points, pausing and freezing.
/// @dev    missingGuard is a calibration switch: family A1 must go red when set.
contract MockGuardedVault {
    address public owner;
    bool public paused;
    bool public missingGuard;
    address public keeper;
    uint256 public feeBps;
    mapping(address => bool) public frozen;

    event FeeSet(uint256 bps);
    event PausedSet(bool value);
    event FrozenSet(address indexed who, bool value);
    event KeeperSet(address indexed keeper);
    event Swept(address indexed to, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function setMissingGuard(bool v) external onlyOwner {
        missingGuard = v;
    }

    function setFee(uint256 bps) external onlyOwner {
        feeBps = bps;
        emit FeeSet(bps);
    }

    function setPaused(bool v) external onlyOwner {
        paused = v;
        emit PausedSet(v);
    }

    function setFrozen(address who, bool v) external onlyOwner {
        require(who != address(0), "zero address");
        frozen[who] = v;
        emit FrozenSet(who, v);
    }

    function setKeeper(address k) external {
        if (!missingGuard) {
            require(msg.sender == owner, "not owner");
        }
        require(k != address(0), "zero address");
        keeper = k;
        emit KeeperSet(k);
    }

    function sweep(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero address");
        emit Swept(to, amount);
    }

    function userAction() external {
        require(!frozen[msg.sender], "frozen");
        require(!paused, "paused");
    }
}
