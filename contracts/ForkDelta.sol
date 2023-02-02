pragma solidity 0.4.19;

import "./IToken.sol";
import "./LSafeMath.sol";

/**
 * @title ForkDelta
 * @dev This is the main contract for the ForkDelta exchange.
 */
contract ForkDelta {
  
  using LSafeMath for uint;

  /// 변수
  address public admin; // 어드민 주소 
  address public feeAccount; //  fee받을 계정
  uint public feeTake; // fee 백분율
  uint public freeUntilDate; // 날짜 unix timestamp 기준 이때까지 free trade 이후는 유료
  bool private depositingTokenFlag; // depositToken 부터 호출시 Token.transferFrom true 
  // tokens<토큰 주소><계정 주소> = <토큰 보유량>
  mapping (address => mapping (address => uint)) public tokens; // 계정에 토큰 주소 매핑 해당 주소의 토큰 잔액을 표현, token = 0 은 ether용
  // orders<사용자 계정><주문 정보 해시 값> = <주문 상태>
  mapping (address => mapping (bytes32 => bool)) public orders; // 사용자 주문에대한 해시값(주문 해시)이 false, true인지 표시 (true = submitted by user, 오브체인과 일치?)
  // orderfills<사용자 계정><주문 정보 해시 값> = <거래된 토큰 양>
  mapping (address => mapping (bytes32 => uint)) public orderFills; // 사용자 주문에 대한 주문, 주문이 실행될때 마다 (완료된 주문수량이 쌓임)
  address public predecessor; // 이전 버전정보 0이면 첫번째 버전임 
  address public successor; // 이계약의 다음 버전 0이면 첫번째 
  uint16 public version; // 버전 번호

  /// 이벤트
  event Order(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user);
  event Cancel(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s);
  event Trade(address tokenGet, uint amountGet, address tokenGive, uint amountGive, address get, address give);
  event Deposit(address token, address user, uint amount, uint balance);
  event Withdraw(address token, address user, uint amount, uint balance);
  event FundsMigrated(address user, address newContract);

  /// 어드민인지 체크 
  modifier isAdmin() {
      require(msg.sender == admin);
      _;
  }

  /// 생성자 함수, contract creation 때만 생성
  function ForkDelta(address admin_, address feeAccount_, uint feeTake_, uint freeUntilDate_, address predecessor_) public {
    admin = admin_;
    feeAccount = feeAccount_;
    feeTake = feeTake_;
    freeUntilDate = freeUntilDate_;
    depositingTokenFlag = false;
    predecessor = predecessor_;
    
    if (predecessor != address(0)) {
      version = ForkDelta(predecessor).version() + 1;
    } else {
      version = 1;
    }
  }

  /// 폴백 리버트 
  function() public {
    revert();
  }

  /// 어드민 주소 체인지
  function changeAdmin(address admin_) public isAdmin {
    require(admin_ != address(0));
    admin = admin_;
  }

  /// FEE 어카운트 체인지 
  function changeFeeAccount(address feeAccount_) public isAdmin {
    feeAccount = feeAccount_;
  }

  /// feetake를 변경함 값은 작아야함
  function changeFeeTake(uint feeTake_) public isAdmin {
    require(feeTake_ <= feeTake);
    feeTake = feeTake_;
  }

  /// fee date 체인지, 유닉스 타임스탬프 
  function changeFreeUntilDate(uint freeUntilDate_) public isAdmin {
    freeUntilDate = freeUntilDate_;
  }
  
  /// successor 변경
  function setSuccessor(address successor_) public isAdmin {
    require(successor_ != address(0));
    successor = successor_;
  }
  
  ////////////////////////////////////////////////////////////////////////////////
  // Deposits, Withdrawals, Balances
  ////////////////////////////////////////////////////////////////////////////////

  /**
   *이더 입금처리  
  */
  function deposit() public payable {
    tokens[0][msg.sender] = tokens[0][msg.sender].add(msg.value);
    Deposit(0, msg.sender, msg.value, tokens[0][msg.sender]);
  }

  /**
   * 이더 출금처리
  */
  function withdraw(uint amount) public {
    require(tokens[0][msg.sender] >= amount);
    tokens[0][msg.sender] = tokens[0][msg.sender].sub(amount);
    msg.sender.transfer(amount);
    Withdraw(0, msg.sender, amount, tokens[0][msg.sender]);
  }

  /**
  * evm 기반 토큰 입금을 처리 
  * 가스 환불0, 이더 입금 허용x 
  * approve안되면 트랜스퍼 안댐 
  * @param token Ethereum contract address of the token or 0 for Ether
  * @param amount uint of the amount of the token the user wishes to deposit
  */
  function depositToken(address token, uint amount) public 
  {
    require(token != 0);
    depositingTokenFlag = true;
    require(IToken(token).transferFrom(msg.sender, this, amount));
    depositingTokenFlag = false;
    tokens[token][msg.sender] = tokens[token][msg.sender].add(amount);
    Deposit(token, msg.sender, amount, tokens[token][msg.sender]);
  }

  /**
  * This function provides a fallback solution as outlined in ERC223.
  * 토큰이 이계약으로 직접 전송되면 거래가 취소 
  * @param sender Ethereum address of the sender of the token
  * @param amount amount of the incoming tokens
  * @param data attached data similar to msg.data of Ether transactions
  */
  function tokenFallback( address sender, uint amount, bytes data) public returns (bool ok) {
      if (depositingTokenFlag) { // depositToken() 부터 Transfer, 유저 밸런스 업데이트 수행해도됨
       
        return true;
      } else { // erc223 token.tranfer 사용해서 해당 컨트랙트로 접근 허용하지않음 일관성을 위해 erc20,eth도 포함 
        revert();
      }
  }
  
  /**
  * EVM 기반 토큰들 출금 처리 , 이더 코인 처리안함, 실패시 가스비 환불
  * @param token Ethereum contract address of the token or 0 for Ether
  * @param amount uint of the amount of the token the user wishes to withdraw
  */
  function withdrawToken(address token, uint amount) public {
    require(token != 0);
    require(tokens[token][msg.sender] >= amount);
    tokens[token][msg.sender] = tokens[token][msg.sender].sub(amount);
    require(IToken(token).transfer(msg.sender, amount));
    Withdraw(token, msg.sender, amount, tokens[token][msg.sender]);
  }

  /**
  * 토큰 잔액 조회
  * @param token Ethereum contract address of the token or 0 for Ether
  * @param user Ethereum address of the user
  * @return the amount of tokens on the exchange for a given user address
  */
  function balanceOf(address token, address user) public constant returns (uint) {
    return tokens[token][user];
  }

  ////////////////////////////////////////////////////////////////////////////////
  // Trading
  ////////////////////////////////////////////////////////////////////////////////

  /**
  * 컨트렉트 안에 활성된 주문을 저장 
  * Note: tokenGet & tokenGive can be the Ethereum contract address.
  * @param tokenGet 받을 Ethereum contract 기반 token address -> 받을 토큰의 어드레스
  * @param amountGet 받을 토큰의 양
  * @param tokenGive 줄 토큰의 Ethereum contract 기반 token address
  * @param amountGive 줄 토큰의 양
  * @param expires 주문이 만료될 블록 번호 단위
  * @param nonce arbitrary 난수
  */
  function order(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce) public {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    orders[msg.sender][hash] = true; // 주문자를 msg.send로 받아서 주문 넣고 true로 상태전환
    Order(tokenGet, amountGet, tokenGive, amountGive, expires, nonce, msg.sender); // 이벤트
  }

  /**
  * 사용자 : 사용자 거래 허용 
  * Requires 조건 : 사용자 서명이 명확, 거래 expire 체크, 거래 하기위한 자금이 존재해야함
  * tokenGet & tokenGive =>  Ethereum contract address 가 될수있음 
  * amount는 (amountGet / tokenGet) 단위
  * @param tokenGet 받을 토큰의 이더리움 컨트랙트 주소 
  * @param amountGet 받을 토큰의 양 
  * @param tokenGive 줘야할 토큰의 이더리움 컨트랙트 주소
  * @param amountGive 줘야할 토큰양
  * @param expires 주문이 만료될 블록 넘버 
  * @param nonce arbitrary 랜덤 변수
  * @param user 주문한 사용자 이더리움 계정 주소
  * @param v 사용자가 서명한 주문 해시 서명의 일부분 
  * @param r 사용자가 서명한 주문 해시 서명의 일부분 
  * @param s 사용자가 서명한 주문 해시 서명의 일부분 
  * @param amount 이 거래에서 구매할 토큰의 양 
  */
  function trade(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s, uint amount) public {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    require((
      (orders[user][hash] || ecrecover(keccak256("\x19Ethereum Signed Message:\n32", hash), v, r, s) == user) &&
      block.number <= expires &&
      orderFills[user][hash].add(amount) <= amountGet
    )); // 주문정보에 대한 서명 검증, 주문 만료 체크,  주문 가능한 수량이 존재한지 체크
    tradeBalances(tokenGet, amountGet, tokenGive, amountGive, user, amount); // 거래에 관련된 사용자 토큰 잔앱 업데이트 
    orderFills[user][hash] = orderFills[user][hash].add(amount); // 완료된 거래 금액으로 업데이트
    Trade(tokenGet, amount, tokenGive, amountGive.mul(amount) / amountGet, user, msg.sender);
  }

  /**
  * trade 수행시 자금이동을 처리 
  * 수수료 처리 
  * 구매자 판매자 모두 토큰 잔액 업데이트 
  * tokenGet & tokenGive 는  Ethereum contract address가 될수도있음 
  * amount는 (amountGet / tokenGet) 단위
  * @param tokenGet 받을 토큰의 이더리움 컨트랙트 주소 
  * @param amountGet 받을 토큰의 양 
  * @param tokenGive 줘야하는 토큰 이더리움 컨트랙트 주소 
  * @param amountGive 줘야하는 토큰 양
  * @param user order 한 사용자의 이더리움 계정 주소
  * @param amount 이 거래에서 구매할 토큰의 양 
  */
  function tradeBalances(address tokenGet, uint amountGet, address tokenGive, uint amountGive, address user, uint amount) private {
    
    uint feeTakeXfer = 0;
    
    if (now >= freeUntilDate) {
      feeTakeXfer = amount.mul(feeTake).div(1 ether);
    }
    
    tokens[tokenGet][msg.sender] = tokens[tokenGet][msg.sender].sub(amount.add(feeTakeXfer)); // 여기서 msg.sender는 trade 함수 호출자 구매자?
    tokens[tokenGet][user] = tokens[tokenGet][user].add(amount); //  order한 사용자가 보유한 토큰을 구매한 만큼 추가  
    tokens[tokenGet][feeAccount] = tokens[tokenGet][feeAccount].add(feeTakeXfer); // fee어카운트에 수수료 추가및 업데이트 
    tokens[tokenGive][user] = tokens[tokenGive][user].sub(amountGive.mul(amount).div(amountGet)); //  order한 사용자가 보유한 토큰을 뺴감, 트레이딩  
    tokens[tokenGive][msg.sender] = tokens[tokenGive][msg.sender].add(amountGive.mul(amount).div(amountGet)); // msg.sender 가져가야할 토큰을 추가함 위에 공식이랑 연동
  }


  /**
  * 거래가 되는지 테스트하는 함수 폴링인듯? 
  * tokenGet & tokenGive 는  Ethereum contract address가 될수도있음 
  * amount는 (amountGet / tokenGet) 단위
  * @param tokenGet 받을 토큰의 이더리움 컨트랙트 주소 
  * @param amountGet 받을 토큰의 양 
  * @param tokenGive 줘야할 토큰의 이더리움 컨트랙트 주소
  * @param amountGive 줘야할 토큰양
  * @param expires 주문이 만료될 블록 넘버 
  * @param nonce arbitrary 랜덤 변수
  * @param user 주문한 사용자 이더리움 계정 주소
  * @param v 사용자가 서명한 주문 해시 서명의 일부분 
  * @param r 사용자가 서명한 주문 해시 서명의 일부분 
  * @param s 사용자가 서명한 주문 해시 서명의 일부분 
  * @param amount 이 거래에서 구매할 토큰의 양 
  * @param sender order를 요청한 계정 주소 
  * @return bool: true거래성공, false 거래 실패
  */
  function testTrade(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s, uint amount, address sender) public constant returns(bool) {
    if (!(
      tokens[tokenGet][sender] >= amount &&
      availableVolume(tokenGet, amountGet, tokenGive, amountGive, expires, nonce, user, v, r, s) >= amount
      )) {  // 거래 가능한지 체크, 
      return false;
    } else {
      return true;
    }
  }

  /**
  * 주어진 order에 사용가능한 볼륨있는지 체크 
  * Note: tokenGet & tokenGive 이더리움 컨트랙트 주소가 될수있음 
  * @param tokenGet 받을 토큰의 이더리움 컨트랙트 주소 
  * @param amountGet 받을 토큰의 양 
  * @param tokenGive 줘야할 토큰의 이더리움 컨트랙트 주소
  * @param amountGive 줘야할 토큰양
  * @param expires 주문이 만료될 블록 넘버 
  * @param nonce arbitrary 랜덤 변수
  * @param user 주문한 사용자 이더리움 계정 주소
  * @param v 사용자가 서명한 주문 해시 서명의 일부분 
  * @param r 사용자가 서명한 주문 해시 서명의 일부분 
  * @param s 사용자가 서명한 주문 해시 서명의 일부분 
  * @return uint: 주어진 주문에 사용가능한 볼륨의 양 (amountGet / tokenGet) 면에서
  */
  function availableVolume(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s) public constant returns(uint) {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    if (!(
      (orders[user][hash] || ecrecover(keccak256("\x19Ethereum Signed Message:\n32", hash), v, r, s) == user) &&
      block.number <= expires
      )) {
      return 0;
    }
    uint[2] memory available;
    available[0] = amountGet.sub(orderFills[user][hash]);
    available[1] = tokens[tokenGive][user].mul(amountGet) / amountGive;
    if (available[0] < available[1]) {
      return available[0];
    } else {
      return available[1];
    }
  }

  /**
  *  이미 채워진 주문의 양을 확인
  * Note: tokenGet & tokenGive 이더 컨트랙트 주소일수있음 
  * @param tokenGet 받을 토큰의 이더리움 컨트랙트 주소 
  * @param amountGet 받을 토큰의 양 
  * @param tokenGive 줘야할 토큰의 이더리움 컨트랙트 주소
  * @param amountGive 줘야할 토큰양
  * @param expires 주문이 만료될 블록 넘버 
  * @param nonce arbitrary 랜덤 변수
  * @param user 주문한 사용자 이더리움 계정 주소
  * @param v 사용자가 서명한 주문 해시 서명의 일부분 
  * @param r 사용자가 서명한 주문 해시 서명의 일부분 
  * @param s 사용자가 서명한 주문 해시 서명의 일부분 
  * @return uint: 주어진 주문에 사용가능한 볼륨의 양 (amountGet / tokenGet) 면에서
  */
  function amountFilled(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s) public constant returns(uint) {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    return orderFills[user][hash];
  }

  /**
  * 주문 취소
  * Updates orderFills to the full amountGet
  * Note: tokenGet & tokenGive 이더리움 컨트랙트 주소 일수있음 
  * @param tokenGet 받을 토큰 주소 
  * @param amountGet 받을 토큰의 양 
  * @param tokenGive 줘야되는 토큰 주소 
  * @param amountGive 줘야되는 토큰양 
  * @param expires 만료 
  * @param nonce arbitrary 난수 
  * @param v 사용자가 서명한 주문 해시 서명의 일부분 
  * @param r 사용자가 서명한 주문 해시 서명의 일부분 
  * @param s 사용자가 서명한 주문 해시 서명의 일부분 
  * @return uint: (amountGet / tokenGet) 기준으로 이미 채워진 지정된 주문의 양  -> 없는데? 없어진듯? 
  */
  function cancelOrder(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, uint8 v, bytes32 r, bytes32 s) public {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    require ((orders[msg.sender][hash] || ecrecover(keccak256("\x19Ethereum Signed Message:\n32", hash), v, r, s) == msg.sender));
    orderFills[msg.sender][hash] = amountGet; // 
    Cancel(tokenGet, amountGet, tokenGive, amountGive, expires, nonce, msg.sender, v, r, s);
  }


  
  ////////////////////////////////////////////////////////////////////////////////
  // Contract Versioning / Migration
  ////////////////////////////////////////////////////////////////////////////////
  
  /**
   * 업그레이드를 위한 계약인데 지금은 필요없는 소스 코드 
  */
  function migrateFunds(address newContract, address[] tokens_) public {
  
    require(newContract != address(0));
    
    ForkDelta newExchange = ForkDelta(newContract);

    // Move Ether into new exchange.
    uint etherAmount = tokens[0][msg.sender];
    if (etherAmount > 0) {
      tokens[0][msg.sender] = 0;
      newExchange.depositForUser.value(etherAmount)(msg.sender);
    }

    // Move Tokens into new exchange.
    for (uint16 n = 0; n < tokens_.length; n++) {
      address token = tokens_[n];
      require(token != address(0)); // Ether is handled above.
      uint tokenAmount = tokens[token][msg.sender];
      
      if (tokenAmount != 0) {      
      	require(IToken(token).approve(newExchange, tokenAmount));
      	tokens[token][msg.sender] = 0;
      	newExchange.depositTokenForUser(token, tokenAmount, msg.sender);
      }
    }

    FundsMigrated(msg.sender, newContract);
  }
  
  /**
  * 해당 컨트랙트에 이더입급에 사용 
  * 자금이동에 사용 
  */
  function depositForUser(address user) public payable {
    require(user != address(0));
    require(msg.value > 0);
    tokens[0][user] = tokens[0][user].add(msg.value);
  }
  
  /**
  * 해당 컨트랙트에 이더외 토큰 입금 
  * 자금 이동에 사용 셀프로 approve까지 호출해야함.. ㅋㅋ 
  */
  function depositTokenForUser(address token, uint amount, address user) public {
    require(token != address(0));
    require(user != address(0));
    require(amount > 0);
    depositingTokenFlag = true;
    require(IToken(token).transferFrom(msg.sender, this, amount));
    depositingTokenFlag = false;
    tokens[token][user] = tokens[token][user].add(amount);
  }
  
}