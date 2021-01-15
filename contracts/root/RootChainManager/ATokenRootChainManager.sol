pragma solidity 0.6.6;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {ATokenRootChainManagerStorage} from "./ATokenRootChainManagerStorage.sol"; 
import {IStateSender} from "../StateSender/IStateSender.sol";
import {ICheckpointManager} from "../ICheckpointManager.sol";
import {RLPReader} from "../../lib/RLPReader.sol";
import {MerklePatriciaProof} from "../../lib/MerklePatriciaProof.sol";
import {Merkle} from "../../lib/Merkle.sol";
import {Initializable} from "../../common/Initializable.sol";
import {NativeMetaTransaction} from "../../common/NativeMetaTransaction.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControlMixin} from "../../common/AccessControlMixin.sol";
import {ContextMixin} from "../../common/ContextMixin.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface ILendingPool {
    function getReserveNormalizedIncome(address _asset) external view returns (uint256);
}

interface IAToken {
    function POOL() external returns(ILendingPool);
    function UNDERLYING_ASSET_ADDRESS() external returns(address);
}

interface IERC20Meta {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

contract ATokenRootChainManager is    
    Initializable,
    AccessControl, // included to match old storage layout while upgrading
    ATokenRootChainManagerStorage, // created to match old storage layout while upgrading
    AccessControlMixin,
    NativeMetaTransaction,
    ContextMixin
{
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;
    using Merkle for bytes32;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // maybe DEPOSIT and MAP_TOKEN can be reduced to bytes4
    bytes32 public constant DEPOSIT = keccak256("DEPOSIT");
    bytes32 public constant MAP_TOKEN = keccak256("MAP_TOKEN");    
    bytes32 public constant MAPPER_ROLE = keccak256("MAPPER_ROLE");
    uint256 internal constant P27 = 1e27;
    uint256 internal constant HALF_P27 = P27 / 2;
    bytes32 public constant TRANSFER_EVENT_SIG = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

   event TokenMapped(
        address indexed rootToken,
        address indexed childToken,
        bytes32 indexed tokenType
    );

    event LockedERC20(
        address indexed depositor,
        address indexed depositReceiver,
        address indexed rootToken,
        uint256 amount
    );

    function _msgSender()
        internal
        override
        view
        returns (address payable sender)
    {
        return ContextMixin.msgSender();
    }

    /**
     * @notice Deposit ether by directly sending to the contract
     * The account sending ether receives WETH on child chain
     */
    receive() external payable {
        revert("Cannot send ETH over aToken bridge");
    }

    /**
     * @notice Initialize the contract after it has been proxified
     * @dev meant to be called once immediately after deployment
     * @param owner the account that should be granted admin role
     */
    function initialize(
        address owner,
        address stateSender,
        address checkpointManager,
        address _childChainManagerAddress,
        bytes32 _childTokenBytecodeHash
    )
        external
        initializer
    {
        _initializeEIP712("ATokenRootChainManager");
        _setupContractId("ATokenRootChainManager");
        _setupRole(DEFAULT_ADMIN_ROLE, owner);
        _setupRole(MAPPER_ROLE, owner);
        _stateSender = IStateSender(stateSender);
        _checkpointManager = ICheckpointManager(checkpointManager);
        childChainManagerAddress = _childChainManagerAddress;
        childTokenBytecodeHash = _childTokenBytecodeHash;        
    }

    // adding seperate function setupContractId since initialize is already called with old implementation
    function setupContractId()
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        _setupContractId("ATokenRootChainManager");
    }

