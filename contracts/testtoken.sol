// TestToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Doge is ERC20 {
    constructor() ERC20("Dogecoin", "DOGE") {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }
}

contract USDT is ERC20 {
    constructor() ERC20("USDT", "USDT") {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }
}