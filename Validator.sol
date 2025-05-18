// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title ProofStorage
 * @dev Contract for storing blockchain proofs from validator nodes
 * Optimized for gas efficiency and high throughput
 */
contract ProofStorage is AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Packed struct for gas optimization
    struct Proof {
        bytes32 merkleRoot;    // 32 bytes
        uint128 timestamp;     // 16 bytes (sufficient until year ~10^10)
        uint128 blockNumber;   // 16 bytes (sufficient for billions of blocks)
        bool exists;           // 1 byte (packed with above)
    }

    // chainId => blockNumber => Proof
    mapping(uint256 => mapping(uint256 => Proof)) public proofs;
    
    // Track total proofs per chain for statistics
    mapping(uint256 => uint256) public totalProofs;
    
    // Events
    event ProofSubmitted(
        uint256 indexed blockNumber,
        uint256 indexed chainId,
        bytes32 merkleRoot,
        uint256 timestamp
    );
    
    event BatchProofSubmitted(
        uint256 indexed chainId,
        uint256 count,
        uint256 timestamp
    );
    
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);

    modifier onlyValidator() {
        require(hasRole(VALIDATOR_ROLE, msg.sender), "ProofStorage: not a validator");
        _;
    }

    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "ProofStorage: not an admin");
        _;
    }

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    /**
     * @dev Submit a single proof
     * @param merkleRoot The merkle root of the block
     * @param blockNumber The block number
     * @param timestamp The block timestamp
     * @param chainId The chain ID
     */
    function submitSingleProof(
        bytes32 merkleRoot,
        uint256 blockNumber,
        uint256 timestamp,
        uint256 chainId
    ) external onlyValidator whenNotPaused nonReentrant {
        require(merkleRoot != bytes32(0), "ProofStorage: invalid merkle root");
        require(blockNumber > 0, "ProofStorage: invalid block number");
        require(timestamp > 0, "ProofStorage: invalid timestamp");
        require(chainId > 0, "ProofStorage: invalid chain ID");
        require(!proofs[chainId][blockNumber].exists, "ProofStorage: proof already exists");

        proofs[chainId][blockNumber] = Proof({
            merkleRoot: merkleRoot,
            timestamp: uint128(timestamp),
            blockNumber: uint128(blockNumber),
            exists: true
        });

        unchecked {
            totalProofs[chainId]++;
        }

        emit ProofSubmitted(blockNumber, chainId, merkleRoot, timestamp);
    }

    /**
     * @dev Submit multiple proofs in a batch for gas efficiency
     * @param merkleRoots Array of merkle roots
     * @param blockNumbers Array of block numbers
     * @param timestamps Array of timestamps
     * @param chainIds Array of chain IDs
     */
    function submitProofBatch(
        bytes32[] calldata merkleRoots,
        uint256[] calldata blockNumbers,
        uint256[] calldata timestamps,
        uint256[] calldata chainIds
    ) external onlyValidator whenNotPaused nonReentrant {
        uint256 length = merkleRoots.length;
        require(length > 0, "ProofStorage: empty batch");
        require(
            length == blockNumbers.length &&
            length == timestamps.length &&
            length == chainIds.length,
            "ProofStorage: array length mismatch"
        );
        require(length <= 100, "ProofStorage: batch too large");

        mapping(uint256 => uint256) storage chainCounts = totalProofs;
        
        for (uint256 i = 0; i < length;) {
            bytes32 merkleRoot = merkleRoots[i];
            uint256 blockNumber = blockNumbers[i];
            uint256 timestamp = timestamps[i];
            uint256 chainId = chainIds[i];

            require(merkleRoot != bytes32(0), "ProofStorage: invalid merkle root");
            require(blockNumber > 0, "ProofStorage: invalid block number");
            require(timestamp > 0, "ProofStorage: invalid timestamp");
            require(chainId > 0, "ProofStorage: invalid chain ID");
            require(!proofs[chainId][blockNumber].exists, "ProofStorage: proof already exists");

            proofs[chainId][blockNumber] = Proof({
                merkleRoot: merkleRoot,
                timestamp: uint128(timestamp),
                blockNumber: uint128(blockNumber),
                exists: true
            });

            unchecked {
                chainCounts[chainId]++;
                i++;
            }

            emit ProofSubmitted(blockNumber, chainId, merkleRoot, timestamp);
        }

        emit BatchProofSubmitted(chainIds[0], length, block.timestamp);
    }

    /**
     * @dev Get a proof for a specific block and chain
     * @param blockNumber The block number
     * @param chainId The chain ID
     * @return merkleRoot The merkle root
     * @return timestamp The timestamp
     * @return exists Whether the proof exists
     */
    function getProof(uint256 blockNumber, uint256 chainId)
        external
        view
        returns (bytes32 merkleRoot, uint256 timestamp, bool exists)
    {
        Proof storage proof = proofs[chainId][blockNumber];
        return (proof.merkleRoot, uint256(proof.timestamp), proof.exists);
    }

    /**
     * @dev Verify if a proof exists
     * @param blockNumber The block number
     * @param chainId The chain ID
     * @return exists Whether the proof exists
     */
    function verifyProofExists(uint256 blockNumber, uint256 chainId)
        external
        view
        returns (bool exists)
    {
        return proofs[chainId][blockNumber].exists;
    }

    /**
     * @dev Get proofs for a range of blocks (for batch verification)
     * @param chainId The chain ID
     * @param startBlock Start block (inclusive)
     * @param endBlock End block (inclusive)
     * @return merkleRoots Array of merkle roots
     * @return timestamps Array of timestamps
     * @return existsFlags Array of existence flags
     */
    function getProofRange(
        uint256 chainId,
        uint256 startBlock,
        uint256 endBlock
    )
        external
        view
        returns (
            bytes32[] memory merkleRoots,
            uint256[] memory timestamps,
            bool[] memory existsFlags
        )
    {
        require(startBlock <= endBlock, "ProofStorage: invalid range");
        require(endBlock - startBlock <= 1000, "ProofStorage: range too large");

        uint256 length = endBlock - startBlock + 1;
        merkleRoots = new bytes32[](length);
        timestamps = new uint256[](length);
        existsFlags = new bool[](length);

        for (uint256 i = 0; i < length;) {
            uint256 blockNumber = startBlock + i;
            Proof storage proof = proofs[chainId][blockNumber];
            
            merkleRoots[i] = proof.merkleRoot;
            timestamps[i] = uint256(proof.timestamp);
            existsFlags[i] = proof.exists;
            
            unchecked { i++; }
        }
    }

    /**
     * @dev Add a new validator
     * @param validator Address of the validator
     */
    function addValidator(address validator) external onlyAdmin {
        require(validator != address(0), "ProofStorage: invalid validator address");
        _grantRole(VALIDATOR_ROLE, validator);
        emit ValidatorAdded(validator);
    }

    /**
     * @dev Remove a validator
     * @param validator Address of the validator
     */
    function removeValidator(address validator) external onlyAdmin {
        _revokeRole(VALIDATOR_ROLE, validator);
        emit ValidatorRemoved(validator);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyAdmin {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyAdmin {
        _unpause();
    }

    /**
     * @dev Get total number of proofs for a chain
     * @param chainId The chain ID
     * @return count Total number of proofs
     */
    function getTotalProofs(uint256 chainId) external view returns (uint256 count) {
        return totalProofs[chainId];
    }

    /**
     * @dev Check if an address is a validator
     * @param account Address to check
     * @return isValidator Whether the address is a validator
     */
    function isValidator(address account) external view returns (bool isValidator) {
        return hasRole(VALIDATOR_ROLE, account);
    }
}

/**
 * @title ProofVerifier
 * @dev Contract for verifying merkle proofs against stored roots
 */
contract ProofVerifier {
    ProofStorage public immutable proofStorage;

    constructor(address _proofStorage) {
        require(_proofStorage != address(0), "ProofVerifier: invalid storage address");
        proofStorage = ProofStorage(_proofStorage);
    }

    /**
     * @dev Verify a merkle proof against a stored root
     * @param proof Array of merkle proof elements
     * @param root The merkle root to verify against
     * @param leaf The leaf to verify
     * @return valid Whether the proof is valid
     */
    function verifyMerkleProof(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) public pure returns (bool valid) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length;) {
            bytes32 proofElement = proof[i];
            
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
            
            unchecked { i++; }
        }

        return computedHash == root;
    }

    /**
     * @dev Verify a transaction existed in a specific block
     * @param chainId The chain ID
     * @param blockNumber The block number
     * @param transactionHash The transaction hash
     * @param merkleProof The merkle proof
     * @return valid Whether the transaction existed
     */
    function verifyTransactionInBlock(
        uint256 chainId,
        uint256 blockNumber,
        bytes32 transactionHash,
        bytes32[] calldata merkleProof
    ) external view returns (bool valid) {
        (bytes32 storedRoot, , bool exists) = proofStorage.getProof(blockNumber, chainId);
        
        if (!exists) {
            return false;
        }

        return verifyMerkleProof(merkleProof, storedRoot, transactionHash);
    }

    /**
     * @dev Batch verify multiple transactions in different blocks
     * @param chainIds Array of chain IDs
     * @param blockNumbers Array of block numbers
     * @param transactionHashes Array of transaction hashes
     * @param merkleProofs Array of merkle proofs (flattened)
     * @param proofLengths Array of proof lengths for each transaction
     * @return results Array of verification results
     */
    function batchVerifyTransactions(
        uint256[] calldata chainIds,
        uint256[] calldata blockNumbers,
        bytes32[] calldata transactionHashes,
        bytes32[] calldata merkleProofs,
        uint256[] calldata proofLengths
    ) external view returns (bool[] memory results) {
        uint256 length = chainIds.length;
        require(
            length == blockNumbers.length &&
            length == transactionHashes.length &&
            length == proofLengths.length,
            "ProofVerifier: array length mismatch"
        );

        results = new bool[](length);
        uint256 proofIndex = 0;

        for (uint256 i = 0; i < length;) {
            uint256 proofLength = proofLengths[i];
            bytes32[] memory proof = new bytes32[](proofLength);
            
            for (uint256 j = 0; j < proofLength;) {
                proof[j] = merkleProofs[proofIndex + j];
                unchecked { j++; }
            }
            
            results[i] = verifyTransactionInBlock(
                chainIds[i],
                blockNumbers[i],
                transactionHashes[i],
                proof
            );
            
            unchecked {
                proofIndex += proofLength;
                i++;
            }
        }
    }
}