    // adding seperate function initializeEIP712 since initialize is already called with old implementation
    function initializeEIP712()
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        _setDomainSeperator("ATokenRootChainManager");
    }

    /**
     * @notice Set the state sender, callable only by admins
     * @dev This should be the state sender from plasma contracts
     * It is used to send bytes from root to child chain
     * @param newStateSender address of state sender contract
     */
    function setStateSender(address newStateSender)
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        _stateSender = IStateSender(newStateSender);
    }

    /**
     * @notice Get the address of contract set as state sender
     * @return The address of state sender contract
     */
    function stateSenderAddress() external view returns (address) {
        return address(_stateSender);
    }

    /**
     * @notice Set the checkpoint manager, callable only by admins
     * @dev This should be the plasma contract responsible for keeping track of checkpoints
     * @param newCheckpointManager address of checkpoint manager contract
     */
    function setCheckpointManager(address newCheckpointManager)
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        _checkpointManager = ICheckpointManager(newCheckpointManager);
    }

    /**
     * @notice Get the address of contract set as checkpoint manager
     * @return The address of checkpoint manager contract
     */
    function checkpointManagerAddress() external view returns (address) {
        return address(_checkpointManager);
    }

    /**
     * @notice Set the child chain manager, callable only by admins
     * @dev This should be the contract responsible to receive deposit bytes on child chain
     * @param newChildChainManager address of child chain manager contract
     * @param newChildTokenBytecodeHash hash of bytecode used to create child token
     */
    function setChildChainManagerAddressAndChildTokenBytecodeHash(address newChildChainManager, bytes32 newChildTokenBytecodeHash)
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        require(newChildChainManager != address(0x0), "ATokenRootChainManager: INVALID_CHILD_CHAIN_ADDRESS");
        childChainManagerAddress = newChildChainManager;        
        childTokenBytecodeHash = newChildTokenBytecodeHash;
    }

    /**
     * @notice Set the child chain manager, callable only by admins
     * @dev This should be the contract responsible to receive deposit bytes on child chain
     * @param newChildChainManager address of child chain manager contract     
     */
    function setChildChainManagerAddress(address newChildChainManager)
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        require(newChildChainManager != address(0x0), "ATokenRootChainManager: INVALID_CHILD_CHAIN_ADDRESS");
        childChainManagerAddress = newChildChainManager;                
    }

    /**
     * @notice Set the child bytecode hash
     * @dev This is used by a create2 call to precalculate the child token address
     * @param newChildTokenBytecodeHash address of child chain manager contract     
     */
    function setChildTokenBytecodeHash(bytes32 newChildTokenBytecodeHash)
        external
        only(DEFAULT_ADMIN_ROLE)
    {        
        childTokenBytecodeHash = newChildTokenBytecodeHash;                
    }

    
    function childTokenAddress(address rootToken) public view returns (address childToken_) {
        // precompute childToken address for mapping
        childToken_ = address(uint160(uint(keccak256(abi.encodePacked(
            bytes1(0xff),
            childChainManagerAddress, // contract creating address
            bytes32(bytes20(rootToken)), // salt
            childTokenBytecodeHash // bytecode hash
        )))));
    }

    /**
     * @notice Map a token to enable its movement via the PoS Portal, callable only by mappers
     * @param rootToken address of token on root chain     
     */
    function mapToken(
        address rootToken        
    ) external only(MAPPER_ROLE) {
        // explicit check if token is already mapped to avoid accidental remaps
        require(
            rootToChildToken[rootToken] == address(0),
            "ATokenRootChainManager: ALREADY_MAPPED"
        );
        address childToken = childTokenAddress(rootToken);
        _mapToken(rootToken, childToken);
    }

    /**
     * @notice Remap a token that has already been mapped, properly cleans up old mapping
     * Callable only by mappers
     * @param rootToken address of token on root chain     
     */
    function remapToken(
        address rootToken        
    ) external only(MAPPER_ROLE) {
        address childToken = childTokenAddress(rootToken);
        // cleanup old mapping
        address oldChildToken = rootToChildToken[rootToken];
        require(childToken != oldChildToken, "ATokenRootChainManager: Child token is the same");
        address oldRootToken = childToRootToken[childToken];
        if (rootToChildToken[oldRootToken] != address(0)) {
            rootToChildToken[oldRootToken] = address(0);            
        }

        if (childToRootToken[oldChildToken] != address(0)) {
            childToRootToken[oldChildToken] = address(0);
        }      
        _mapToken(rootToken, childToken);
    }

    function _mapToken(
        address rootToken,
        address childToken
    ) private {                        
        rootToChildToken[rootToken] = childToken;
        childToRootToken[childToken] = rootToken;        

        emit TokenMapped(rootToken, childToken, 0x0);

        bytes memory syncData = abi.encode(            
            rootToken, 
            abi.encodePacked('Matic ', IERC20Meta(rootToken).name()),
            abi.encodePacked('m',IERC20Meta(rootToken).symbol()),
            IERC20Meta(rootToken).decimals()
        );
        _stateSender.syncState(
            childChainManagerAddress,
            abi.encode(MAP_TOKEN, syncData)
        );
    }
    

    /**
     * @notice Move tokens from root to child chain
     * @dev This mechanism supports arbitrary tokens as long as its predicate has been registered and the token is mapped
     * @param user address of account that should receive this deposit on child chain
     * @param rootToken address of token that is being deposited
     * @param depositData bytes data that is sent to predicate and child token contracts to handle deposit
     */
    function depositFor(
        address user,
        address rootToken,
        bytes memory depositData
    ) public {        
        require(rootToChildToken[rootToken] != address(0x0), "ATokenRootChainManager: TOKEN_NOT_MAPPED");
        require(
            user != address(0),
            "ATokenRootChainManager: INVALID_USER"
        );

        uint256 aTokenValue = abi.decode(depositData, (uint256));
        address depositor = _msgSender();
        emit LockedERC20(depositor, user, rootToken, aTokenValue);
        IERC20(rootToken).safeTransferFrom(depositor, address(this), aTokenValue);

        uint256 maTokenValue = getMATokenValue(rootToken, aTokenValue);
        // replace aTokenValue with maTokenValue in depositData
        // assembly increases start of bytes array and reduces the size by one uint256
        uint256 depositDataLength = depositData.length;
        assembly { 
            depositData := add(depositData, 32) 
            mstore(depositData, sub(depositDataLength, 32))
        }        
        depositData = abi.encodePacked(maTokenValue, depositData);        
        bytes memory syncData = abi.encode(user, rootToken, depositData);
        _stateSender.syncState(
            childChainManagerAddress,
            abi.encode(DEPOSIT, syncData)
        );
    }    
     
     /**
    * @dev Divides two 27 decimal percision values, rounding half up to the nearest decimal
    * @param a 27 decimal percision value
    * @param b 27 decimal percision value
    * @return The result of a/b, in 27 decimal percision value
    **/
    function p27Div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "p27 division by 0");
        uint256 c = a * P27;
        require(a == c / P27, "p27 multiplication overflow");      
        uint256 bDividedByTwo = b / 2;
        c += bDividedByTwo;
        require(c >= bDividedByTwo, "p27 multiplication addition overflow");        
        return c / b;
    }
    
     /**
    * @dev Multiplies two 27 decimal percision values, rounding half up to the nearest decimal
    * @param a 27 decimal percision value
    * @param b 27 decimal percision value
    * @return The result of a*b, in 27 decimal percision value
    **/
    function p27Mul(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a * b;
        if(c == 0) {
            return 0;
        }
        require(b == c / a, "p27 multiplication overflow");
        c += HALF_P27;
        require(c >= HALF_P27, "p27 multiplication addition overflow");
        return c / P27;
    }

    /**
    * @dev Converts aToken value to maToken value
    * @param _aTokenAddress aToken contract address
    * @param _aTokenValue aToken value to convert
    * @return maTokenValue_ The converted maToken value
    **/
    function getMATokenValue(address _aTokenAddress, uint256 _aTokenValue) public returns (uint256 maTokenValue_) {
        ILendingPool pool = IAToken(_aTokenAddress).POOL();
        uint256 liquidityIndex = pool.getReserveNormalizedIncome(IAToken(_aTokenAddress).UNDERLYING_ASSET_ADDRESS());
        maTokenValue_ = p27Div(_aTokenValue, liquidityIndex);        
    }

    /**
    * @dev Converts maToken value to aToken value
    * @param _aTokenAddress aToken contract address
    * @param _maTokenValue maToken value to convert
    * @return aTokenValue_ The converted aToken value
    **/
    function getATokenValue(address _aTokenAddress, uint256 _maTokenValue) public returns (uint256 aTokenValue_) {
        ILendingPool pool = IAToken(_aTokenAddress).POOL();
        uint256 liquidityIndex = pool.getReserveNormalizedIncome(IAToken(_aTokenAddress).UNDERLYING_ASSET_ADDRESS());
        aTokenValue_ = p27Mul(_maTokenValue, liquidityIndex);        
    }

    /**
     * @notice exit tokens by providing proof
     * @dev This function verifies if the transaction actually happened on child chain
     * the transaction log is then sent to token predicate to handle it accordingly
     *
     * @param inputData RLP encoded data of the reference tx containing following list of fields
     *  0 - headerNumber - Checkpoint header block number containing the reference tx
     *  1 - blockProof - Proof that the block header (in the child chain) is a leaf in the submitted merkle root
     *  2 - blockNumber - Block number containing the reference tx on child chain
     *  3 - blockTime - Reference tx block time
     *  4 - txRoot - Transactions root of block
     *  5 - receiptRoot - Receipts root of block
     *  6 - receipt - Receipt of the reference transaction
     *  7 - receiptProof - Merkle proof of the reference receipt
     *  8 - branchMask - 32 bits denoting the path of receipt in merkle tree
     *  9 - receiptLogIndex - Log Index to read from the receipt
     */
    function exit(bytes calldata inputData) external {
        RLPReader.RLPItem[] memory inputDataRLPList = inputData
            .toRlpItem()
            .toList();

        // checking if exit has already been processed
        // unique exit is identified using hash of (blockNumber, branchMask, receiptLogIndex)
        bytes32 exitHash = keccak256(
            abi.encodePacked(
                inputDataRLPList[2].toUint(), // blockNumber
                // first 2 nibbles are dropped while generating nibble array
                // this allows branch masks that are valid but bypass exitHash check (changing first 2 nibbles only)
                // so converting to nibble array and then hashing it
                MerklePatriciaProof._getNibbleArray(inputDataRLPList[8].toBytes()), // branchMask
                inputDataRLPList[9].toUint() // receiptLogIndex
            )
        );
        require(
            processedExits[exitHash] == false,
            "ATokenRootChainManager: EXIT_ALREADY_PROCESSED"
        );
        processedExits[exitHash] = true;

        RLPReader.RLPItem[] memory receiptRLPList = inputDataRLPList[6]
            .toBytes()
            .toRlpItem()
            .toList();
        RLPReader.RLPItem memory logRLP = receiptRLPList[3]
            .toList()[
                inputDataRLPList[9].toUint() // receiptLogIndex
            ];

        address childToken = RLPReader.toAddress(logRLP.toList()[0]); // log emitter address field
        // log should be emmited only by the child token
        address rootToken = childToRootToken[childToken];
        require(
            rootToken != address(0),
            "ATokenRootChainManager: TOKEN_NOT_MAPPED"
        );

        // branch mask can be maximum 32 bits
        require(
            inputDataRLPList[8].toUint() &
                0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000 ==
                0,
            "ATokenRootChainManager: INVALID_BRANCH_MASK"
        );

        // verify receipt inclusion
        require(
            MerklePatriciaProof.verify(
                inputDataRLPList[6].toBytes(), // receipt
                inputDataRLPList[8].toBytes(), // branchMask
                inputDataRLPList[7].toBytes(), // receiptProof
                bytes32(inputDataRLPList[5].toUint()) // receiptRoot
            ),
            "ATokenRootChainManager: INVALID_PROOF"
        );

        // verify checkpoint inclusion
        _checkBlockMembershipInCheckpoint(
            inputDataRLPList[2].toUint(), // blockNumber
            inputDataRLPList[3].toUint(), // blockTime
            bytes32(inputDataRLPList[4].toUint()), // txRoot
            bytes32(inputDataRLPList[5].toUint()), // receiptRoot
            inputDataRLPList[0].toUint(), // headerNumber
            inputDataRLPList[1].toBytes() // blockProof
        );         

        exitTokens(
            _msgSender(),
            childToRootToken[childToken],
            logRLP.toRlpBytes()
        );
    }

    function exitTokens(
        address,
        address rootToken,
        bytes memory log
    ) private {
        RLPReader.RLPItem[] memory logRLPList = log.toRlpItem().toList();
        RLPReader.RLPItem[] memory logTopicRLPList = logRLPList[1].toList(); // topics

        require(
            bytes32(logTopicRLPList[0].toUint()) == TRANSFER_EVENT_SIG, // topic0 is event sig
            "ATokenRootChainManager: INVALID_SIGNATURE"
        );

        address withdrawer = address(logTopicRLPList[1].toUint()); // topic1 is from address

        require(
            address(logTopicRLPList[2].toUint()) == address(0), // topic2 is to address
            "ATokenRootChainManager: INVALID_RECEIVER"
        );

        uint256 maTokenValue = logRLPList[2].toUint(); // log data field
        uint256 aTokenValue = getATokenValue(rootToken, maTokenValue);

        IERC20(rootToken).safeTransfer(
            withdrawer,
            aTokenValue
        );
    }

    function _checkBlockMembershipInCheckpoint(
        uint256 blockNumber,
        uint256 blockTime,
        bytes32 txRoot,
        bytes32 receiptRoot,
        uint256 headerNumber,
        bytes memory blockProof
    ) private view returns (uint256) {
        (
            bytes32 headerRoot,
            uint256 startBlock,
            ,
            uint256 createdAt,

        ) = _checkpointManager.headerBlocks(headerNumber);

        require(
            keccak256(
                abi.encodePacked(blockNumber, blockTime, txRoot, receiptRoot)
            )
                .checkMembership(
                blockNumber.sub(startBlock),
                headerRoot,
                blockProof
            ),
            "ATokenRootChainManager: INVALID_HEADER"
        );
        return createdAt;
    }
}
