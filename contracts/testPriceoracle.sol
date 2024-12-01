// TestPriceOracle.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract TestPriceOracle {
    uint256 private price = 1 * 10 ** 18; // 1 USD initial price

    function getMemecoinPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 _newPrice) external {
        price = _newPrice;
    }
}