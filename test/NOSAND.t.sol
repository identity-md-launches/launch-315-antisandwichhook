// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NOSAND} from "../src/NOSAND.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract NOSANDTest is Test {
    NOSAND token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new NOSAND();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Nosandwich");
        assertEq(token.symbol(), "NOSAND");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice), token.totalSupply());
    }

    function test_allowanceAndInfiniteApproval() public {
        token.approve(alice, 10 ether);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 4 ether);
        assertEq(token.allowance(address(this), alice), 6 ether);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
        assertEq(token.balanceOf(bob), 5 ether);
    }

    function test_invalidTransfersAndInsufficientAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1);
    }

    function test_noAdminOrMintEvenForDeployer() public {
        bytes4[8] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("mint()")),
            bytes4(keccak256("setOwner(address)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("setMinter(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, 1 ether));
            assertFalse(ok);
            vm.prank(alice);
            (ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
