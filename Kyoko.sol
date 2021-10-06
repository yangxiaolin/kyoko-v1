// SPDX-License-Identifier: MIT

pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "./BorrowToken.sol";
import "./LenderToken.sol";

contract Kyoko is Ownable, ERC721Holder {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    BorrowToken public bToken; // bToken

    LenderToken public lToken; // lToken

    bool public pause = false; // true: any operation will be rejected

    uint256 public yearSeconds = 31536000; // Seconds per year

    uint256 public fee = 100; // admin fee

    address[] public whiteList; // whiteList

    struct MARK {
        bool isBorrow;
        bool isRepay;
        bool hasWithdraw;
        bool liquidate;
    }

    struct COLLATERAL {
        uint256 apy;
        uint256 price;
        uint256 period;
        uint256 buffering;
        address erc20Token;
        string description;
    }

    struct OFFER {
        uint256 apy;
        uint256 price;
        uint256 period;
        uint256 buffering;
        address erc20Token;
        bool accept;
        bool symbol;
        uint256 lTokenId;
    }

    struct NFT {
        address holder;
        address lender;
        uint256 tokenId; // nft tokenId
        address nftToken; // nft address
        uint256 bTokenId; // btoken id
        uint256 lTokenId; // ltoken id
        uint256 borrowTimestamp; // borrow timestamp
        uint256 emergencyTimestamp; // emergency timestamp
        uint256 repayAmount; // repayAmount
        MARK marks;
        COLLATERAL collateral;
    }

    struct ASSETS {
        uint256 repayAmount;
        uint256 lTokenId;
        address erc20Token;
        bool hasClaim;
    }

    mapping(address => mapping(uint256 => NFT)) public NftMap; // Collaterals mapping

    mapping(address => mapping(uint256 => mapping(address => OFFER)))
        public OfferMap;

    mapping(uint256 => ASSETS) public AssetsMap;

    event NFTReceived(
        address indexed operator,
        address indexed from,
        uint256 indexed tokenId,
        bytes data
    );

    event Deposit(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        COLLATERAL _collateral,
        address indexed _holder
    );

    event Modify(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        address indexed _holder
    );

    event Lend(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        address indexed _lender,
        NFT _nft
    );

    event Borrow(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        address indexed _holder,
        NFT _nft
    );

    event Repay(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        NFT _nft
    );

    event AcceptOffer(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        address indexed _lender,
        OFFER _offer
    );

    event ExecuteEmergency(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        address indexed _lender
    );

    event Liquidate(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        address _lender
    );

    event AddOffer(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        OFFER _offer,
        address indexed _lender
    );

    event CancelOffer(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        address _lender,
        OFFER indexed _offer
    );

    event ClaimCollateral(
        address indexed _nftToken,
        uint256 indexed _nftTokenId,
        address _holder
    );

    event AddAssets(
        uint256 indexed _lTokenId,
        address indexed _lender,
        NFT _nft,
        ASSETS _assets
    );

    event ClaimERC20(address indexed _lender, uint256 indexed _lTokenId);

    event AddWhiteList(address _address);

    event SetWhiteList(address[] _whiteList);

    event SetFee(uint256 _fee);

    event SetPause(bool _Pause);

    constructor(BorrowToken _bToken, LenderToken _lToken) {
        bToken = _bToken;
        lToken = _lToken;
    }

    modifier isPause() {
        require(!pause, "Now Pause");
        _;
    }

    modifier checkWhiteList(address _address) {
        bool include;
        for (uint256 index = 0; index < whiteList.length; index++) {
            if (whiteList[index] == _address) {
                include = true;
                break;
            }
        }
        require(include, "The address is not whitelisted");
        _;
    }

    modifier checkCollateralStatus(uint256 _nftTokenId, address _nftToken) {
        NFT memory _nft = NftMap[_nftToken][_nftTokenId];
        require(!_nft.marks.isRepay && _nft.marks.isBorrow, "NFT status wrong");
        _;
    }

    function setPause(bool _pause) external onlyOwner {
        pause = _pause;
        emit SetPause(_pause)
    }

    function setWhiteList(address[] calldata _whiteList)
        external
        isPause
        onlyOwner
    {
        whiteList = _whiteList;
        emit SetWhiteList(_whiteList);
    }

    function setFee(uint256 _fee) external isPause onlyOwner {
        fee = _fee;
        emit SetFee(_fee);
    }

    function addWhiteList(address _address) external isPause onlyOwner {
        whiteList.push(_address);
        emit AddWhiteList(_address);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) public override(ERC721Holder) returns (bytes4) {
        emit NFTReceived(operator, from, tokenId, data);
        return
            bytes4(
                keccak256("onERC721Received(address,address,uint256,bytes)")
            );
    }

    // deposit NFT
    function deposit(
        address _nftToken,
        uint256 _nftTokenId,
        uint256 _apy,
        uint256 _price,
        uint256 _period,
        uint256 _buffering,
        address _erc20Token,
        string memory _description
    ) external isPause checkWhiteList(_erc20Token) {
        require(IERC721(_nftToken) != bToken); // btoken => No
        require(
            IERC721(_nftToken).supportsInterface(0x80ac58cd),
            "Parameter _nftToken is not ERC721 contract address"
        );
        uint256 _nftid = _nftTokenId;
        address _nftadr = _nftToken;
        // mint bToken
        uint256 _bTokenId = bToken.mint(msg.sender);
        // loan status info
        MARK memory _mark = MARK(false, false, false, false);
        // collateral info
        COLLATERAL memory _collateral = COLLATERAL(
            _apy,
            _price,
            _period,
            _buffering,
            _erc20Token,
            _description
        );
        IERC721(_nftadr).safeTransferFrom(msg.sender, address(this), _nftid);
        // set collateral info
        NftMap[_nftadr][_nftid] = NFT({
            holder: msg.sender,
            tokenId: _nftid,
            nftToken: _nftadr,
            bTokenId: _bTokenId,
            borrowTimestamp: 0,
            emergencyTimestamp: 0,
            repayAmount: 0,
            lTokenId: 0,
            marks: _mark,
            lender: address(0),
            collateral: _collateral
        });

        emit Deposit(_nftadr, _nftid, _collateral, msg.sender);
    }

    function modify(
        address _nftToken,
        uint256 _nftTokenId,
        uint256 _apy,
        uint256 _price,
        uint256 _period,
        uint256 _buffering,
        address _erc20Token,
        string memory _description
    ) external isPause checkWhiteList(_erc20Token){
        NFT storage _nft = NftMap[_nftToken][_nftTokenId];
        require(bToken.ownerOf(_nft.bTokenId) == msg.sender, 'Not bToken owner');
        // change collateral status
        _nft.collateral.apy = _apy;
        _nft.collateral.price = _price;
        _nft.collateral.period = _period;
        _nft.collateral.buffering = _buffering;
        _nft.collateral.erc20Token = _erc20Token;
        _nft.collateral.description = _description;
        emit Modify(_nftToken, _nftTokenId, msg.sender);
    }

    function addOffer(
        address _nftToken,
        uint256 _nftTokenId,
        uint256 _apy,
        uint256 _price,
        uint256 _period,
        uint256 _buffering,
        address _erc20Token
    ) external isPause checkWhiteList(_erc20Token) {
        NFT memory _nft = NftMap[_nftToken][_nftTokenId];
        require(!_nft.marks.isBorrow, "This collateral already borrowed");
        OFFER memory _offer = OfferMap[_nftToken][_nftTokenId][msg.sender];
        if (!_offer.accept && _offer.symbol) {
            cancelOffer(_nftToken, _nftTokenId);
        }
        uint256 _nftid = _nftTokenId;
        address _nftadr = _nftToken;
        // mint lToken
        uint256 _lTokenId = lToken.mint(msg.sender);
        uint256 _amount = _price.mul(10000).div(10000 + fee);
        IERC20(_erc20Token).safeTransferFrom(
            address(msg.sender),
            address(this),
            _price
        );
        OFFER memory _off = OFFER(
            _apy,
            _amount,
            _period,
            _buffering,
            _erc20Token,
            false,
            true,
            _lTokenId
        );

        OfferMap[_nftadr][_nftid][msg.sender] = _off;

        emit AddOffer(_nftadr, _nftid, _off, msg.sender);
    }

    function cancelOffer(address _nftToken, uint256 _nftTokenId)
        public
        isPause
    {
        OFFER storage _offer = OfferMap[_nftToken][_nftTokenId][msg.sender];
        // Verify token owner
        require(lToken.ownerOf(_offer.lTokenId) == msg.sender, 'Not lToken owner');
        lToken.burn(_offer.lTokenId);
        require(
            _offer.symbol && !_offer.accept,
            "This offer already has accepted."
        );
        _offer.accept = false;
        _offer.symbol = false;
        uint256 _price = _offer.price.mul(10000 + fee).div(10000);
        IERC20(_offer.erc20Token).safeTransfer(msg.sender, _price);
        emit CancelOffer(_nftToken, _nftTokenId, msg.sender, _offer);
    }

    function acceptOffer(
        address _nftToken,
        uint256 _nftTokenId,
        address _lender
    ) external isPause {
        NFT storage _nft = NftMap[_nftToken][_nftTokenId];
        OFFER storage _offer = OfferMap[_nftToken][_nftTokenId][_lender];
        require(bToken.ownerOf(_nft.bTokenId) == msg.sender, 'Not bToken owner');
        require(!_nft.marks.isBorrow, 'This collateral already borrowed');
        require(!_offer.accept && _offer.symbol, "This Offer out of date");
        // change offer status
        _offer.accept = true;

        // change collateral status
        _nft.collateral.apy = _offer.apy;
        _nft.collateral.price = _offer.price;
        _nft.collateral.period = _offer.period;
        _nft.collateral.buffering = _offer.buffering;
        _nft.collateral.erc20Token = _offer.erc20Token;
        _nft.lTokenId = _offer.lTokenId;
        _nft.lender = _lender;
        _borrow(_nftToken, _nftTokenId);
        emit AcceptOffer(_nftToken, _nftTokenId, _lender, _offer);
    }

    // Lend ERC20
    function lend(
        address _nftToken,
        uint256 _nftTokenId,
        uint256 _amount
    ) external isPause {
        NFT storage _nft = NftMap[_nftToken][_nftTokenId];
        address _erc20Token = _nft.collateral.erc20Token;
        require(!_nft.marks.isBorrow, "This collateral already borrowed");
        // get lend amount
        uint256 tempAmount = _nft.collateral.price.mul(10000 + fee).div(10000);
        require(_amount >= tempAmount, "The _amount is not match");
        IERC20(_erc20Token).safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        // get fee
        // uint256 _fee = _amount - _nft.collateral.price;
        // IERC20(_erc20Token).safeTransfer(owner(), _fee);
        // mint lToken
        uint256 _lTokenId = lToken.mint(msg.sender);
        // set collateral lTokenid
        _nft.lTokenId = _lTokenId;
        _nft.lender = msg.sender;
        emit Lend(_nftToken, _nftTokenId, msg.sender, _nft);
        // borrow action
        _borrow(_nftToken, _nftTokenId);
    }

    function _borrow(address _nftToken, uint256 _nftTokenId) internal {
        NFT storage _nft = NftMap[_nftToken][_nftTokenId];
        // change collateral status
        _nft.marks.isBorrow = true;
        _nft.borrowTimestamp = block.timestamp;
        // send erc20 token to collateral _nft.holder
        IERC20(_nft.collateral.erc20Token).safeTransfer(
            address(_nft.holder),
            _nft.collateral.price
        );
        emit Borrow(_nftToken, _nftTokenId, _nft.holder, _nft);
    }

    function repay(
        address _nftToken,
        uint256 _nftTokenId,
        uint256 _amount
    ) external {
        NFT storage _nft = NftMap[_nftToken][_nftTokenId];
        require(_nft.marks.isBorrow, "This collateral is not borrowed");
        // get repay amount
        uint256 _repayAmount = calcInterestRate(_nftToken, _nftTokenId, true);
        require(_amount >= _repayAmount, "Wrong amount.");
        require(!_nft.marks.isRepay, "This debt already Cleared");
        require(!_nft.marks.liquidate, "This debt already liquidated");
        IERC20(_nft.collateral.erc20Token).safeTransferFrom(
            address(msg.sender),
            address(this),
            _repayAmount
        );
        // change collateral status
        _nft.marks.isRepay = true;
        _nft.repayAmount = _repayAmount;
        ASSETS memory _assets = ASSETS(
            _repayAmount,
            _nft.lTokenId,
            _nft.collateral.erc20Token,
            false
        );
        AssetsMap[_nft.lTokenId] = _assets;
        emit AddAssets(_nft.lTokenId, _nft.lender, _nft, _assets);
        emit Repay(_nftToken, _nftTokenId, _nft);
    }

    function claimCollateral(address _nftToken, uint256 _nftTokenId) external {
        NFT storage _nft = NftMap[_nftToken][_nftTokenId];
        // Verify token owner
        require(bToken.ownerOf(_nft.bTokenId) == msg.sender, 'Not bToken owner');
        require(
            !_nft.marks.isBorrow || _nft.marks.isRepay,
            "This debt is not repay"
        );
        require(!_nft.marks.hasWithdraw, "This collateral has been withdrawn");
        require(!_nft.marks.liquidate, "This debt already liquidated");
        // burn bToken
        bToken.burn(_nft.bTokenId);
        // send collateral to msg.sender
        IERC721(_nftToken).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        _nft.marks.hasWithdraw = true;
        emit ClaimCollateral(_nftToken, _nftTokenId, msg.sender);
    }

    function claimERC20(uint256 _lTokenId) external {
        // check collateral status
        ASSETS storage _assets = AssetsMap[_lTokenId];
        // Verify token owner
        require(lToken.ownerOf(_assets.lTokenId) == msg.sender, 'Not lToken owner');
        require(_assets.repayAmount != 0, "This debt is not clear");
        require(!_assets.hasClaim, "Already claim assets");
        _assets.hasClaim = true;
        // burn lToken
        lToken.burn(_assets.lTokenId);
        // send erc20 token to lender
        IERC20(_assets.erc20Token).safeTransfer(
            msg.sender,
            _assets.repayAmount
        );
        emit ClaimERC20(msg.sender, _lTokenId);
    }

    function executeEmergency(address _nftToken, uint256 _nftTokenId)
        external
        isPause
        checkCollateralStatus(_nftTokenId, _nftToken)
    {
        NFT storage _nft = NftMap[_nftToken][_nftTokenId];
        // Verify token owner
        require(lToken.ownerOf(_nft.lTokenId) == msg.sender, 'Not lToken owner');
        uint256 time = _nft.borrowTimestamp;
        // An emergency can be triggered after collateral period
        require(
            (block.timestamp - time) > _nft.collateral.period,
            "Can do not execute emergency."
        );
        // set collateral emergency timestamp
        _nft.emergencyTimestamp = block.timestamp;
        emit ExecuteEmergency(_nftToken, _nftTokenId, msg.sender);
    }

    function liquidate(address _nftToken, uint256 _nftTokenId)
        external
        isPause
        checkCollateralStatus(_nftTokenId, _nftToken)
    {
        NFT storage _nft = NftMap[_nftToken][_nftTokenId];
        // Verify token owner
        require(lToken.ownerOf(_nft.lTokenId) == msg.sender, 'Not lToken owner');
        // burn lToken
        lToken.burn(_nft.lTokenId);
        uint256 _emerTime = _nft.emergencyTimestamp;
        require(
            (block.timestamp - _emerTime) > _nft.collateral.buffering,
            "Can do not liquidate."
        );
        // send collateral to lender
        IERC721(_nftToken).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        _nft.marks.liquidate = true;
        emit Liquidate(_nftToken, _nftTokenId, msg.sender);
    }

    function calcInterestRate(
        address _nftToken,
        uint256 _nftTokenId,
        bool _isRepay
    ) public view returns (uint256 repayAmount) {
        uint256 base = _isRepay ? 100 : 101;
        NFT memory _nft = NftMap[_nftToken][_nftTokenId];
        if (_nft.borrowTimestamp == 0) {
            return repayAmount;
        }
        // loan times
        uint256 _loanSeconds = block.timestamp - _nft.borrowTimestamp;
        // per second interest
        uint256 _secondInterest = _nft.collateral.apy.mul(10**10).div(
            yearSeconds
        );
        // total interest
        uint256 _interest = (_loanSeconds *
            _secondInterest *
            _nft.collateral.price) / 10**18;
        repayAmount = _interest.add(_nft.collateral.price.mul(base).div(100));
    }
}