/**
 * @title ProofStorageFactory
 * @dev Factory for deploying ProofStorage contracts
 */
contract ProofStorageFactory {
    event ProofStorageDeployed(address indexed proofStorage, address indexed admin);

    /**
     * @dev Deploy a new ProofStorage contract
     * @param admin Address of the admin
     * @return proofStorage Address of the deployed contract
     */
    function deployProofStorage(address admin) external returns (address proofStorage) {
        require(admin != address(0), "ProofStorageFactory: invalid admin address");
        
        proofStorage = address(new ProofStorage(admin));
        emit ProofStorageDeployed(proofStorage, admin);
    }

    /**
     * @dev Deploy a new ProofStorage contract with deterministic address
     * @param admin Address of the admin
     * @param salt Salt for CREATE2
     * @return proofStorage Address of the deployed contract
     */
    function deployProofStorageDeterministic(
        address admin,
        bytes32 salt
    ) external returns (address proofStorage) {
        require(admin != address(0), "ProofStorageFactory: invalid admin address");
        
        bytes memory bytecode = abi.encodePacked(
            type(ProofStorage).creationCode,
            abi.encode(admin)
        );
        
        assembly {
            proofStorage := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        require(proofStorage != address(0), "ProofStorageFactory: deployment failed");
        emit ProofStorageDeployed(proofStorage, admin);
    }

    /**
     * @dev Predict the address of a ProofStorage contract
     * @param admin Address of the admin
     * @param salt Salt for CREATE2
     * @return predicted Predicted address
     */
    function predictProofStorageAddress(
        address admin,
        bytes32 salt
    ) external view returns (address predicted) {
        bytes memory bytecode = abi.encodePacked(
            type(ProofStorage).creationCode,
            abi.encode(admin)
        );
        
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );
        
        return address(uint160(uint256(hash)));
    }
}

