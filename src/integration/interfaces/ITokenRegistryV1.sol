// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice nadfun V1 (contract-v3) TokenRegistry의 최소 호출 인터페이스.
/// @dev V1은 Solidity 0.8.12로 작성됐고 등록 판단은 pool != address(0) 으로 한다.
interface ITokenRegistryV1 {
    function tokenInfos(address token) external view returns (address pool, address lpManager, address dexDeployer);
}
