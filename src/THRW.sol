// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply Threeway token. The deployer (the launch factory) receives the entire supply.
contract THRW is ERC20 {
    constructor() ERC20("Threeway", "THRW") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
