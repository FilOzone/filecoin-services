// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

contract SessionKeyRegistry {
    mapping(address user => mapping(address signer => mapping(bytes32 permission => uint256))) public
        authorizationExpiry;

    event AuthorizationsUpdated(
        address indexed identity, address signer, uint256 expiry, bytes32[] permissions, string origin
    );

    function _setAuthorizations(address signer, uint256 expiry, bytes32[] calldata permissions, string calldata origin)
        internal
    {
        mapping(bytes32 => uint256) storage permissionExpiry = authorizationExpiry[msg.sender][signer];
        for (uint256 i = 0; i < permissions.length; i++) {
            permissionExpiry[permissions[i]] = expiry;
        }
        emit AuthorizationsUpdated(msg.sender, signer, expiry, permissions, origin);
    }

    /**
     * @notice Caller revokes from the signer the specified permissions
     * @param signer the authorized account
     * @param permissions the scope of authority to revoke from the signer
     * @param origin indicates what app prompted this revocation
     */
    function revoke(address signer, bytes32[] calldata permissions, string calldata origin) external {
        _setAuthorizations(signer, 0, permissions, origin);
    }

    /**
     * @notice Caller authorizes the signer with permissions until expiry
     * @param signer the account authorized
     * @param expiry when the authorization ends
     * @param permissions the scope of authority granted to the signer
     * @param origin indicates what app prompted this authorization
     */
    function login(address signer, uint256 expiry, bytes32[] calldata permissions, string calldata origin) external {
        _setAuthorizations(signer, expiry, permissions, origin);
    }

    /**
     * @notice Caller funds and authorizes the signer with permissions until expiry
     * @param signer the account authorized
     * @param expiry when the authorization ends
     * @param permissions the scope of authority granted to the signer
     * @param origin indicates what app prompted this authorization
     */
    function loginAndFund(
        address payable signer,
        uint256 expiry,
        bytes32[] calldata permissions,
        string calldata origin
    ) external payable {
        _setAuthorizations(signer, expiry, permissions, origin);
        signer.transfer(msg.value);
    }
}
