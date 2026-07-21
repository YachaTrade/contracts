// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {TokenInfoLens} from "../../src/integration/TokenInfoLens.sol";
import {ITokenRegistryV1} from "../../src/integration/interfaces/ITokenRegistryV1.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";

/// @notice Fork test exercising TokenInfoLens against the real Monad mainnet
///         TokenRegistry contracts (V1 in contract-v3, V2 in nadfun-contract-v2)
///         plus the real WMON.
/// @dev Skips unless `RUN_FORK_TESTS=true` and `RPC_URL` is set.
contract TokenInfoLensForkTest is Test {
    // Mainnet registry addresses (operator-confirmed)
    address internal constant V1_REGISTRY = 0x3Be9198208c198e2a4dab9A575764C8468DC83c6;
    address internal constant V2_REGISTRY = 0x3CBF1E9F8847A4c968Bb2636696723CC82b91565;
    address internal constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    // Known registered tokens (operator-confirmed)
    address internal constant V1_TOKEN = 0x23c26BD5D55e0d3c1985e23eF2a377C0e2547777;
    address internal constant V2_TOKEN = 0xEabfAF9B5ed1c589c53494e36CdD8A7b35a77777;

    TokenInfoLens internal lens;

    function setUp() public {
        if (!vm.envOr("RUN_FORK_TESTS", false)) {
            vm.skip(true, "Set RUN_FORK_TESTS=true to run fork tests");
        }
        vm.createSelectFork(vm.envString("RPC_URL"));
        lens = new TokenInfoLens(V1_REGISTRY, V2_REGISTRY, WMON);
    }

    function test_fork_sanity_registriesHaveCode() public view {
        assertGt(V1_REGISTRY.code.length, 0, "V1 registry has no code on this fork");
        assertGt(V2_REGISTRY.code.length, 0, "V2 registry has no code on this fork");
        assertGt(WMON.code.length, 0, "WMON has no code on this fork");
    }

    function test_fork_v1Token_classifiedAsV1_withWmonQuote() public view {
        (address pool,,) = ITokenRegistryV1(V1_REGISTRY).tokenInfos(V1_TOKEN);
        assertTrue(pool != address(0), "V1 token must be registered in V1 registry");

        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(V1_TOKEN);
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.V1));
        assertEq(info.quoteToken, WMON, "V1 token should report WMON as quoteToken");
    }

    function test_fork_v2Token_classifiedAsV2_withRegistryQuote() public view {
        assertTrue(ITokenRegistry(V2_REGISTRY).isRegistered(V2_TOKEN), "V2 token must be registered in V2 registry");
        address expectedQuote = ITokenRegistry(V2_REGISTRY).getTokenInfo(V2_TOKEN).quoteToken;
        assertTrue(expectedQuote != address(0), "V2 quote token must be non-zero");

        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(V2_TOKEN);
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.V2));
        assertEq(info.quoteToken, expectedQuote, "V2 token quote must mirror V2 registry");
    }

    function test_fork_unregisteredAddress_classifiedAsNone() public view {
        address rando = address(0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD);
        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(rando);
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.None));
        assertEq(info.quoteToken, address(0));
    }

    function test_fork_zeroAddress_classifiedAsNone() public view {
        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(address(0));
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.None));
        assertEq(info.quoteToken, address(0));
    }

    function test_fork_batch_mixedRealAddresses() public view {
        address[] memory input = new address[](4);
        input[0] = V1_TOKEN;
        input[1] = V2_TOKEN;
        input[2] = address(0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD);
        input[3] = address(0);

        TokenInfoLens.TokenInfo[] memory got = lens.getTokenInfos(input);
        assertEq(got.length, 4);

        assertEq(uint256(got[0].version), uint256(TokenInfoLens.Version.V1));
        assertEq(got[0].quoteToken, WMON);

        assertEq(uint256(got[1].version), uint256(TokenInfoLens.Version.V2));
        assertEq(got[1].quoteToken, ITokenRegistry(V2_REGISTRY).getTokenInfo(V2_TOKEN).quoteToken);

        assertEq(uint256(got[2].version), uint256(TokenInfoLens.Version.None));
        assertEq(got[2].quoteToken, address(0));

        assertEq(uint256(got[3].version), uint256(TokenInfoLens.Version.None));
        assertEq(got[3].quoteToken, address(0));

        console.log("V1 token quote:", got[0].quoteToken);
        console.log("V2 token quote:", got[1].quoteToken);
    }
}
