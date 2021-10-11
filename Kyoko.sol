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
        bool cancel;
        uint256 lTokenId;
    }

    struct NFT {
        address holder;
        address lender;
        uint256 nftId; // nft tokenId
        address nftAdr; // nft address
        uint256 bTokenId; // btoken id
        uint256 lTokenId; // ltoken id
        uint256 borrowTimestamp; // borrow timestamp
        uint256 emergencyTimestamp; // emergency timestamp
        uint256 repayAmount; // repayAmount
        MARK marks;
        COLLATERAL collateral;
    }

    mapping(uint256 => NFT) public NftMap; // uint256 === btokenId(btokenId is a unique identifier)
    mapping(uint256 => mapping(uint256 => OFFER)) public OfferMap; //btokenId => ltokenId => Bidder(Only one offer can exist per person)
    mapping(uint256 => OFFER) public LTokenMapOffer; // ltokenid => Offer (The token holder unilaterally searches for offer information
    mapping(uint256 => uint256) public TokenMap; // lTokenId => bTokenId => collateral (The token holder unilaterally searches for collateral information

    event NFTReceived(
        address indexed operator,
        address indexed from,
        uint256 indexed tokenId,
        bytes data
    );

    event Deposit(uint256 indexed _bTokenId);

    event Modify(uint256 indexed _bTokenId, address _holder);

    event AddOffer(
        uint256 indexed _bTokenId,
        address indexed _lender,
        uint256 indexed _lTokenId
    );

    event CancelOffer(uint256 indexed _bTokenId, address _lender);

    event AcceptOffer(uint256 indexed _bTokenId);

    event Lend(uint256 indexed _bTokenId, uint256 indexed _lTokenId);

    event Borrow(uint256 indexed _bTokenId);

    event Repay(uint256 indexed _bTokenId);

    event ClaimCollateral(uint256 indexed _bTokenId);

    event ClaimERC20(uint256 indexed _lTokenId);

    event ExecuteEmergency(uint256 indexed _bTokenId);

    event Liquidate(uint256 indexed _bTokenId);

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

    modifier checkCollateralStatus(uint256 _bTokenId) {
        NFT memory _nft = NftMap[_bTokenId];
        require(!_nft.marks.isRepay && _nft.marks.isBorrow, "NFT status wrong");
        _;
    }

    function setPause(bool _pause) external onlyOwner {
        pause = _pause;
        emit SetPause(_pause);
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

    /**
     * @param _nftAdr Collateral contract address.
     * @param _nftId Collateral ID.
     * @param _price Loan conditions.
     * @param _period Loan conditions.
     * @param _buffering Loan conditions.
     * @param _erc20Token Loan conditions.
     * @param _description Collateral description.
     * Deposit NFT
     */
    function deposit(
        address _nftAdr,
        uint256 _nftId,
        uint256 _apy,
        uint256 _price,
        uint256 _period,
        uint256 _buffering,
        address _erc20Token,
        string memory _description
    ) external isPause checkWhiteList(_erc20Token) {
        require(IERC721(_nftAdr) != bToken && IERC721(_nftAdr) != lToken); // btoken => No
        require(
            IERC721(_nftAdr).supportsInterface(0x80ac58cd),
            "Parameter _nftAdr is not ERC721 contract address"
        );
        uint256 _bTokenId = bToken.mint(msg.sender); // mint bToken
        MARK memory _mark = MARK(false, false, false, false); // loan status info
        COLLATERAL memory _collateral = COLLATERAL(
            _apy,
            _price,
            _period,
            _buffering,
            _erc20Token,
            _description
        ); // collateral info
        IERC721(_nftAdr).safeTransferFrom(msg.sender, address(this), _nftId);
        // set collateral info
        NftMap[_bTokenId] = NFT({
            holder: msg.sender,
            nftId: _nftId,
            nftAdr: _nftAdr,
            bTokenId: _bTokenId,
            borrowTimestamp: 0,
            emergencyTimestamp: 0,
            repayAmount: 0,
            lTokenId: 0,
            marks: _mark,
            lender: address(0),
            collateral: _collateral
        });

        emit Deposit(_bTokenId);
    }

    /**
     * @param _bTokenId For find collateral.
     * @param _apy Loan conditions.
     * @param _price Loan conditions.
     * @param _period Loan conditions.
     * @param _buffering Loan conditions.
     * @param _erc20Token Loan conditions.
     * @param _description Collateral description.
     * Modify collateral information
     */
    function modify(
        uint256 _bTokenId,
        uint256 _apy,
        uint256 _price,
        uint256 _period,
        uint256 _buffering,
        address _erc20Token,
        string memory _description
    ) external isPause checkWhiteList(_erc20Token) {
        NFT storage _nft = NftMap[_bTokenId];
        require(
            bToken.ownerOf(_bTokenId) == msg.sender && !_nft.marks.isBorrow,
            "Not bToken owner"
        );
        // change collateral status
        _nft.collateral.apy = _apy;
        _nft.collateral.price = _price;
        _nft.collateral.period = _period;
        _nft.collateral.buffering = _buffering;
        _nft.collateral.erc20Token = _erc20Token;
        _nft.collateral.description = _description;
        emit Modify(_bTokenId, msg.sender);
    }

    /**
     * @param _bTokenId For find collateral.
     * @param _apy Loan conditions.
     * @param _price Loan conditions.
     * @param _period Loan conditions.
     * @param _buffering Loan conditions.
     * @param _erc20Token Loan conditions.
     * Bid for collateral
     */
    function addOffer(
        uint256 _bTokenId,
        uint256 _apy,
        uint256 _price,
        uint256 _period,
        uint256 _buffering,
        address _erc20Token
    ) external isPause checkWhiteList(_erc20Token) {
        NFT memory _nft = NftMap[_bTokenId];
        require(!_nft.marks.isBorrow, "This collateral already borrowed");
        uint256 _lTokenId = lToken.mint(msg.sender); // mint lToken
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
            false,
            _lTokenId
        );
        OfferMap[_bTokenId][_lTokenId] = _off;
        LTokenMapOffer[_lTokenId] = _off;
        emit AddOffer(_bTokenId, msg.sender, _lTokenId);
    }

    /**
     * @param _bTokenId For find Collateral.
     * @param _lTokenId For find Offer.
     * Offer not accepted executable
     * Destroy ltoken after execution
     */

    function cancelOffer(uint256 _bTokenId, uint256 _lTokenId)
        external
        isPause
    {
        OFFER storage _offer = OfferMap[_bTokenId][_lTokenId];
        require(!_offer.accept, "This offer already accepted.");
        require(!_offer.cancel, "This offer already cancelled.");
        require(
            lToken.ownerOf(_offer.lTokenId) == msg.sender,
            "Not lToken owner"
        ); // Verify token owner
        lToken.burn(_offer.lTokenId);
        uint256 _price = _offer.price.mul(10000 + fee).div(10000);
        IERC20(_offer.erc20Token).safeTransfer(msg.sender, _price);
        _offer.cancel = true;
        LTokenMapOffer[_lTokenId] = _offer;
        emit CancelOffer(_bTokenId, msg.sender);
    }

    /**
     * @param _bTokenId For find collateral.
     * @param _lTokenId Accept the offer of the _lTokenId.
     */

    function acceptOffer(uint256 _bTokenId, uint256 _lTokenId)
        external
        isPause
    {
        NFT storage _nft = NftMap[_bTokenId];
        require(!_nft.marks.isBorrow, "This collateral already borrowed");
        OFFER storage _offer = OfferMap[_bTokenId][_lTokenId];
        require(bToken.ownerOf(_bTokenId) == msg.sender, "Not bToken owner");
        require(!_offer.cancel, "This Offer out of date");
        _offer.accept = true; // change offer status
        LTokenMapOffer[_lTokenId] = _offer;
        // change collateral status
        _nft.collateral.apy = _offer.apy;
        _nft.collateral.price = _offer.price;
        _nft.collateral.period = _offer.period;
        _nft.collateral.buffering = _offer.buffering;
        _nft.collateral.erc20Token = _offer.erc20Token;
        _nft.lTokenId = _offer.lTokenId;
        _nft.lender = lToken.ownerOf(_lTokenId);
        TokenMap[_lTokenId] = _bTokenId;
        _borrow(_bTokenId);
        emit AcceptOffer(_bTokenId);
    }

    /**
     * @param _bTokenId For find collateral.
     * Lend money to the mortgagor immediately.
     */
    function lend(uint256 _bTokenId) external isPause {
        NFT storage _nft = NftMap[_bTokenId];
        require(!_nft.marks.isBorrow, "This collateral already borrowed");
        address _erc20Token = _nft.collateral.erc20Token;
        uint256 _amount = _nft.collateral.price.mul(10000 + fee).div(10000); // get lend amount
        IERC20(_erc20Token).safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        uint256 _lTokenId = lToken.mint(msg.sender); // mint lToken
        _nft.lTokenId = _lTokenId; // set collateral lTokenid
        _nft.lender = msg.sender;
        TokenMap[_lTokenId] = _bTokenId;
        emit Lend(_bTokenId, _lTokenId);
        _borrow(_bTokenId); // borrow action
    }

    function _borrow(uint256 _bTokenId) internal {
        NFT storage _nft = NftMap[_bTokenId];
        _nft.marks.isBorrow = true; // change collateral status
        _nft.borrowTimestamp = block.timestamp;
        IERC20(_nft.collateral.erc20Token).safeTransfer(
            address(_nft.holder),
            _nft.collateral.price
        ); // send erc20 token to collateral _nft.holder
        emit Borrow(_bTokenId);
    }

    /**
     * @param _bTokenId For find collateral.
     * Repayment of debt.
     */

    function repay(uint256 _bTokenId, uint256 _amount) external {
        NFT storage _nft = NftMap[_bTokenId];
        require(_nft.marks.isBorrow, "This collateral is not borrowed");
        uint256 _repayAmount = calcInterestRate(_bTokenId, true); // get repay amount
        require(_amount >= _repayAmount, "Wrong amount.");
        require(!_nft.marks.isRepay, "This debt already Cleared"); // Debt has clear?
        require(!_nft.marks.liquidate, "This debt already liquidated"); // has liquidate?
        IERC20(_nft.collateral.erc20Token).safeTransferFrom(
            address(msg.sender),
            address(this),
            _repayAmount
        );
        _nft.marks.isRepay = true; // change collateral status
        _nft.repayAmount = _repayAmount;
        emit Repay(_bTokenId);
    }

    /**
     * @param _bTokenId For find collateral.
     * Execution after debt repayment.
     * Destroy btoken after execution
     */

    function claimCollateral(uint256 _bTokenId) external {
        NFT storage _nft = NftMap[_bTokenId];
        require(
            !_nft.marks.isBorrow || _nft.marks.isRepay,
            "This debt is not repay"
        );
        require(!_nft.marks.liquidate, "This debt already liquidated");
        require(bToken.ownerOf(_bTokenId) == msg.sender, "Not bToken owner"); // Verify token owner
        bToken.burn(_nft.bTokenId); // burn bToken
        IERC721(_nft.nftAdr).safeTransferFrom(
            address(this),
            msg.sender,
            _nft.nftId
        ); // send collateral to msg.sender
        _nft.marks.hasWithdraw = true;
        emit ClaimCollateral(_bTokenId);
    }

    /**
     * @param _lTokenId For find assest.
     * The collateral is enforceable after the debt is repaid.
     * Destroy ltoken after execution
     */

    function claimERC20(uint256 _lTokenId) external {
        uint256 _bTokenId = TokenMap[_lTokenId];
        NFT storage _nft = NftMap[_bTokenId];
        require(
            lToken.ownerOf(_nft.lTokenId) == msg.sender,
            "Not lToken owner"
        ); // Verify token owner
        require(_nft.marks.isRepay, "This debt is not clear");
        lToken.burn(_nft.lTokenId); // burn lToken
        IERC20(_nft.collateral.erc20Token).safeTransfer(
            msg.sender,
            _nft.repayAmount
        );
        emit ClaimERC20(_nft.lTokenId);
    }

    /**
     * @param _bTokenId For find collateral.
     * Execute after lending cycle.
     */

    function executeEmergency(uint256 _bTokenId)
        external
        isPause
        checkCollateralStatus(_bTokenId)
    {
        NFT storage _nft = NftMap[_bTokenId];
        require(
            lToken.ownerOf(_nft.lTokenId) == msg.sender,
            "Not lToken owner"
        ); // Verify token owner
        require(
            (block.timestamp - _nft.borrowTimestamp) > _nft.collateral.period,
            "Can do not execute emergency."
        ); // An emergency can be triggered after collateral period
        _nft.emergencyTimestamp = block.timestamp; // set collateral emergency timestamp
        emit ExecuteEmergency(_bTokenId);
    }

    /**
     * @param _bTokenId For find collateral.
     * First collateral must be in an emergency.
     * Second collateral can only be liquidate after the buffering time has elapsed.
     * Destroy ltoken after execution
     */
    function liquidate(uint256 _bTokenId)
        external
        isPause
        checkCollateralStatus(_bTokenId)
    {
        NFT storage _nft = NftMap[_bTokenId];
        uint256 _emerTime = _nft.emergencyTimestamp;
        require(_emerTime > 0, "The collateral has not been in an emergency");
        require(
            (block.timestamp - _emerTime) > _nft.collateral.buffering,
            "Can do not liquidate."
        );
        require(
            lToken.ownerOf(_nft.lTokenId) == msg.sender,
            "Not lToken owner"
        ); // Verify token owner
        lToken.burn(_nft.lTokenId); // burn lToken
        IERC721(_nft.nftAdr).safeTransferFrom(
            address(this),
            msg.sender,
            _nft.nftId
        ); // send collateral to lender
        _nft.marks.liquidate = true;
        emit Liquidate(_bTokenId);
    }

    /**
     * @param _bTokenId For find collateral.
     * @param _isRepay False for frontEnd || True for repay action/
     * _secondsInterest = Interest per second per token.
     * Because the interest rate is a percentage system.
     * So it needs to be multiplied by 10 * * 16 to convert to Wei.
     * Then calculate the interest per second of each token.
     * total interest = _loanSeconds multiply _secondsInterest
     * repatAmount = total interest plus price.
     */
    function calcInterestRate(uint256 _bTokenId, bool _isRepay)
        public
        view
        returns (uint256 repayAmount)
    {
        uint256 base = _isRepay ? 100 : 101;
        NFT memory _nft = NftMap[_bTokenId];
        if (_nft.borrowTimestamp == 0) {
            return repayAmount;
        }
        uint256 _loanSeconds = block.timestamp - _nft.borrowTimestamp; // loan period
        uint256 _secondsInterest = _nft.collateral.apy.mul(10**16).div(
            yearSeconds
        );
        uint256 _totalInterest = (_loanSeconds *
            _secondsInterest *
            _nft.collateral.price) / 10**18; // total interest
        repayAmount = _totalInterest.add(
            _nft.collateral.price.mul(base).div(100)
        );
    }
}
