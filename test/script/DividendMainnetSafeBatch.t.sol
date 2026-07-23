// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IDividendVault} from "../../src/interfaces/IDividendVault.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";

interface IUUPSUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract DividendMainnetSafeBatchTest is Test {
    string private constant BATCH_PATH = "deploy/dividend-mainnet-safe-batch.json";

    function test_allTransactionSelectorsMatchCurrentInterfaces() public view {
        string memory batch = vm.readFile(BATCH_PATH);

        _assertSelector(batch, 0, IUUPSUpgrade.upgradeToAndCall.selector);
        _assertSelector(batch, 1, IVaultRegistry.register.selector);
        _assertSelector(batch, 2, IProtocolManager.setOperatorPermission.selector);
        _assertSelector(batch, 3, IProtocolManager.setOperatorPermission.selector);
        _assertSelector(batch, 4, IDividendVault.setAdapters.selector);
        _assertSelector(batch, 5, IDividendVault.setWnative.selector);
        for (uint256 i = 6; i < 12; ++i) {
            _assertSelector(batch, i, IDividendVault.setAllowedDividendToken.selector);
        }
    }

    function _assertSelector(string memory batch, uint256 index, bytes4 expected) private view {
        bytes memory data = vm.parseJsonBytes(batch, string.concat(".transactions[", vm.toString(index), "].data"));
        assertGe(data.length, 4, "transaction calldata is shorter than a selector");

        bytes4 actual;
        assembly ("memory-safe") {
            actual := mload(add(data, 0x20))
        }
        assertEq(actual, expected, string.concat("stale selector at transaction ", vm.toString(index)));
    }
}
