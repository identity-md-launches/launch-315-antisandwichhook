// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply; the launch factory receives the entire supply on creation.
contract NOSAND is ERC20 {
    constructor() ERC20("Nosandwich", "NOSAND") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
