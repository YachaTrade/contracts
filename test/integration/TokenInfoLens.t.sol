// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {TokenInfoLens} from "../../src/integration/TokenInfoLens.sol";
import {MockTokenRegistryV1} from "../mocks/MockTokenRegistryV1.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";

contract TokenInfoLensTest is SetUp {
    MockTokenRegistryV1 internal v1;
    TokenInfoLens internal lens;

    address internal constant V1_WRAPPED_NATIVE = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    address internal unregistered = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        v1 = new MockTokenRegistryV1();
        assertTrue(V1_WRAPPED_NATIVE != address(wnative), "V1 fallback must be distinct from canonical WNATIVE");
        lens = new TokenInfoLens(address(v1), address(tokenRegistry), V1_WRAPPED_NATIVE);

        vm.prank(admin);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), ITokenRegistry.register.selector, true
        );
    }

    // ── Constructor guards ───────────────────────────────────────

    function test_constructor_revertsWhenV1IsZero() public {
        vm.expectRevert(TokenInfoLens.ZeroAddress.selector);
        new TokenInfoLens(address(0), address(tokenRegistry), V1_WRAPPED_NATIVE);
    }

    function test_constructor_revertsWhenV2IsZero() public {
        vm.expectRevert(TokenInfoLens.ZeroAddress.selector);
        new TokenInfoLens(address(v1), address(0), V1_WRAPPED_NATIVE);
    }

    function test_constructor_revertsWhenV1WrappedNativeIsZero() public {
        vm.expectRevert(TokenInfoLens.ZeroAddress.selector);
        new TokenInfoLens(address(v1), address(tokenRegistry), address(0));
    }

    function test_constructor_setsImmutableGetters() public view {
        assertEq(address(lens.v1Registry()), address(v1));
        assertEq(address(lens.v2Registry()), address(tokenRegistry));
        assertEq(lens.v1WrappedNative(), V1_WRAPPED_NATIVE);
    }

    // ── getTokenInfo ─────────────────────────────────────────────

    function test_getTokenInfo_returnsNone_whenUnregistered() public view {
        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(unregistered);
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.None));
        assertEq(info.quoteToken, address(0));
    }

    function test_getTokenInfo_returnsNone_forZeroAddress() public view {
        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(address(0));
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.None));
        assertEq(info.quoteToken, address(0));
    }

    function test_getTokenInfo_returnsV2_withRegistryQuoteToken() public {
        address token = address(0xa000000000000000000000000000000000000002);
        address pair = address(0xb000000000000000000000000000000000000002);
        _registerV2(token, pair, address(quoteToken));

        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(token);
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.V2));
        assertEq(info.quoteToken, address(quoteToken));
    }

    function test_getTokenInfo_returnsV1_withLegacyWrappedNativeAsQuoteToken() public {
        address token = address(0xA000000000000000000000000000000000000001);
        v1.register(token, address(0xb000000000000000000000000000000000000001));

        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(token);
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.V1));
        assertEq(info.quoteToken, V1_WRAPPED_NATIVE);
    }

    function test_getTokenInfo_returnsNone_whenV1HasPoolZeroButOtherFieldsSet() public {
        // V1 registration is judged by pool != 0 ONLY.
        address token = address(0xA00000000000000000000000000000000000001B);
        v1.registerFull(token, address(0), address(0xdead), address(0xdead));

        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(token);
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.None));
        assertEq(info.quoteToken, address(0));
    }

    function test_getTokenInfo_prefersV2_whenBothRegistered() public {
        address token = address(0xa000000000000000000000000000000000000012);
        v1.register(token, address(0xb000000000000000000000000000000000000001));
        _registerV2(token, address(0xb000000000000000000000000000000000000002), address(quoteToken));

        // Sanity: both registries must be live before we test the tie-break.
        (address pool,,) = v1.tokenInfos(token);
        assertTrue(pool != address(0), "V1 must be registered");
        assertTrue(tokenRegistry.isRegistered(token), "V2 must be registered");

        // Tie-break: lens must pick V2 with V2's quoteToken (not the V1 fallback).
        TokenInfoLens.TokenInfo memory info = lens.getTokenInfo(token);
        assertEq(uint256(info.version), uint256(TokenInfoLens.Version.V2));
        assertEq(info.quoteToken, address(quoteToken));
    }

    // ── getTokenInfos (batch) ────────────────────────────────────

    function test_getTokenInfos_emptyArray() public view {
        address[] memory empty = new address[](0);
        TokenInfoLens.TokenInfo[] memory got = lens.getTokenInfos(empty);
        assertEq(got.length, 0);
    }

    function test_getTokenInfos_mixedInput_preservesOrder() public {
        address tokenV1 = address(0xA1000000000000000000000000000000000000A1);
        address tokenV2 = address(0xA2000000000000000000000000000000000000A2);
        address tokenNone = address(0xA3000000000000000000000000000000000000a3);

        v1.register(tokenV1, address(0xb1000000000000000000000000000000000000B1));
        _registerV2(tokenV2, address(0xb2000000000000000000000000000000000000B2), address(quoteToken));

        address[] memory input = new address[](4);
        input[0] = tokenNone;
        input[1] = tokenV1;
        input[2] = tokenV2;
        input[3] = address(0); // zero address -> None

        TokenInfoLens.TokenInfo[] memory got = lens.getTokenInfos(input);
        assertEq(got.length, 4);

        assertEq(uint256(got[0].version), uint256(TokenInfoLens.Version.None));
        assertEq(got[0].quoteToken, address(0));

        assertEq(uint256(got[1].version), uint256(TokenInfoLens.Version.V1));
        assertEq(got[1].quoteToken, V1_WRAPPED_NATIVE);

        assertEq(uint256(got[2].version), uint256(TokenInfoLens.Version.V2));
        assertEq(got[2].quoteToken, address(quoteToken));

        assertEq(uint256(got[3].version), uint256(TokenInfoLens.Version.None));
        assertEq(got[3].quoteToken, address(0));
    }

    // ── helpers ─────────────────────────────────────────────────

    /// @dev Directly seeds legacy registry data for lens compatibility coverage.
    function _registerV2(address token, address pair, address quote) internal {
        tokenRegistry.register(token, pair, quote, ITokenRegistry.DexType.UniswapV2);
    }
}
