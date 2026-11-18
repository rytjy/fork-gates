// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract MockERC20 is IERC20 {
    string public symbol;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        if (from != msg.sender) {
            require(allowance[from][msg.sender] >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Minimal ERC4626-shaped vault with a switchable rounding defect.
contract MockVault {
    MockERC20 public immutable asset;
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    bool public roundSharesUp;

    constructor(MockERC20 a) {
        asset = a;
    }

    function setRoundSharesUp(bool v) external {
        roundSharesUp = v;
    }

    /// @notice yield / donation: raises totalAssets without minting shares,
    /// breaking the 1:1 ratio so rounding paths are actually exercised.
    function donate(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "xfer");
        totalAssets += amount;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        if (totalSupply == 0) {
            shares = assets;
        } else {
            shares = assets * totalSupply / totalAssets;
            if (roundSharesUp && (assets * totalSupply) % totalAssets != 0) {
                shares += 1;
            }
        }
        require(asset.transferFrom(msg.sender, address(this), assets), "xfer");
        totalAssets += assets;
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        assets = shares * totalAssets / totalSupply;
        totalSupply -= shares;
        totalAssets -= assets;
        balanceOf[msg.sender] -= shares;
        require(asset.transfer(msg.sender, assets), "xfer");
    }
}