/**
 * @title ProofQuery
 * @dev Contract for efficient querying of proofs
 */
contract ProofQuery {
    ProofStorage public immutable proofStorage;

    struct ProofInfo {
        bytes32 merkleRoot;
        uint256 timestamp;
        uint256 blockNumber;
        uint256 chainId;
        bool exists;
    }

    constructor(address _proofStorage) {
        require(_proofStorage != address(0), "ProofQuery: invalid storage address");
        proofStorage = ProofStorage(_proofStorage);
    }

    /**
     * @dev Get multiple proofs efficiently
     * @param chainIds Array of chain IDs
     * @param blockNumbers Array of block numbers
     * @return proofInfos Array of proof information
     */
    function getMultipleProofs(
        uint256[] calldata chainIds,
        uint256[] calldata blockNumbers
    ) external view returns (ProofInfo[] memory proofInfos) {
        require(chainIds.length == blockNumbers.length, "ProofQuery: array length mismatch");
        require(chainIds.length <= 1000, "ProofQuery: too many proofs requested");

        proofInfos = new ProofInfo[](chainIds.length);

        for (uint256 i = 0; i < chainIds.length;) {
            (bytes32 merkleRoot, uint256 timestamp, bool exists) = proofStorage.getProof(
                blockNumbers[i],
                chainIds[i]
            );

            proofInfos[i] = ProofInfo({
                merkleRoot: merkleRoot,
                timestamp: timestamp,
                blockNumber: blockNumbers[i],
                chainId: chainIds[i],
                exists: exists
            });

            unchecked { i++; }
        }
    }

    /**
     * @dev Check existence of multiple proofs
     * @param chainIds Array of chain IDs
     * @param blockNumbers Array of block numbers
     * @return existsFlags Array of existence flags
     */
    function checkMultipleProofsExist(
        uint256[] calldata chainIds,
        uint256[] calldata blockNumbers
    ) external view returns (bool[] memory existsFlags) {
        require(chainIds.length == blockNumbers.length, "ProofQuery: array length mismatch");
        require(chainIds.length <= 1000, "ProofQuery: too many proofs to check");

        existsFlags = new bool[](chainIds.length);

        for (uint256 i = 0; i < chainIds.length;) {
            existsFlags[i] = proofStorage.verifyProofExists(blockNumbers[i], chainIds[i]);
            unchecked { i++; }
        }
    }

    /**
     * @dev Find missing proofs in a range
     * @param chainId The chain ID
     * @param startBlock Start block (inclusive)
     * @param endBlock End block (inclusive)
     * @return missingBlocks Array of missing block numbers
     */
    function findMissingProofs(
        uint256 chainId,
        uint256 startBlock,
        uint256 endBlock
    ) external view returns (uint256[] memory missingBlocks) {
        require(startBlock <= endBlock, "ProofQuery: invalid range");
        require(endBlock - startBlock <= 10000, "ProofQuery: range too large");

        uint256[] memory tempMissing = new uint256[](endBlock - startBlock + 1);
        uint256 missingCount = 0;

        for (uint256 blockNumber = startBlock; blockNumber <= endBlock;) {
            if (!proofStorage.verifyProofExists(blockNumber, chainId)) {
                tempMissing[missingCount] = blockNumber;
                unchecked { missingCount++; }
            }
            unchecked { blockNumber++; }
        }

        // Resize array to actual missing count
        missingBlocks = new uint256[](missingCount);
        for (uint256 i = 0; i < missingCount;) {
            missingBlocks[i] = tempMissing[i];
            unchecked { i++; }
        }
    }
}
