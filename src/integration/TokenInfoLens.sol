// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {ITokenRegistryV1} from "./interfaces/ITokenRegistryV1.sol";

/// @title TokenInfoLens
/// @notice V1·V2 TokenRegistry를 동시에 조회해서 토큰의 세대와 quoteToken을 결정론적으로
///         리턴하는 stateless view 컨트랙트. Off-chain SDK/indexer 전용.
/// @dev V1은 항상 WMON quote 토큰만 지원했으므로 WMON 주소를 constructor로 받아 V1
///      매치 시 fallback으로 사용한다. V2는 TokenRegistry에 저장된 quoteToken을 그대로 노출.
contract TokenInfoLens {
    enum Version {
        None,
        V1,
        V2
    }

    /// @notice 단일 토큰 조회 결과.
    /// @dev `version == None`이면 quoteToken은 `address(0)`.
    struct TokenInfo {
        Version version;
        address quoteToken;
    }

    error ZeroAddress();

    ITokenRegistryV1 public immutable v1Registry;
    ITokenRegistry public immutable v2Registry;
    address public immutable wmon;

    constructor(address v1Registry_, address v2Registry_, address wmon_) {
        if (v1Registry_ == address(0) || v2Registry_ == address(0) || wmon_ == address(0)) revert ZeroAddress();
        v1Registry = ITokenRegistryV1(v1Registry_);
        v2Registry = ITokenRegistry(v2Registry_);
        wmon = wmon_;
    }

    /// @notice 단일 토큰의 세대와 quoteToken을 조회.
    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        return _getTokenInfo(token);
    }

    /// @notice 다수 토큰을 한 번에 조회. 입력 인덱스 순서를 보존.
    function getTokenInfos(address[] calldata tokens) external view returns (TokenInfo[] memory infos) {
        infos = new TokenInfo[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            infos[i] = _getTokenInfo(tokens[i]);
        }
    }

    function _getTokenInfo(address token) private view returns (TokenInfo memory) {
        if (v2Registry.isRegistered(token)) {
            return TokenInfo({version: Version.V2, quoteToken: v2Registry.getTokenInfo(token).quoteToken});
        }
        (address pool,,) = v1Registry.tokenInfos(token);
        if (pool != address(0)) {
            return TokenInfo({version: Version.V1, quoteToken: wmon});
        }
        return TokenInfo({version: Version.None, quoteToken: address(0)});
    }
}
